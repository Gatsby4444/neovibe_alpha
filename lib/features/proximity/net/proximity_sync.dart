import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/notification_service.dart';
import '../../../core/supabase_providers.dart';
import '../ping_store.dart';
import '../proximity_identity.dart';
import 'connection_trace.dart';

/// La couche 7 : ce qui remonte au serveur quand internet revient.
///
/// ## Les trois défauts qu'elle corrige
///
/// **1. Un N+1 sur les profils.** L'ancienne synchro récupérait les clés en un
/// appel, puis faisait **une requête `profiles` par ami**, séquentiellement,
/// dans une boucle `await`. À 200 amis : 200 allers-retours réseau, à chaque
/// activation du ping, à chaque wave et à chaque croisement. Ici : **deux**
/// requêtes, quel que soit le nombre d'amis.
///
/// **2. Une file d'envoi qui retentait l'impossible pour toujours.** Le
/// `catch (_)` d'origine ne distinguait pas « pas de réseau » (à retenter) de
/// « le serveur refuse » (à abandonner). Un enregistrement rejeté — signature
/// invalide, RLS — restait dans la file **indéfiniment** et repartait à chaque
/// synchronisation.
///
/// **3. Rien ne disait jamais qu'un envoi avait échoué pour de bon.** Un
/// élément abandonné est désormais **compté**, et le nombre est lisible : une
/// perte silencieuse est exactement ce qu'on supprime partout dans ce chantier.
class ProximitySync {
  ProximitySync(this.ref);

  final Ref ref;

  /// ⚠️ **Le carnet ET l'identité viennent des providers.** Ces champs valaient
  /// un `new` local : la synchro écrivait dans **son** cache pendant que le
  /// contrôleur et le réseau gardaient le leur, et publiait potentiellement au
  /// serveur une clé de diffusion différente de celle réellement diffusée.
  FriendKeyStore get _keyBook => ref.read(friendBookProvider);
  ProximityIdentity get _identity => ref.read(proximityIdentityProvider);

  var _running = false;

  /// Au-delà, on considère l'échec définitif et on cesse de réessayer.
  ///
  /// Choisi large : le réseau mobile échoue souvent et légitimement. Ce qu'on
  /// cherche à borner, c'est l'élément qui ne passera **jamais**.
  static const maxAttempts = 8;

  /// Éléments abandonnés depuis le lancement — visible au diagnostic.
  var abandoned = 0;

  Future<void> run() async {
    if (_running) return;
    _running = true;
    try {
      final client = ref.read(supabaseProvider);
      final me = ref.read(currentUserIdProvider);
      if (me == null) return;

      // ⚠️ **La clé de diffusion tourne, et elle ne tournait pas.**
      //
      // Écrite une fois à l'installation, plus jamais régénérée : un ex-ami qui
      // l'avait téléchargée nous reconnaissait **à vie**, hors ligne et en
      // silence. La RLS l'empêche de la relire ; elle ne reprend pas ce qu'il a
      // déjà. Pour une app dont la thèse est le cercle restreint, retirer un ami
      // ne retirait rien.
      //
      // Période : 7 jours (décision de Jay, 2026-08-18).
      await _identity.rotateBroadcastIfDue();
      await _publishKeys(client, me);

      // ⚠️ **La file d'abord, le carnet ensuite. L'ordre est le correctif.**
      //
      // `_pullFriendKeys` REMPLACE désormais le carnet par ce que le serveur
      // renvoie (sinon un ami retiré resterait un ami pour toujours). Or un ami
      // tout juste accepté en BLE n'existe côté serveur qu'une fois la file
      // vidée : dans l'ordre inverse, on l'aurait effacé du carnet **juste
      // avant** de le créer.
      await _drainOutbox(client, me);
      await _pullFriendKeys(client, me);
    } catch (_) {
      // Hors ligne : tout reste en file, on réessaiera. C'est le seul cas où
      // ne rien dire est juste. Le carnet n'est PAS touché — un carnet vidé
      // parce que le réseau est tombé ferait disparaître tous les amis.
      ConnectionTrace.note(ConnectionEvent.syncOffline);
    } finally {
      _running = false;
    }
  }

