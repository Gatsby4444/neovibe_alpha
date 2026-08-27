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

      // ⚠️ **Il n'y a plus rien à faire tourner** (2026-08-20).
      //
      // Cette ligne appelait `rotateBroadcastIfDue()` : la clé de diffusion,
      // partagée avec TOUS les amis, devait être remplacée tous les 7 jours et
      // à chaque révocation. C'est cette distribution qui créait le trou —
      // chaque rotation rendait invisible à tout ami qui n'avait pas
      // resynchronisé.
      //
      // Un secret par paire ne se distribue pas : il se calcule. Le serveur ne
      // reçoit plus que des clés **publiques**, qu'on peut republier autant
      // qu'on veut sans conséquence.
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

  /// Publie nos clés **publiques**. Il n'y a plus rien de secret ici.
  ///
  /// ⚠️ **C'est le changement de nature du 2026-08-20.** Cette table portait un
  /// secret — la clé de diffusion — qu'il fallait distribuer à tous les amis et
  /// remplacer dès que l'un d'eux partait. Elle ne porte plus que ce que le
  /// monde entier peut lire sans rien en tirer :
  ///
  /// - `ed_pub` : pour vérifier nos signatures ;
  /// - `x25519_pub` : pour que chaque ami dérive, de son côté, le secret **de
  ///   sa paire** avec nous. Sans sa propre clé privée, elle ne vaut rien.
  ///
  /// Conséquence pratique : republier est sans risque et sans effet de bord.
  /// C'est ce qui rend une réinstallation indolore — voir `_pullFriendKeys`.
  Future<void> _publishKeys(dynamic client, String me) async {
    await client.from('device_keys').upsert({
      'user_id': me,
      'ed_pub': base64Encode(await _identity.edPublicKey()),
      'x25519_pub': base64Encode(await _identity.x25519PublicKey()),
    });
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
      if (avant > 0) {
        ConnectionTrace.note(
          ConnectionEvent.friendsRemoved,
          detail: '$avant retiré(s)',
        );
      }
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
      final x25519 = row['x25519_pub'] as String?;
      // ⚠️ **Un ami sans clé X25519 n'est PAS un ami parti.**
      //
      // C'est le cas d'un appareil resté sur l'ancien protocole, ou tout juste
      // réinstallé. Il est simplement non reconnaissable en attendant qu'il
      // republie — pas retiré. La distinction était vitale tant qu'une absence
      // déclenchait une révocation ; elle ne l'est plus, parce que la révocation
      // par rotation n'existe plus. La cause du faux positif a disparu avec elle.
      if (x25519 == null) continue;
      amis.add(
        FriendKeys(
          userId: row['user_id'] as String,
          username: profile['display_name'] as String,
          tagName: profile['tag_name'] as String?,
          avatarUrl: profile['avatar_url'] as String?,
          edPublicKey: Uint8List.fromList(
            base64Decode(row['ed_pub'] as String),
          ),
          // ⚠️ **La clé publique de l'ami, telle que le serveur la donne
          // MAINTENANT.** On ne stocke aucun secret dérivé : il se recalcule à
          // partir d'elle. C'est ce qui rend une réinstallation indolore — sa
          // nouvelle clé arrive ici, le secret de la paire suit tout seul, et il
          // n'y a rien à invalider ni à penser à mettre à jour.
          x25519PublicKey: Uint8List.fromList(base64Decode(x25519)),
        ),
      );
    }

    // ⚠️ **La révocation ne coûte plus rien, et c'est le gain principal.**
    //
    // Ce bloc faisait tourner notre clé de diffusion dès qu'un ami disparaissait
    // de la liste — donc aveuglait **tous les autres** jusqu'à leur prochaine
    // synchronisation (RAPPELS #46 ②). Il fallait en plus se méfier des faux
    // positifs : une donnée manquante ressemblait à un départ.
    //
    // Avec un secret par paire, retirer un ami est **local et total** : son
    // secret n'est plus dérivé, son jeton n'est plus émis, et il n'a plus rien
    // à reconnaître. Personne d'autre n'est affecté, et il n'y a aucune fenêtre
    // pendant laquelle il nous verrait encore. `replace` suffit.
    final avant = (await _keyBook.all()).keys.toSet();
    final partis = avant.difference(amis.map((a) => a.userId).toSet());

    await _keyBook.replace(amis);
    ConnectionTrace.count(ConnectionTrace.friendsPulled);

    if (partis.isNotEmpty) {
      ConnectionTrace.note(
        ConnectionEvent.friendsRemoved,
        detail: '${partis.length} retiré(s)',
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
          // ⚠️ **`encounter` et `connection` ont été retirés le 2026-08-27**,
          // avec le transport BLE qui les produisait : un certificat de
          // croisement co-signé (`report_encounter`) et une demande d'ami
          // co-signée (`submit_ble_connection`). Plus rien ne les met en file.
          //
          // Un cas de `switch` sans producteur n'est pas inoffensif : il fait
          // croire que le chemin existe encore, et il maintient vivantes deux
          // fonctions serveur que plus personne n'appelle (consignées dans
          // `RAPPELS.md`).
          // ⚠️ **Les constats partent en LOT, et ils ne prouvent rien seuls.**
          //
          // Le serveur ne cree un croisement que si le constat inverse existe
          // aussi (fonction `report_sightings`). Un envoi unilateral n'a donc
          // aucun effet observable — c'est la propriete anti-traque, et elle
          // est tenue en base, pas ici : le client ne peut pas s'en dispenser.
          case 'sightings':
            await client.rpc(
              'report_sightings',
              params: {'items': item['items']},
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
