import 'dart:typed_data';

import '../proximity_identity.dart';

/// **Ce qu'on émet, et ce qu'on s'attend à recevoir — calculé à l'avance.**
///
/// ## Pourquoi ce fichier existe : le point H
///
/// Le jeton d'un ami vaut `HMAC(secret de la paire, créneau)`. Le créneau change
/// toutes les 15 minutes, et c'était **un minuteur Dart** qui poussait la
/// nouvelle valeur à la radio. Or le Dart meurt avec l'interface, pendant que le
/// service natif, lui, survit et garde la radio.
///
/// Conséquence relevée le 2026-08-19 (`RAPPELS.md` #49) : dès qu'Android
/// détruisait l'activité, l'identifiant émis **se figeait**. Passé une demi-heure
/// il sortait de la fenêtre de tolérance et plus aucun ami ne reconnaissait
/// l'appareil — alors qu'il criait en permanence, avec la bonne clé. Et il
/// devenait constant, c'est-à-dire exactement le mouchard que la rotation par
/// créneau existe pour éviter.
///
/// ⚠️ **Ce défaut ne vient PAS de la clé partagée**, donc le passage au secret
/// par paire ne le corrige pas : il vient du créneau, qui reste indispensable.
/// La cause à supprimer est ailleurs — *le natif dépend du Dart pour savoir quoi
/// émettre*.
///
/// D'où le plan : le Dart calcule **plusieurs heures de jetons d'avance** et les
/// remet au service, qui n'a plus qu'à lire l'heure et choisir. Le natif ne
/// détient aucun secret, ne calcule aucune cryptographie, et continue d'émettre
/// juste même si le Dart a disparu depuis longtemps.
///
/// ## Le dimensionnement, et ce qu'il coûte vraiment
///
/// [horizon] créneaux × N amis × 16 octets. À 12 h et 50 amis :
/// 48 × 50 × 16 ≈ **38 Ko**. C'est le prix de l'indépendance du natif.
///
/// ## ⚠️ Ce que ce fichier ne fait pas
///
/// Il ne lit rien, n'écrit rien, ne parle à aucune radio. Il transforme des
/// secrets en jetons. C'est ce qui le rend testable sans Bluetooth, et c'est la
/// règle de dissociation de Jay (2026-08-20) : le calcul ne connaît ni la source
/// de ses entrées, ni la destination de ses sorties.

/// Un jeton à émettre, et pour qui il est lisible.
class AdvertToken {
  const AdvertToken({
    required this.slot,
    required this.bytes,
    required this.audience,
  });

  final int slot;
  final Uint8List bytes;

  /// L'identifiant de l'ami visé, ou `null` pour l'identifiant public du ping.
  ///
  /// ⚠️ **Un accesseur `isPublic` vivait ici et n'avait aucun appelant**
  /// (retiré le 2026-08-28). La question se pose une seule fois, dans le
  /// superviseur, qui traduit l'audience en octet de type pour le natif — un
  /// second endroit où la poser aurait été une seconde définition de « public ».
  final String? audience;
}

/// Le plan d'émission : tout ce que l'appareil doit crier, et quand.
class AdvertPlan {
  const AdvertPlan({
    required this.fromSlot,
    required this.toSlot,
    required this.tokens,
  });

  /// Premier créneau couvert (inclus).
  final int fromSlot;

  /// Dernier créneau couvert (inclus).
  final int toSlot;

  final List<AdvertToken> tokens;

  bool get isEmpty => tokens.isEmpty;

  /// Les jetons du créneau [slot], dans l'ordre où les émettre.
  List<AdvertToken> forSlot(int slot) => [
    for (final t in tokens)
      if (t.slot == slot) t,
  ];

  // ⚠️ **`covers` a été RETIRÉ le 2026-08-28** : aucun appelant côté Dart. La
  // question « le plan couvre-t-il cet instant ? » se pose là où elle a des
  // conséquences — dans le natif, qui se **tait** quand la réponse est non
  // (`AdvertSchedule.covers`). La poser ici aussi aurait été un second juge
  // pour une décision qui n'appartient qu'à l'émetteur.
}

/// La table de reconnaissance : jeton reçu (hex) → identifiant de l'ami.
class RecognitionTable {
  const RecognitionTable({
    required this.fromSlot,
    required this.toSlot,
    required this.byToken,
  });

