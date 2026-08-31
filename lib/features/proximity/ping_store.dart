import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'proximity_identity.dart';

/// Ce que le ping garde **sur l'appareil**, et qui n'a pas de ligne serveur.
///
/// Il ne reste qu'une chose : la **file d'envoi** — ce qui doit remonter au
/// serveur au retour d'internet (constats de croisement, waves).
///
/// ## ⚠️ Ce qui a été retiré le 2026-08-27
///
/// | Ce qui est parti | Pourquoi |
/// |---|---|
/// | les **conversations ping** (un fichier par pair, TTL 12 h, règle anti-spam) | la messagerie de proximité passe par le serveur |
/// | les **croisements locaux** (`LocalEncounter`) | le croisement est un constat mutuel côté serveur, pas un certificat co-signé |
///
/// ⚠️ **Vérifié en base avant de couper, pas déduit** : la table `encounters`
/// est bien remplie par `report_sightings`, et sa seule ligne porte
/// `proof = 'mutual_sighting'` — alors que le défaut de la colonne est
/// `'certificate'`. Le certificat BLE n'a donc **jamais** rien produit en deux
/// mois, et rien ne lit `proof` : `can_view_profile` et `can_view_stories` ne
/// testent que l'existence de la ligne.
///
/// La règle anti-spam part avec les conversations. Elle protégeait d'un inconnu
/// insistant **dans un fil local que nous seuls arbitrions** ; un fil serveur a
/// ses propres règles, et en garder une seconde, muette et invisible, c'était
/// deux arbitres pour une même conversation.
/// ⚠️ **N'est plus un `ChangeNotifier` depuis le 2026-08-27.**
///
/// Son unique observateur était `PingScreen`, qui rechargeait conversations et
/// croisements à chaque écriture. Les deux ont disparu avec le transport BLE :
/// ce qui reste — la file d'envoi — n'a **aucun lecteur d'interface**, elle est
/// drainée par `proximity_sync`. Un notifieur que personne n'écoute est un
/// nœud orphelin qui donne l'illusion qu'un écran se met à jour.
class PingStore {
  PingStore();

  Directory? _dir;

  Future<Directory> _root() async {
    if (_dir != null) return _dir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}ping');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Efface TOUT le local du ping.
  ///
  /// ⚠️ **Appelé au changement de compte.** Ces fichiers ne portent pas
  /// d'identifiant de propriétaire : sans effacement, le compte suivant
  /// hériterait de la file d'envoi du précédent. Il vide le dossier entier, donc
  /// il emporte aussi les reliquats du chat BLE (`chat_*.json`,
  /// `encounters.json`) restés sur les appareils d'avant le 2026-08-27.
  Future<void> wipe() async {
    final dir = await _root();
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        if (entry is File) await entry.delete();
      }
    }
  }

  // ⚠️ **`conversation`, `conversations`, `append`, `_write`, `sweep`,
  // `_chatFile`, `encounters`, `addEncounter` et `_encountersFile` ont été
  // SUPPRIMÉES le 2026-08-27**, avec le transport BLE qui les alimentait.
  //
  // `conversation` et `conversations` étaient déjà **sans aucun appelant**
  // depuis le retrait de la section « Conversations ping » du 2026-08-27 : elles
  // lisaient un magasin que plus personne n'écrivait.

  // ------------------------------------------------------------------
  // Outbox serveur (au retour d'internet)
  // ------------------------------------------------------------------

  Future<File> _outboxFile() async =>
      File('${(await _root()).path}${Platform.pathSeparator}outbox.json');

  Future<List<Map<String, dynamic>>> outbox() async {
    try {
      final file = await _outboxFile();
      if (!await file.exists()) return [];
      return (jsonDecode(await file.readAsString()) as List)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Au-delà, les plus anciens éléments partent.
  ///
  /// ## 🔴 Il n'y avait AUCUNE borne — corrigé le 2026-08-31
  ///
  /// `_sweepSightings` dépose un lot dès qu'il constate du nouveau, et
  /// `pushOutbox` échoue **en silence** hors ligne (`_unSeul` avale). Le
  /// compteur de tentatives ne monte donc pas — il ne monte qu'à un envoi
  /// *tenté* — et rien n'abandonne jamais rien : la file grossissait tant que
  /// le réseau manquait.
  ///
  /// ⚠️ **Et le coût est quadratique** : chaque dépôt relit puis réécrit le
  /// fichier ENTIER. Le millième élément coûte mille fois le premier. C'est le
  /// genre de défaut qui ne se voit qu'après plusieurs jours hors ligne, chez
  /// quelqu'un qu'on n'a pas sous la main.
  ///
  /// 500 : très au-delà de ce qu'un usage normal accumule (un constat par ami
  /// et par créneau de 15 min), et le serveur **refuse** de toute façon un
  /// constat vieux de plus de 48 h (`report_sightings`). Ce qui déborde était
  /// déjà périmé.
  static const outboxMax = 500;

  Future<void> enqueue(Map<String, dynamic> item) async {
    final list = await outbox();
    list.add(item);
    // Les plus VIEUX partent : ce sont eux que le serveur refuserait.
    if (list.length > outboxMax) {
      list.removeRange(0, list.length - outboxMax);
    }
    await (await _outboxFile()).writeAsString(jsonEncode(list));
  }

  Future<void> replaceOutbox(List<Map<String, dynamic>> items) async {
    await (await _outboxFile()).writeAsString(jsonEncode(items));
  }
}

/// ChangeNotifier minimal sans dépendre de Flutter (testable en pur Dart).
/// Instantané du profil d'un pair présent à côté de nous.
///
/// ⚠️ **Il venait du BLE jusqu'au 2026-08-27** — un mini-profil signé, reçu
/// dans le canal chiffré. Il ne peut plus venir que du **carnet d'amis**, donc
/// d'un ami reconnu à son jeton : la radio n'apprend plus rien sur un inconnu.
/// [verified] est donc toujours vrai en pratique ; il reste parce que le champ
/// est persisté dans la file d'envoi et qu'un jour il redeviendra une vraie
/// question (attestation serveur, `RAPPELS.md` #2).
class PingPeerSnapshot {
  const PingPeerSnapshot({
    required this.userId,
    required this.username,
    this.tagName,
    this.verified = false,
  });

  final String userId;
  final String username;
  final String? tagName;

  /// Identité vérifiée côté serveur (sinon « profil non vérifié » : hors
  /// ligne, rien n'empêche techniquement d'usurper un username — signalé à
  /// Jay, l'attestation serveur signée est une amélioration future).
  final bool verified;

  String get displayName =>
      (tagName != null && tagName!.isNotEmpty) ? tagName! : username;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    'tagName': tagName,
    'verified': verified,
  };

  factory PingPeerSnapshot.fromJson(Map<String, dynamic> json) =>
      PingPeerSnapshot(
        userId: json['userId'] as String,
        username: json['username'] as String,
        tagName: json['tagName'] as String?,
        verified: json['verified'] as bool? ?? false,
      );
}