  /// Publie nos deux clés de diffusion : la courante et la précédente.
  ///
  /// ⚠️ **La précédente n'est pas une commodité.** Sans elle, chaque rotation
  /// aveuglerait tous nos amis jusqu'à leur prochaine synchronisation : ils
  /// indexeraient une clé que nous n'utilisons plus, et nous deviendrions un
  /// inconnu pour tout le monde pendant ce temps. En les publiant toutes les
  /// deux, la rotation ne se voit pas.
  ///
  /// Une **révocation**, elle, jette délibérément la précédente : voir
  /// [_revokeBroadcast].
  Future<void> _publishKeys(dynamic client, String me) async {
    final previous = await _identity.previousBroadcastKey();
    await client.from('device_keys').upsert({
      'user_id': me,
      'ed_pub': base64Encode(await _identity.edPublicKey()),
      'broadcast_key': base64Encode(await _identity.broadcastKey()),
      'broadcast_key_prev': previous == null ? null : base64Encode(previous),
      'rotated_at': (await _identity.broadcastRotatedAt()).toIso8601String(),
    });
  }

  /// Quelqu'un a perdu le droit de nous reconnaître : on change de clé **et on
  /// jette l'ancienne**.
  ///
  /// ⚠️ **C'est le seul moyen de reprendre ce qui a déjà été distribué.** Une
  /// clé de diffusion n'est pas un droit de lecture qu'on révoque côté serveur :
  /// c'est un secret que l'autre a copié sur son appareil. Tant qu'elle ne
  /// change pas, aucune politique RLS n'empêche quoi que ce soit.
  ///
  /// Contrepartie assumée : nos autres amis ne nous reconnaissent plus jusqu'à
  /// leur prochaine synchronisation — qui tourne au lancement de l'app et à
  /// chaque croisement.
  Future<void> _revokeBroadcast(dynamic client, String me, int partis) async {
    await _identity.rotateBroadcast(keepPrevious: false);
    await _publishKeys(client, me);
    ConnectionTrace.note(
      ConnectionEvent.friendsRemoved,
      detail: '$partis retiré(s) — clé de diffusion révoquée',
    );
  }

  /// Rapatrie les clés de reconnaissance des amis — **en deux requêtes**.
  ///
  /// ⚠️ **Ce que `device_keys` renvoie EST la liste d'amis, et rien au point
  /// d'appel ne le dit.** La politique RLS `device_keys_friends` restreint la
  /// lecture aux `connections` en `status = 'full'` ; le client, lui, écrit
  /// « prends tout sauf moi ». La définition d'« ami » côté application vit donc
  /// dans une politique du serveur. C'est vrai, c'est vérifié en base le
  /// 2026-08-17 — et c'est écrit ici parce qu'un jour quelqu'un relâchera cette
  /// politique et croira n'avoir touché qu'à de la lecture.
  ///
  /// ⚠️ **On REMPLACE, on n'ajoute pas.** `put` seul faisait qu'une amitié
  /// rompue restait vraie sur l'appareil pour toujours : on continuait de
  /// reconnaître la personne à son ID rotatif et de la présenter comme une amie.
  Future<void> _pullFriendKeys(dynamic client, String me) async {
    final rows =
        await client.from('device_keys').select().neq('user_id', me) as List;

    if (rows.isEmpty) {
      // Le serveur dit « aucun ami ». C'est une réponse, pas une absence de
      // réponse — une erreur réseau aurait levé et nous aurait envoyés dans le
      // `catch` de `run()`, qui ne touche pas au carnet.
      final avant = (await _keyBook.all()).length;
      await _keyBook.replace(const []);
      if (avant > 0) await _revokeBroadcast(client, me, avant);
      return;
    }

    final ids = rows
        .map((r) => (r as Map<String, dynamic>)['user_id'] as String)
        .toList();

    // ⚠️ UNE requête pour tous les profils, au lieu d'une par ami.
    final profiles =
        await client
                .from('profiles')
                .select('id, display_name, tag_name, avatar_url')
                .inFilter('id', ids)
            as List;
    final byId = {
      for (final p in profiles) (p as Map<String, dynamic>)['id'] as String: p,
    };

    final amis = <FriendKeys>[];
    for (final raw in rows) {
      final row = raw as Map<String, dynamic>;
      final profile = byId[row['user_id'] as String];
      if (profile == null) continue;
      final broadcast = row['broadcast_key'] as String?;
      // Un ami qui n'a pas encore publié sa clé de diffusion ne peut pas être
      // reconnu en silence. Le garder sans clé ferait planter l'index rotatif ;
      // l'omettre le rend simplement invisible jusqu'à sa prochaine connexion.
      if (broadcast == null) continue;
      final previous = row['broadcast_key_prev'] as String?;
      amis.add(
        FriendKeys(
          userId: row['user_id'] as String,
          username: profile['display_name'] as String,
          tagName: profile['tag_name'] as String?,
          avatarUrl: profile['avatar_url'] as String?,
          edPublicKey: Uint8List.fromList(
            base64Decode(row['ed_pub'] as String),
          ),
          broadcastKey: Uint8List.fromList(base64Decode(broadcast)),
          // La clé d'avant sa dernière rotation : c'est elle qui fait qu'un ami
          // qui vient de tourner reste reconnu tant que nous n'avons pas
          // resynchronisé.
          previousBroadcastKey: previous == null
              ? null
              : Uint8List.fromList(base64Decode(previous)),
        ),
      );
    }

    final avant = (await _keyBook.all()).keys.toSet();
    final apres = amis.map((a) => a.userId).toSet();
    final partis = avant.difference(apres);

    await _keyBook.replace(amis);
    ConnectionTrace.count(ConnectionTrace.friendsPulled);

    // ⚠️ **Un ami retiré doit cesser de nous reconnaître, et retirer sa ligne
    // ne suffit pas** : il a déjà notre clé de diffusion sur son appareil. On la
    // change, et on jette l'ancienne.
    if (partis.isNotEmpty) await _revokeBroadcast(client, me, partis.length);
  }

