import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  final _identity = ProximityIdentity();

  /// ⚠️ **Le carnet vient du provider.** Ce champ valait `FriendKeyBook()` :
  /// la synchro écrivait alors dans **son** cache et dans le fichier, pendant
  /// que le contrôleur et le réseau gardaient le leur, chargé au démarrage. Les
  /// clés téléchargées ici n'atteignaient jamais l'app.
  FriendKeyStore get _keyBook => ref.read(friendBookProvider);

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

      await client.from('device_keys').upsert({
        'user_id': me,
        'ed_pub': base64Encode(await _identity.edPublicKey()),
        'broadcast_key': base64Encode(await _identity.broadcastKey()),
      });

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
      if (avant > 0) {
        ConnectionTrace.note(
          ConnectionEvent.friendsRemoved,
          detail: '$avant retiré(s), le serveur n\'en renvoie aucun',
        );
      }
      await _keyBook.replace(const []);
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
        ),
      );
    }

    final avant = (await _keyBook.all()).keys.toSet();
    final apres = amis.map((a) => a.userId).toSet();
    final partis = avant.difference(apres);
    if (partis.isNotEmpty) {
      ConnectionTrace.note(
        ConnectionEvent.friendsRemoved,
        detail: '${partis.length} retiré(s)',
      );
    }

    await _keyBook.replace(amis);
    ConnectionTrace.count(ConnectionTrace.friendsPulled);
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
