import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import '../ping_store.dart';
import '../proximity_identity.dart';
import 'connection_trace.dart';

/// La couche 7 : ce qui monte et descend entre l'appareil et le serveur.
///
/// ⚠️ **Trois gestes indépendants, trois déclencheurs.** Voir [_unSeul] :
/// les avoir fondus dans un seul appel coûtait 4 requêtes toutes les deux
/// secondes pour une information qui change une fois par quart d'heure.
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

  /// Ce qui est déjà en vol, par geste. Deux appels du même geste se
  /// recouvriraient sans rien apprendre de plus.
  final _enCours = <String>{};

  /// Au-delà, on considère l'échec définitif et on cesse de réessayer.
  ///
  /// Choisi large : le réseau mobile échoue souvent et légitimement. Ce qu'on
  /// cherche à borner, c'est l'élément qui ne passera **jamais**.
  static const maxAttempts = 8;

  // ⚠️ **`abandoned` a été SUPPRIMÉ le 2026-08-28.** Il était incrémenté à deux
  // endroits et **jamais lu** : son commentaire promettait « visible au
  // diagnostic », ce qui était faux. Ce qui rend l'abandon visible, c'est le
  // `ConnectionTrace.note` qui l'accompagne — et lui, il figure bien dans le
  // rapport, avec le motif et le type de l'élément.

  /// **Les trois gestes, ensemble.** Pour l'ouverture d'une session et la
  /// remise à zéro — les deux seuls moments où l'on ne sait rien de ce qui a
  /// changé, donc où tout mérite d'être refait.
  ///
  /// ⚠️ **Ne PAS rappeler ceci « pour être sûr ».** C'est exactement ce que
  /// faisait le balayage de constats, toutes les deux secondes.
  Future<void> run() async {
    await publishMyKey();
    await pushOutbox();
    await pullFriendBook();
  }

  /// **Ma clé publique.** Une fois par session, et c'est déjà généreux : elle
  /// vit dans le coffre-fort de l'appareil (`nv_x25519_seed`) et ne change
  /// jamais tant qu'on ne réinstalle pas.
  Future<void> publishMyKey() => _unSeul('clé', _publishKeys);

  /// **Ce qu'on doit au serveur** : constats de croisement et waves.
  ///
  /// Déclenché par l'arrivée de quelque chose de neuf dans la file, plus le
  /// filet périodique — qui est aussi ce qui **retente** un élément resté
  /// coincé faute de réseau.
  Future<void> pushOutbox() => _unSeul('file', _drainOutbox);

  /// **Le carnet d'amis.** Déclenché par un changement du graphe d'amis, plus
  /// le filet périodique. Voir `friend_book_watcher.dart`.
  Future<void> pullFriendBook() => _unSeul('carnet', _pullFriendKeys);

  /// ## 🔴 Pourquoi ces trois gestes ont été séparés le 2026-08-28
  ///
  /// Ils vivaient dans un `run()` unique, appelé depuis **sept** endroits — et
  /// notamment depuis le balayage de constats, **toutes les deux secondes**
  /// tant qu'un ami était à portée. Chaque passage coûtait quatre appels
  /// serveur, dont **un seul** avait quelque chose à dire :
  ///
  /// | Geste | Ce qu'il demande | Quand ça change |
  /// |---|---|---|
  /// | publier ma clé | ma clé publique | jamais |
  /// | vider la file | « j'ai vu X au créneau S » | à chaque créneau, au plus |
  /// | tirer le carnet | les clés et profils de mes amis | quand le graphe bouge |
  ///
  /// Trois rythmes dans un seul objet : c'est la règle de dissociation de Jay
  /// prise à l'envers — *« deux sources qui ne changent pas au même rythme ne
  /// partagent pas le même objet d'état »*. Le plus rapide imposait son rythme
  /// aux deux autres.
  ///
  /// ⚠️ **L'ordre file-puis-carnet a disparu avec eux, et c'est justifié.** Le
  /// commentaire d'origine l'imposait parce qu'un ami accepté en BLE n'existait
  /// côté serveur qu'une fois la file vidée : tirer le carnet avant l'aurait
  /// effacé. **Le BLE ne transporte plus de demande d'ami depuis le
  /// 2026-08-27** — vérifié par inventaire, la file ne reçoit plus que
  /// `sightings` et `wave` (`proximity_controller.dart`, deux `enqueue`), dont
  /// aucun ne crée d'amitié. La contrainte n'a pas été levée : sa cause a
  /// disparu.
  Future<void> _unSeul(
    String quoi,
    Future<void> Function(dynamic client, String me) geste,
  ) async {
    if (!_enCours.add(quoi)) return;
    try {
      final client = ref.read(supabaseProvider);
      final me = ref.read(currentUserIdProvider);
      if (me == null) return;
      await geste(client, me);
    } catch (_) {
      // Hors ligne : la file reste pleine, le carnet n'est PAS touché — un
      // carnet vidé parce que le réseau est tombé ferait disparaître tous les
      // amis. C'est le seul cas où ne rien dire à l'utilisateur est juste, et
      // le seul où le journal doit quand même le consigner.
      ConnectionTrace.note(ConnectionEvent.syncOffline, detail: quoi);
    } finally {
      _enCours.remove(quoi);
    }
  }

  /// Publie nos clés **publiques**. Il n'y a plus rien de secret ici.
  ///
  /// ⚠️ **C'est le changement de nature du 2026-08-20.** Cette table portait un
  /// secret — la clé de diffusion — qu'il fallait distribuer à tous les amis et
  /// remplacer dès que l'un d'eux partait. Elle ne porte plus que ce que le
  /// monde entier peut lire sans rien en tirer :
  ///
  /// - `x25519_pub` : pour que chaque ami dérive, de son côté, le secret **de
  ///   sa paire** avec nous. Sans sa propre clé privée, elle ne vaut rien.
  ///
  /// Conséquence pratique : republier est sans risque et sans effet de bord.
  /// C'est ce qui rend une réinstallation indolore — voir `_pullFriendKeys`.
  Future<void> _publishKeys(dynamic client, String me) async {
    await client.from('device_keys').upsert({
      'user_id': me,
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

    // Ce que le carnet sait déjà : sert de repli quand un profil est masqué.
    final connu = await _keyBook.all();
    final amis = <FriendKeys>[];
    for (final raw in rows) {
      final row = raw as Map<String, dynamic>;
      final userId = row['user_id'] as String;
      final profile = byId[userId];
      final x25519 = row['x25519_pub'] as String?;
      // ⚠️ **Un ami sans clé X25519 n'est PAS un ami parti.**
      //
      // C'est le cas d'un appareil resté sur l'ancien protocole, ou tout juste
      // réinstallé. Il est simplement non reconnaissable en attendant qu'il
      // republie — pas retiré. La distinction était vitale tant qu'une absence
      // déclenchait une révocation ; elle ne l'est plus, parce que la révocation
      // par rotation n'existe plus. La cause du faux positif a disparu avec elle.
      if (x25519 == null) continue;
      // ⚠️ **UN PROFIL INVISIBLE NE RETIRE PAS UN AMI.**
      //
      // Cette ligne faisait `if (profile == null) continue;` — donc une absence
      // de NOM faisait perdre une CLÉ. Constaté chez Jay le 2026-08-27 à
      // 20 h 58 : le blocage rendait le profil invisible, et le carnet d'amis
      // s'est vidé **des deux côtés**, arrêtant net la reconnaissance BLE.
      //
      // ⚠️ **C'est `device_keys` qui décide qui je reconnais**, et lui seul :
      // sa politique RLS ne rend que mes amis, et écarte ceux qui m'ont bloqué.
      // Une source d'affichage ne doit jamais pouvoir révoquer une capacité.
      //
      // C'est le même raisonnement que la ligne juste au-dessus pour la clé
      // X25519 — *« un ami sans clé n'est PAS un ami parti »* — qui manquait
      // ici d'une ligne.
      final nom =
          profile?['display_name'] as String? ?? connu[userId]?.username ?? '…';
      amis.add(
        FriendKeys(
          userId: userId,
          username: nom,
          tagName: profile?['tag_name'] as String?,
          avatarUrl: profile?['avatar_url'] as String?,
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
            //
            // ⚠️ **C'est ce qui absorbe les reliquats du transport BLE.** Les
            // appareils de Jay peuvent encore porter des `encounter` (certificat
            // de croisement) et des `connection` (demande d'ami co-signée)
            // déposés avant le 2026-08-27, dont les deux fonctions serveur sont
            // en fin de vie. Ils sont **abandonnés proprement et comptés**, au
            // lieu d'être retentés indéfiniment.
            ConnectionTrace.note(
              ConnectionEvent.outboxAbandoned,
              detail: 'type inconnu : ${item['type']}',
            );
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
          // ⚠️ **Une notification « Connexion non enregistrée » vivait ici,
          // et elle est devenue INATTEIGNABLE le 2026-08-27.**
          //
          // Elle prévenait l'utilisateur quand un `connection` — une demande
          // d'ami co-signée en BLE — mourait après `maxAttempts`. Il avait lu
          // « Vous êtes connectés » en acceptant : sans cette notification,
          // l'amitié n'existait pas et personne ne le lui disait.
          //
          // Ce type ne peut plus entrer dans la file : plus aucun producteur, et
          // il tomberait de toute façon dans `default` juste au-dessus, qui
          // `continue` avant de pouvoir lever. Un `if` que rien ne peut
          // satisfaire est un garde-fou qui rassure sans protéger.
          //
          // ⚠️ **Ce que la promesse est devenue** : accepter une demande est un
          // appel serveur direct, qui réussit ou lève **devant l'utilisateur**.
          // Il n'y a plus de file, donc plus d'échec différé et silencieux à
          // rattraper — la cause a disparu avec le chemin.
          continue;
        }
        remaining.add({...item, 'attempts': attempts, 'lastError': '$e'});
      }
    }
    await store.replaceOutbox(remaining);
  }
}

final proximitySyncProvider = Provider((ref) => ProximitySync(ref));