  /// Vide la file, en distinguant ce qui mérite une nouvelle tentative.
  Future<void> _drainOutbox(dynamic client, String me) async {
    final store = ref.read(pingStoreProvider);
    final pending = await store.outbox();
    final remaining = <Map<String, dynamic>>[];

    for (final item in pending) {
      try {
        switch (item['type']) {
          case 'encounter':
            await client.rpc(
              'report_encounter',
              params: {'cert': item['certificate']},
            );
          case 'connection':
            await client.rpc(
              'submit_ble_connection',
              params: {'record': item['record']},
            );
          case 'wave':
            await client.from('waves').insert({
              'user_id': me,
              'peer_id': item['peerId'],
              'notify_after': item['notifyAfter'],
            });
          default:
            // Type inconnu : il ne partira jamais. L'abandonner tout de suite
            // vaut mieux que de le traîner à chaque synchronisation.
            ConnectionTrace.note(
              ConnectionEvent.outboxAbandoned,
              detail: 'type inconnu : ${item['type']}',
            );
            abandoned++;
            continue;
        }
      } catch (e) {
        final attempts = (item['attempts'] as int? ?? 0) + 1;
        if (attempts >= maxAttempts) {
          // Échec définitif : on abandonne, et on le COMPTE. Retenter à
          // l'infini n'aurait jamais rien changé qu'à la facture réseau.
          ConnectionTrace.note(
            ConnectionEvent.outboxAbandoned,
            detail: '${item['type']} après $attempts tentatives — $e',
          );
          // ⚠️ **Une CONNEXION abandonnée ne peut pas partir en silence.**
          //
          // L'utilisateur a lu « Vous êtes connectés » au moment d'accepter :
          // c'est la promesse la plus forte du produit. Si l'enregistrement
          // n'atteint jamais le serveur, l'amitié n'existe pas — et personne ne
          // le lui dit. Les autres types (croisement, wave) sont du confort ;
          // celui-ci est le mécanisme d'entrée.
          if (item['type'] == 'connection') {
            await NotificationService.instance.schedule(
              NotifChannel.waves,
              'Connexion non enregistrée',
              'Une connexion faite en proximité n\'a pas pu être enregistrée. '
                  'Recroisez-vous pour réessayer.',
              DateTime.now(),
            );
          }
          abandoned++;
          continue;
        }
        remaining.add({...item, 'attempts': attempts, 'lastError': '$e'});
      }
    }
    await store.replaceOutbox(remaining);
  }
}

final proximitySyncProvider = Provider((ref) => ProximitySync(ref));
