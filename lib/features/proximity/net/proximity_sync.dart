import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import '../ping_store.dart';
import '../proximity_identity.dart';

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
  final _keyBook = FriendKeyBook();

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

      await _pullFriendKeys(client, me);
      await _drainOutbox(client, me);
    } catch (_) {
      // Hors ligne : tout reste en file, on réessaiera. C'est le seul cas où
      // ne rien dire est juste.
    } finally {
      _running = false;
    }
  }

  /// Rapatrie les clés de reconnaissance des amis — **en deux requêtes**.
  Future<void> _pullFriendKeys(dynamic client, String me) async {
    final rows =
        await client.from('device_keys').select().neq('user_id', me) as List;
    if (rows.isEmpty) return;

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

    for (final raw in rows) {
      final row = raw as Map<String, dynamic>;
      final profile = byId[row['user_id'] as String];
      if (profile == null) continue;
      await _keyBook.put(
        FriendKeys(
          userId: row['user_id'] as String,
          username: profile['display_name'] as String,
          tagName: profile['tag_name'] as String?,
          avatarUrl: profile['avatar_url'] as String?,
          edPublicKey: Uint8List.fromList(
            base64Decode(row['ed_pub'] as String),
          ),
          broadcastKey: Uint8List.fromList(
            base64Decode(row['broadcast_key'] as String),
          ),
        ),
      );
    }
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
            abandoned++;
            continue;
        }
      } catch (e) {
        final attempts = (item['attempts'] as int? ?? 0) + 1;
        if (attempts >= maxAttempts) {
          // Échec définitif : on abandonne, et on le COMPTE. Retenter à
          // l'infini n'aurait jamais rien changé qu'à la facture réseau.
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