  final int fromSlot;
  final int toSlot;
  final Map<String, String> byToken;

  String? match(Uint8List advertId) => byToken[ProximityIdentity.hex(advertId)];

  // ⚠️ **`covers` et `length` ont été RETIRÉS le 2026-08-28** : aucun appelant.
  // Cette table est reconstruite à chaque changement de créneau par
  // `PeerNetwork.tick`, donc elle couvre toujours l'instant présent — demander
  // à un objet toujours valide s'il est valide, c'est entretenir un doute que
  // sa construction a déjà levé.
}

/// Combien de créneaux de tolérance de part et d'autre du créneau courant.
///
/// Deux téléphones n'ont jamais exactement la même heure, et une annonce peut
/// être traitée juste après un changement de créneau. Un seul créneau de marge
/// de chaque côté suffit : à 15 minutes le créneau, cela laisse ±15 minutes.
const slotTolerance = 1;

/// Horizon du plan d'émission remis au natif.
///
/// ⚠️ **C'est la durée pendant laquelle l'appareil reste reconnaissable sans le
/// moindre code Dart vivant.** La choisir courte, c'est réintroduire le point H
/// avec un délai plus long ; la choisir longue coûte de la mémoire, et rien
/// d'autre — les jetons ne sont pas des secrets, ce sont des identifiants.
///
/// 12 h : couvre une nuit entière app fermée. À revoir sur mesure d'appareil.
const planHorizon = Duration(hours: 12);

/// Calcule le plan d'émission et la table de reconnaissance.
///
/// [secrets] : identifiant d'ami → secret de la paire, déjà dérivé
/// (`ProximityIdentity.pairSecrets`). Cette fonction ne dérive rien : un X25519
/// par créneau et par ami serait hors de prix, un HMAC ne l'est pas.
///
/// [pingSeed] : non nul **uniquement** si le mode ping est activé. C'est la
/// seule différence entre « je laisse mes amis me croiser » et « je me rends
/// découvrable » — deux choses distinctes qui partagent la même radio
/// (consigne de Jay, 2026-08-20).
class AdvertPlanner {
  const AdvertPlanner({this.tolerance = slotTolerance});

  final int tolerance;

  /// [meUserId] : **mon** identifiant de compte. C'est lui qui donne son sens à
  /// chaque jeton d'ami — voir [ProximityIdentity.pairToken].
  ///
  /// ⚠️ **`null` = on n'émet aucun jeton d'ami**, et c'est délibéré. Sans
  /// identifiant, la seule chose qu'on saurait crier est la valeur symétrique
  /// d'avant le 2026-08-26, que plus personne n'écoute : ce serait une radio
  /// bruyante et muette, indiscernable d'une radio saine. Le silence, lui, se
  /// constate. L'identifiant public du ping, qui ne dépend que d'une graine
  /// locale, part quand même.
  Future<AdvertPlan> plan({
    required Map<String, Uint8List> secrets,
    required int fromSlot,
    required int slots,
    required String? meUserId,
    Uint8List? pingSeed,
  }) async {
    final tokens = <AdvertToken>[];
    final toSlot = fromSlot + slots - 1;
    for (var slot = fromSlot; slot <= toSlot; slot++) {
      // L'identifiant public d'abord : quand le ping est actif, c'est lui qu'un
      // inconnu doit pouvoir capter vite. Les amis, eux, ont tout le temps —
      // ils nous croisent, ils ne nous cherchent pas.
      if (pingSeed != null) {
        tokens.add(
          AdvertToken(
            slot: slot,
            bytes: await ProximityIdentity.publicPingId(pingSeed, slot),
            audience: null,
          ),
        );
      }
      if (meUserId == null) continue;
      for (final entry in secrets.entries) {
        tokens.add(
          AdvertToken(
            slot: slot,
            // ⚠️ **C'est MOI qui émets** : le sens du jeton porte mon nom, pas
            // celui de l'ami. L'inverse rendrait les deux appareils sourds.
            bytes: await ProximityIdentity.pairToken(
              entry.value,
              slot,
              emitter: meUserId,
            ),
            audience: entry.key,
          ),
        );
      }
    }
    return AdvertPlan(fromSlot: fromSlot, toSlot: toSlot, tokens: tokens);
  }