final pingStoreProvider = Provider((ref) => PingStore());

/// **LE** carnet d'amis de l'app. Un seul, et c'est tout l'intérêt.
///
/// ⚠️ **Ne jamais écrire `FriendKeyBook()` ailleurs que dans un test.**
///
/// Le 2026-08-17, trois instances coexistaient — contrôleur, synchronisation, et
/// le défaut de `PeerNetwork` — chacune avec son cache mémoire. La
/// synchronisation écrivait les clés téléchargées du serveur avec la sienne ;
/// les deux autres avaient déjà chargé le fichier et ne le relisaient jamais.
/// **Un ami s'affichait donc comme un inconnu**, avec un bouton « demander à se
/// connecter », jusqu'au prochain lancement de l'app.
///
/// Le cache n'était pas le défaut : le défaut était qu'un objet à état partagé
/// se construisait avec `new` à trois endroits. Un provider supprime la cause ;
/// une règle de relecture ne l'aurait qu'écartée.
final friendBookProvider = Provider<FriendKeyStore>((ref) => FriendKeyBook());

/// Suis-je ami avec cette personne ?
///
/// ⚠️ **Le seul endroit de l'app qui répond à cette question.**
///
/// Elle se **dérive** du carnet, elle ne se **recopie** nulle part. C'est la
/// différence qui a coûté la panne du 2026-08-17 : `PeerNetwork` calculait
/// `isFriend`, l'émettait dans `PeerIdentified`, et `markIdentified` ne le
/// rangeait pas dans l'entrée de présence — que le bouton lisait. La réponse
/// était juste, et personne ne la lisait au bon endroit.
///
/// La règle qui en sort, et qui rend le défaut impossible plutôt que corrigé :
/// **la présence dit OÙ et À QUELLE DISTANCE, jamais QUI.**
final isFriendProvider = StreamProvider.family<bool, String>((ref, userId) {
  final book = ref.watch(friendBookProvider);
  final controller = StreamController<bool>();
  // ⚠️ **Le test de fermeture doit venir APRÈS l'attente, pas avant.**
  //
  // Il ne se faisait qu'en tête de `emit` : entre ce test et le `add`, il y a
  // une lecture du carnet, donc un `await`. Si la disposition tombait dans cet
  // intervalle — un écran fermé pendant que le carnet se relit — `add` levait
  // un `StateError` **asynchrone et non rattrapé**, puisque le `Future` de cet
  // écouteur n'est attendu par personne (défaut relevé le 2026-08-28).
  var ferme = false;

  Future<void> emit() async {
    final ami = (await book.all()).containsKey(userId);
    if (ferme || controller.isClosed) return;
    controller.add(ami);
  }

  book.changes.addListener(emit);
  ref.onDispose(() {
    ferme = true;
    book.changes.removeListener(emit);
    controller.close();
  });
  unawaited(emit());
  return controller.stream;
});