  /// La table remise au NATIF : les mêmes jetons attendus, mais sur tout
  /// l'horizon et rangés à plat, par **rang** plutôt que par identifiant.
  ///
  /// ⚠️ **Le natif ne doit apprendre aucune identité.** D'où le rang : il
  /// renvoie « le rang 3 est passé », et c'est le Dart qui sait qui c'est. Lui
  /// donner les identifiants d'amis mettrait hors du Dart la liste de vos
  /// proches, pour un gain nul.
  ///
  /// ⚠️ **L'ordre est la seule chose qui relie un rang à une personne.** Il est
  /// donc rendu avec la table, et le tout est versionné : si le carnet change,
  /// la table change d'identifiant et les constats de l'ancienne sont jetés
  /// plutôt qu'attribués au hasard.
  Future<NativeRecognitionTable> nativeTable({
    required Map<String, Uint8List> secrets,
    required int fromSlot,
    required int slots,
    required int tableId,
  }) async {
    final ordre = secrets.keys.toList();
    final flat = Uint8List(
      slots * ordre.length * ProximityIdentity.tokenLength,
    );
    var pos = 0;
    for (var slot = fromSlot; slot < fromSlot + slots; slot++) {
      for (final userId in ordre) {
        // ⚠️ **C'est LUI qui émet** : on prépare ici ce qu'on s'attend à
        // ENTENDRE, donc le sens porte le nom de l'ami. Symétrique de `plan`.
        final token = await ProximityIdentity.pairToken(
          secrets[userId]!,
          slot,
          emitter: userId,
        );
        flat.setRange(pos, pos + ProximityIdentity.tokenLength, token);
        pos += ProximityIdentity.tokenLength;
      }
    }
    return NativeRecognitionTable(
      tableId: tableId,
      order: ordre,
      tokens: flat,
      fromSlot: fromSlot,
      slotCount: slots,
    );
  }

  /// La table de ce qu'on s'attend à recevoir, sur `[slot - tolérance,
  /// slot + tolérance]`.
  ///
  /// ⚠️ Bien plus petite que le plan d'émission : on ne prépare que trois
  /// créneaux, parce qu'un jeton reçu se juge **maintenant**. Préparer douze
  /// heures d'avance n'apporterait rien et coûterait douze heures de HMAC.
  Future<RecognitionTable> table({
    required Map<String, Uint8List> secrets,
    required int slot,
  }) async {
    final byToken = <String, String>{};
    for (var s = slot - tolerance; s <= slot + tolerance; s++) {
      for (final entry in secrets.entries) {
        // ⚠️ **C'est LUI qui émet** — même sens que `nativeTable`. Voir
        // [ProximityIdentity.pairToken].
        final token = await ProximityIdentity.pairToken(
          entry.value,
          s,
          emitter: entry.key,
        );
        byToken[ProximityIdentity.hex(token)] = entry.key;
      }
    }
    return RecognitionTable(
      fromSlot: slot - tolerance,
      toSlot: slot + tolerance,
      byToken: byToken,
    );
  }
}

/// La table telle qu'elle part au natif, **avec la clé de lecture des rangs**.
///
/// ⚠️ L'ordre et les jetons voyagent ensemble, et pour cause : séparés, un rang
/// deviendrait un nombre sans signification, interprétable par n'importe quelle
/// liste — donc faux sans qu'on puisse s'en apercevoir.
class NativeRecognitionTable {
  const NativeRecognitionTable({
    required this.tableId,
    required this.order,
    required this.tokens,
    required this.fromSlot,
    required this.slotCount,
  });

  /// Version de cette table. Revient avec chaque constat du natif.
  final int tableId;

  /// Rang → identifiant d'ami. **La seule clé de lecture des constats.**
  final List<String> order;

  final Uint8List tokens;
  final int fromSlot;
  final int slotCount;

  int get perSlot => order.length;

  // ⚠️ **`isEmpty` a été RETIRÉ le 2026-08-28** : aucun appelant. Le
  // superviseur ne construit cette table que lorsqu'il a des secrets, donc elle
  // n'est jamais vide à la sortie ; et le natif a le sien
  // (`AdvertSchedule.isEmpty`), qui porte sur le plan d'émission.

  /// Qui est le rang [index] ? `null` si le rang n'existe pas dans cette table.
  String? friendAt(int index) =>
      (index < 0 || index >= order.length) ? null : order[index];
}
