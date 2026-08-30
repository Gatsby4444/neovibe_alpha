import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/notification_service.dart';
import '../../../core/supabase_providers.dart';
import '../ping_store.dart';
import '../nearby_people.dart';
import '../presence_feed.dart';
import '../proximity_identity.dart';
import '../../connections/connections_repository.dart';
import 'connection_trace.dart';
import 'peer_network.dart';
import '../../connections/friendships_repository.dart';
import 'presque_delai.dart';
import 'wave_rules.dart';
import 'peer_session.dart';
import 'presence_book.dart';
import 'proximity_journal.dart';
import 'ble_radio.dart';
import 'distance_estimate.dart';
import 'proximity_supervisor.dart';
import 'proximity_sync.dart';
import 'radio_status.dart';
import 'sighting_log.dart';

/// Le chef d'orchestre : il branche la radio sur la présence, et la présence
/// sur les fonctions du produit.
///
/// ## Ce qu'il porte, et ce qu'il délègue
///
/// Il **décide** (quand constater un croisement, quand envoyer un wave) et il
/// **range** (magasin local, file d'envoi serveur). Il ne touche pas à la radio.
///
/// ## ⚠️ Ce qui a changé le 2026-08-27
///
/// Il portait aussi tout ce qui voyageait dans le canal BLE : messagerie de
/// proximité, demandes d'amis émises et reçues, acceptations co-signées,
/// certificats de croisement. Ces quatre fonctions ont un chemin serveur
/// depuis le 2026-08-27, et le canal est supprimé — voir `peer_network.dart`.
///
/// ⚠️ **Ce n'est pas un allègement, c'est un déplacement de la barrière.** « On
/// ne demande en ami que quelqu'un qu'on a physiquement rencontré » était
/// garanti par la portée de la radio ; c'est désormais une **règle serveur**
/// (`request_connection_from_proximity`), et une règle peut être contournée si
/// on l'oublie. Voir `RAPPELS.md` #70.
class ProximityController extends AsyncNotifier<void> {
  PeerNetwork? _network;
  StreamSubscription<RadioEvent>? _radioFeed;
  StreamSubscription<PeerEvent>? _peerFeed;
  Timer? _sightingSweep;

  final _journal = ProximityJournal();

  /// ⚠️ **Le carnet ET l'identité viennent des providers.**
  ///
  /// Les deux valaient un `new` local. Trois carnets coexistaient le
  /// 2026-08-17 ; cinq identités le 2026-08-18, avec une course au premier
  /// lancement capable de faire diverger la clé diffusée de celle publiée au
  /// serveur. Un objet à état partagé n'a qu'un point de construction.
  FriendKeyStore get _keyBook => ref.read(friendBookProvider);
  ProximityIdentity get _identity => ref.read(proximityIdentityProvider);

  /// Un seul wave par personne et par fenêtre. **Persisté** depuis le
  /// 2026-08-16 : en mémoire, redémarrer l'app suffisait à renotifier.
  static const waveCooldown = Duration(hours: 2);

  /// Le compte auquel le local du ping appartient actuellement.
  String? _boundUserId;

  /// ⚠️ **Relevé pendant `build`, jamais pendant `onDispose`.** [_teardown]
  /// s'exécute au démontage du provider ; y lire un autre provider revient à
  /// interroger un conteneur peut-être en cours de destruction. On garde donc
  /// la référence prise pendant qu'on avait le droit de la prendre.
  PresenceFeed? _presence;

  @override
  Future<void> build() async {
    // ⚠️ **On ne surveille QUE le compte.**
    //
    // Ce `build` surveillait l'état de la radio (`ref.watch` du superviseur).
    // Or Riverpod ré-exécute `build` à chaque changement de ce qu'il surveille,
    // **et déclenche d'abord les `onDispose` de l'exécution précédente**. Chaque
    // transition d'état — et il y en a au moins deux à chaque démarrage,
    // `starting` puis `running` — **détruisait donc le réseau de pairs**
    // aussitôt créé. Le champ `_network`, lui, restait non nul : `_ensureNetwork`
    // repartait immédiatement, satisfait, en laissant l'app branchée sur un
    // objet mort. Plus aucun scan, plus aucun événement, pour toujours.
    //
    // La règle qui en sort : **une référence qui pointe vers un objet détruit
    // doit être remise à nul dans le même geste**. Un champ non nul vers un
    // cadavre est un nœud orphelin — il ment à tous ceux qui le consultent.
    final me = ref.watch(currentUserIdProvider);
    _presence = ref.read(presenceProvider.notifier);
    ref.onDispose(_teardown);

    // ⚠️ **Changement de compte : on efface le local du ping.**
    //
    // Rien ne le faisait — `signOut()` ne nettoyait que la session serveur.
    // Or le carnet de clés, les croisements et le cooldown des waves sont des
    // fichiers **sans propriétaire inscrit** : un compte B ouvert sur le même
    // appareil héritait de tout, et reconnaissait **silencieusement** les amis
    // du compte A grâce à leurs clés de diffusion.
    //
    // Pour une app dont la thèse est le cercle restreint, c'est une fuite. Les
    // méthodes d'effacement existaient déjà côté magasins ; **personne ne les
    // appelait** — un nœud orphelin, au sens exact du terme.
    if (_boundUserId != null && _boundUserId != me) await _forgetLocalPing();
    _boundUserId = me;

    // ⚠️ **`listen`, jamais `watch`.** Surveiller le superviseur ici
    // ré-exécuterait ce `build` à chaque changement d'état de la radio — donc
    // détruirait puis reconstruirait le réseau de pairs deux fois par
    // démarrage. C'est exactement la panne décrite plus haut. `ref.listen`
    // observe sans reconstruire : le consommateur choisit ce qui l'intéresse.
    ref.listen(proximitySupervisorProvider.select((r) => r.wantsFriends), (
      _,
      veut,
    ) {
      _appliquerBalayage(veut);
    });

    if (me != null) await _ensureNetwork();

    // ⚠️ **Un tour TOUT DE SUITE, avant d'armer le minuteur.** L'app a pu être
    // fermée pendant l'heure qui suivait un croisement : sans ce premier tour,
    // le verdict attendrait cinq minutes de plus à chaque lancement, et un
    // lancement plus court que ça ne le rendrait jamais.
    if (me != null) {
      unawaited(_rendreVerdicts());
      _verdicts ??= Timer.periodic(
        verdictEvery,
        (_) => unawaited(_rendreVerdicts()),
      );
    }

    _publishPresence();
  }

  /// Défait tout, **et remet les références à nul**.
  void _teardown() {
    _radioFeed?.cancel();
    _radioFeed = null;
    _peerFeed?.cancel();
    _peerFeed = null;
    _sightingSweep?.cancel();
    _sightingSweep = null;
    _verdicts?.cancel();
    _verdicts = null;
    final network = _network;
    _network = null; // ← la ligne qui manquait
    // ⚠️ **La présence ne se vide PLUS ici** (2026-08-29), et ce n'était pas
    // un choix : Riverpod interdit de modifier un autre fournisseur pendant un
    // `onDispose`. L'appel levait une assertion — avalee par `runGuarded`, donc
    // parfaitement silencieuse — et ne vidait rien du tout en debug.
    //
    // Le besoin, lui, reste vrai : *un constat périmé présenté comme une
    // observation est exactement ce que ce chantier supprime partout.* Il est
    // couvert deux fois, légalement :
    //
    // - au changement de compte, par [_forgetLocalPing], qui vide la présence
    //   **avant** que le nouveau compte n'ait quoi que ce soit à montrer ;
    // - à la fin de chaque `build`, par [_publishPresence] : sans réseau il
    //   publie une liste vide, ce que `clear()` faisait à l'identique.
    //
    // ⚠️ **Trouvé par un test qui démonte le conteneur**, pas à la lecture :
    // en release les assertions n'existent pas, l'appel passait, et rien n'a
    // jamais distingué les deux comportements.
    unawaited(network?.dispose());
  }

  /// Remet à zéro **tout le local du ping**, à la demande.
  ///
  /// ⚠️ **Outil de test** (Développeur), et il manquait. Supprimer une amitié
  /// en base ne suffit pas à revenir à « ils ne se sont jamais vus » : le
  /// carnet, les croisements et le cooldown des waves vivent **sur
  /// l'appareil**. Sans ce bouton, un test de première rencontre repartait avec
  /// la moitié de la mémoire de la précédente — et ce qu'on aurait observé
  /// n'aurait pas été une première rencontre.
  ///
  /// À retirer avec la section Développeur (RAPPELS #4).
  Future<void> resetLocalPing() async {
    await _forgetLocalPing();
    await _network?.refreshFriends();
    unawaited(ref.read(proximitySyncProvider).run());
    _publishPresence();
  }

  /// Efface tout ce que le ping garde en local, pour le compte qui s'en va.
  ///
  /// ⚠️ **L'identité de l'appareil en fait partie, et personne ne l'effaçait.**
  ///
  /// La clé de diffusion ne dépendait pas du compte connecté : après une
  /// déconnexion, l'appareil continuait de diffuser l'ID rotatif du compte
  /// précédent. Les amis de A voyaient donc « A est là » pendant que B utilisait
  /// le téléphone.
  Future<void> _forgetLocalPing() async {
    await _journal.clear();
    await _presences.clear();
    // ⚠️ **Après le premier `await`, et c'est ce qui le rend légal.** Vider
    // la présence, c'est modifier un autre fournisseur : interdit pendant un
    // cycle de vie (`build` synchrone, `onDispose`), permis ensuite. C'est
    // aussi le bon moment produit — on efface ce que l'ancien compte voyait
    // avant que le nouveau ne soit branché.
    _presence?.clear();
    await _keyBook.clear();
    await _identity.forget();
    await ref.read(pingStoreProvider).wipe();

    // ⚠️ **Et on redémarre la radio, sinon l'oubli ne s'entend pas.**
    //
    // Le natif continue de diffuser l'identifiant qu'on lui a passé au
    // démarrage. Sans ce rappel, l'appareil annoncerait encore l'ID rotatif du
    // compte précédent jusqu'au prochain changement de créneau — **jusqu'à
    // quinze minutes**. Effacer une clé sans cesser de l'émettre ne l'efface
    // pas.
    await ref.read(proximitySupervisorProvider.notifier).retry();
  }

  Future<void> _ensureNetwork() async {
    if (_network != null) return;

    final supervisor = ref.read(proximitySupervisorProvider.notifier);
    final network = PeerNetwork(identity: _identity, keyBook: _keyBook);
    _network = network;
    await network.start();

    // La synchro part au démarrage : c'est le moment où l'on récupère les clés
    // des amis, sans lesquelles aucune reconnaissance silencieuse n'est
    // possible.
    unawaited(ref.read(proximitySyncProvider).run());

    // ⚠️ **Plus rien à oublier quand la radio s'arrête** (2026-08-30). Il
    // fallait vider le registre en mémoire, parce qu'un souvenir de présence
    // en cours y survivait à l'extinction. Le carnet, lui, ne retient que des
    // contacts **terminés** et datés : une radio qui s'arrête n'en fabrique
    // aucun, et le réseau jette ses sessions sans émettre de `PeerLost`.
    _radioFeed = supervisor.events.listen(network.onRadioEvent);
    _peerFeed = network.events.listen(_onPeerEvent);

    _appliquerBalayage(ref.read(proximitySupervisorProvider).wantsFriends);
  }

  /// Cadence du balayage des constats.
  ///
  /// ⚠️ **Un seul balayage depuis le 2026-08-27, contre deux avant.** Le second
  /// tentait un **certificat de croisement co-signé** : ouvrir un lien GATT
  /// avec le pair et faire signer les deux appareils. Il part avec le
  /// transport, et la base prouve qu'il n'a jamais rien produit — la seule
  /// ligne de `encounters` porte `proof = 'mutual_sighting'`, alors que le
  /// défaut de la colonne est `'certificate'`.
  ///
  /// Ce qui reste — le CONSTAT — est celui qui marche : il ne demande ni lien,
  /// ni signature, et c'est le serveur qui exige la réciprocité.
  static const sweepEvery = Duration(seconds: 2);

  /// **Le balayage suit « Croiser mes amis », et rien d'autre.**
  ///
  /// ## 🔴 Le défaut que ceci corrige — relevé sur l'appareil le 2026-08-28
  ///
  /// Ce minuteur démarrait dès qu'un compte était connecté et ne s'arrêtait
  /// jamais. Or chacun de ses tours traverse la frontière native
  /// (`takeSightings`) : **30 appels par minute, toute la nuit, y compris les
  /// deux interrupteurs éteints** — c'est-à-dire quand il n'y a, par
  /// construction, rien à constater.
  ///
  /// ## ⚠️ Et la bonne condition n'est PAS « la radio tourne »
  ///
  /// La radio s'allume si l'un **ou** l'autre interrupteur est posé
  /// (`radioNeeded`). L'attacher à celui-là aurait laissé le balayage tourner
  /// pour quelqu'un qui ne veut qu'être visible d'inconnus : la radio a une
  /// raison de tourner, mais aucune table d'amis n'a été déposée, donc la
  /// réponse est vide **par construction**. Deux fonctions qui partagent une
  /// radio ne partagent pas leurs conditions d'arrêt (consigne de Jay,
  /// 2026-08-20).
  ///
  /// ## ⚠️ Ce qu'on récupère en s'arrêtant, et pourquoi
  ///
  /// À l'extinction on fait **un dernier tour**. Un constat déjà pris l'a été
  /// pendant que l'utilisateur le voulait, et un croisement n'existe que si les
  /// **deux** côtés l'ont signalé : jeter le nôtre ferait échouer en silence
  /// celui d'un ami qui, lui, a tout fait correctement.
  ///
  /// ⚠️ **Ce dernier tour n'est pas atomique, et il ne prétend pas l'être.** Si
  /// les deux interrupteurs tombent ensemble, la radio peut s'être arrêtée
  /// avant lui — `takeSightings` échoue alors, et le tampon natif part avec le
  /// service. Ce qui se perd tient dans les deux secondes précédentes, et le
  /// journal déduplique par créneau de 15 minutes : un ami vu dans ce créneau a
  /// déjà été remonté.
  void _appliquerBalayage(bool veutCroiserSesAmis) {
    if (veutCroiserSesAmis) {
      if (_network == null) return;
      _sightingSweep ??= Timer.periodic(
        sweepEvery,
        (_) => unawaited(_sweepSightings()),
      );
      return;
    }
    final minuteur = _sightingSweep;
    if (minuteur == null) return;
    minuteur.cancel();
    _sightingSweep = null;
    unawaited(_sweepSightings());
  }

  // ------------------------------------------------------------------
  // Réactions
  // ------------------------------------------------------------------

  Future<void> _onPeerEvent(PeerEvent event) async {
    switch (event) {
      // ⚠️ **Les événements de PRÉSENCE ne touchent pas au disque.** C'est le
      // chemin chaud : il part à la fréquence des annonces BLE. Y remettre une
      // lecture de fichier, c'est refaire le défaut du point C.
      case PresenceChanged():
        _publishPresence();
      case PeerIdentified():
        // ⚠️ **Rien ne part ici depuis le 2026-08-29.** Reconnaître quelqu'un et
        // l'avoir raté sont deux choses différentes — voir [_finDePresence].
        _publishPresence();
      case PeerLost():
        // ⚠️ **Plus aucun jugement ici depuis le 2026-08-30.** La fin d'une
        // présence vue par le Dart et celle vue par le natif sont le MÊME fait :
        // le natif est la seule source, parce que c'est le seul des deux qui ne
        // manque rien quand l'interface disparaît (voir
        // [_collectNativePresences]).
        _publishPresence();
    }
  }

  /// Une présence vient de se terminer : on l'enregistre, et on juge.
  ///
  /// ## 🔴 Le défaut que ceci corrige — signalé par Jay le 2026-08-29
  ///
  /// > *« le presque se déclenche alors que je reste à proximité, il n'y a pas
  /// > de croisement et pourtant le presque semble se déclencher à certains
  /// > moments sans raisons apparentes »*
  ///
  /// Le « presque » partait sur `PeerIdentified`, c'est-à-dire **au moment où
  /// l'on reconnaît quelqu'un**, avec pour seule condition un délai de garde de
  /// deux heures. Rien ne vérifiait que la personne soit repartie, ni qu'il n'y
  /// ait pas eu de vrai croisement.
  ///
  /// Conséquence : **rester assis à côté d'un ami toute la journée en produisait
  /// un.** Il suffisait que la radio hoquette — un lien perdu puis retrouvé plus
  /// de deux heures après le dernier envoi — pour qu'une « presque rencontre »
  /// soit annoncée à deux personnes qui ne s'étaient jamais quittées.
  ///
  /// ⚠️ **Et ce n'est pas un défaut isolé** : c'est le même symptôme, vu par
  /// l'autre bout, que la panne d'émission du 2026-08-29 (voir `AdvertOnAir`).
  /// Chaque instabilité de la radio fabriquait une réidentification, donc un
  /// « presque ».
  ///
  /// ## La règle, maintenant
  ///
  /// Un « presque » dit *« vous vous êtes ratés »*. Il faut donc **deux**
  /// choses, et elles ne sont connues qu'à la fin :
  ///
  /// 1. la présence est **terminée** (`PeerLost`, soit
  ///    [PresenceRules.forgetAfter] sans rien entendre) ;
  /// 2. elle n'a **jamais produit de constat** — un contact assez long pour
  ///    compter est un croisement, pas un « presque ».
  ///
  /// ⚠️ **Le seuil n'est pas un nouveau réglage, et c'est délibéré.** « Assez
  /// long pour compter » est déjà défini une fois, par [PeerSession.isStable]
  /// (`stableAfter` + `minSightings`) — celui-là même qui décide d'un constat.
  /// En introduire un second aurait fait deux définitions du même mot, qui
  /// auraient fini par se contredire.
  ///
  /// ⚠️ **Une radio qui s'arrête n'émet pas de `PeerLost`**, et c'est juste :
  /// couper sa visibilité n'est pas quelqu'un qui s'en va.
  /// Enregistre un contact terminé, et rend le jugement INSTANTANÉ.
  ///
  /// ⚠️ **Appelé pour les présences venues du NATIF, jamais de `PeerLost`.**
  /// Voir [_collectNativePresences] : le Dart sait aussi mesurer une présence,
  /// mais seulement tant que le pont est attaché. Deux mesures d'un même fait,
  /// dont une avec des trous, c'est deux vérités à tenir d'accord — et rien ne
  /// les distingue une fois écrites dans le carnet.
  Future<void> _noterContact(
    String userId, {
    required Presence contact,
    required int detections,
  }) async {
    // ⚠️ **On enregistre AVANT de juger, et toujours.** Un contact qui ne
    // déclenche rien reste un fait : c'est lui qui, dans une heure, empêchera
    // un presque de partir pour un croisement qu'on n'a pas raté. Ne garder que
    // les contacts intéressants, c'est se priver de la moitié de la règle.
    await _presences.noter(userId, contact: contact, detections: detections);

    // « Ton ami est tout près » se décide MAINTENANT — c'est toute sa raison
    // d'être. Le presque, lui, attend l'heure d'après ; voir [_rendreVerdicts].
    final historique = await _presences.historique(userId, sauf: contact);
    if (!WaveRules.toutPres(
      historique: historique,
      contact: contact,
      detections: detections,
    )) {
      return;
    }
    final profil = await ref.read(profileByIdProvider(userId).future);
    await _notifierToutPres(userId, profil?.displayName ?? 'Un ami');
  }

  /// Les présences **terminées** mesurées par le service, et leur jugement.
  ///
  /// ## ⚠️ Un rang d'une table périmée est JETÉ, comme pour les constats
  ///
  /// Le natif rend « le rang 3 a été là de tant à tant ». Ce rang n'a de sens
  /// que pour la table qui l'a produit : si le carnet a changé depuis,
  /// l'attribuer serait notifier la mauvaise personne.
  Future<void> _collectNativePresences() async {
    final supervisor = ref.read(proximitySupervisorProvider.notifier);
    final List<Map<String, dynamic>> bruts;
    try {
      bruts = await _radio.takePresences();
    } catch (_) {
      // Le service ne tourne pas : il n'a rien mesuré, et ce n'est pas une
      // panne — c'est l'état normal quand la visibilité est coupée.
      return;
    }
    for (final brut in bruts) {
      final userId = supervisor.friendOfSighting(
        (brut['tableId'] as num?)?.toInt() ?? -1,
        (brut['index'] as num?)?.toInt() ?? -1,
      );
      if (userId == null) continue;
      if (!await _isFriend(userId)) continue;
      await _noterContact(
        userId,
        contact: Presence(
          debut: DateTime.fromMillisecondsSinceEpoch(
            (brut['debut'] as num).toInt(),
          ),
          fin: DateTime.fromMillisecondsSinceEpoch(
            (brut['fin'] as num).toInt(),
          ),
        ),
        detections: (brut['detections'] as num?)?.toInt() ?? 0,
      );
    }
  }

  /// Le canal natif, pour récupérer ce que le service a constaté seul.
  ///
  /// ⚠️ **Vient du provider depuis le 2026-08-28**, comme le carnet et
  /// l'identité : un seul point de construction pour un objet partagé.
  BleRadio get _radio => ref.read(bleRadioProvider);

  /// Les constats en attente d'envoi.
  ///
  /// ⚠️ **Vit ici et pas dans le réseau.** Le réseau constate une présence ; ce
  /// qu'on en fait — savoir qui est un ami, décider d'en informer le serveur —
  /// est une décision produit, et elle n'a rien à faire sous la frontière radio.
  final _sightings = SightingLog();

  /// La mémoire des présences passées, sur le disque.
  ///
  /// ## 🔴 Ce qu'elle remplace, et pourquoi le remplacement était obligatoire
  ///
  /// `PresqueLedger` était un **ensemble d'identifiants en mémoire vive** : il
  /// savait seulement « cette présence a produit un constat ». Les règles
  /// décidées par Jay le 2026-08-30 regardent **deux heures avant et une heure
  /// après** — il ne pouvait donc répondre à aucune d'elles, et il repartait de
  /// zéro à chaque redémarrage alors que le verdict du presque se rend une
  /// heure plus tard.
  ///
  /// ⚠️ **Il est SUPPRIMÉ, pas gardé « au cas où ».** Sa question — *ce contact
  /// a-t-il compté ?* — est désormais posée par `WaveRules` avec sa propre
  /// définition (moins de 20 secondes). Deux définitions du même mot finissent
  /// toujours par se contredire, et celle-là l'aurait fait en silence.
  final _presences = PresenceBook();

  /// Le balayage qui rend les verdicts de presque mûrs.
  ///
  /// ⚠️ **Une cadence à lui, et surtout PAS celle des constats.** Le balayage
  /// des constats tourne toutes les deux secondes et ne touche pas au disque
  /// (`_sweepSightings`) ; celui-ci lit et réécrit un fichier. Les fusionner
  /// ferait trente lectures de disque par minute pour une question dont la
  /// réponse ne peut changer qu'une fois par heure — c'est exactement le défaut
  /// du point C du 2026-08-18, imposer le rythme du plus rapide au plus lent.
  static const verdictEvery = Duration(minutes: 5);

  Timer? _verdicts;

  // ------------------------------------------------------------------
  // Constats de croisement (réciprocité serveur)
  // ------------------------------------------------------------------

  /// Note qui est là, et fait partir les constats quand il y en a de nouveaux.
  ///
  /// ## ⚠️ Le seuil anti-passant, et c'est voulu
  ///
  /// On ne constate que les pairs **frais et stables**. Sans cette règle, une
  /// annonce isolée captée à cinquante mètres suffirait à fabriquer un
  /// croisement, et « vous vous êtes croisés » ne voudrait plus rien dire.
  ///
  /// ## ⚠️ Pourquoi ce balayage ne coûte presque rien
  ///
  /// Le journal déduplique par `(personne, créneau)`. Un ami immobile produit
  /// donc **un** constat par quart d'heure, pas un par annonce — sinon ce
  /// serait ~9 000 par créneau. Et le journal ne devient non vide que quand
  /// quelque chose de neuf est arrivé : les envois sont rares par construction.
  Future<void> _sweepSightings() async {
    final network = _network;
    if (network == null) return;
    if (ref.read(currentUserIdProvider) == null) return;

    await _collectNativeSightings();
    await _collectNativePresences();

    final now = network.now();
    for (final session in network.presence.sessions) {
      final userId = session.userId;
      if (userId == null) continue;
      if (!session.isFresh(now) || !session.isStable(now)) continue;
      // ⚠️ **Le serveur refuserait un constat entre non-amis** —
      // `report_sightings` exige `connections.status = 'full'` (vérifié en base
      // le 2026-08-27). Autant ne pas l'envoyer.
      if (!await _isFriend(userId)) continue;
      _sightings.observe(userId, now, band: session.toPresence().band);
    }

    if (_sightings.length == 0) return;
    final lot = _sightings.drain();
    await ref.read(pingStoreProvider).enqueue({
      'type': 'sightings',
      'items': [for (final s in lot) s.toJson()],
    });
    // ⚠️ **La FILE, pas toute la synchronisation.** Ce `run()` republiait ma
    // clé publique et retéléchargeait tout le carnet d'amis — quatre appels
    // serveur — **toutes les deux secondes** tant qu'un ami était à portée.
    // Relevé sur l'appareil de Jay le 2026-08-28 : 50 synchronisations pour
    // 92 secondes de présence, pour 2 lignes écrites en base.
    unawaited(ref.read(proximitySyncProvider).pushOutbox());
  }

  /// Récupère ce que le SERVICE NATIF a constaté pendant que le Dart dormait.
  ///
  /// ## ⚠️ C'est ce qui rend le croisement possible app fermée
  ///
  /// Le natif diffuse tout seul depuis le plan d'émission, et reconnaît tout
  /// seul depuis la table. Mais il ne sait ni qui est qui, ni parler au serveur.
  /// Ce qu'il a vu attend donc ici, et repart dans le même journal que les
  /// constats faits en direct — un seul chemin vers le serveur, une seule règle.
  ///
  /// ## ⚠️ Un rang d'une table périmée est JETÉ
  ///
  /// Le natif rend « le rang 3 est passé au créneau S ». Ce rang n'a de sens
  /// que pour la table qui l'a produit : si le carnet a changé depuis, le rang 3
  /// désigne peut-être quelqu'un d'autre. On jette plutôt que d'attribuer au
  /// hasard — un croisement faux vaut moins que pas de croisement.
  Future<void> _collectNativeSightings() async {
    final supervisor = ref.read(proximitySupervisorProvider.notifier);
    final List<Map<String, dynamic>> bruts;
    try {
      bruts = await _radio.takeSightings();
    } catch (_) {
      // Le service ne tourne pas : il n'a rien constaté, et ce n'est pas une
      // panne — c'est l'état normal quand la visibilité est coupée.
      return;
    }
    if (bruts.isEmpty) return;

    var jetes = 0;
    for (final brut in bruts) {
      final userId = supervisor.friendOfSighting(
        (brut['tableId'] as num?)?.toInt() ?? -1,
        (brut['index'] as num?)?.toInt() ?? -1,
      );
      if (userId == null) {
        jetes++;
        continue;
      }
      _sightings.note(
        Sighting(
          peerId: userId,
          slot: (brut['slot'] as num).toInt(),
          // La bande se calcule ICI, pas dans le natif : dupliquer le modèle de
          // distance en Kotlin, c'est se garantir qu'un jour les deux ne
          // diront plus la même chose.
          band: DistanceModel.bandFor((brut['rssi'] as num).toDouble(), null),
        ),
      );
    }
    // ⚠️ **Compté, plus consigné** (2026-08-28). Ceci se produisait toutes les
    // deux secondes et saturait l'anneau du journal — voir
    // `ConnectionTrace.nativeDropped`. Et le motif employé, « synchronisation
    // hors ligne », décrivait quelque chose qui ne s'était pas produit : un
    // lecteur du rapport en aurait conclu à 318 pannes réseau.
    for (var i = 0; i < jetes; i++) {
      ConnectionTrace.count(ConnectionTrace.nativeDropped);
    }
  }

  // ------------------------------------------------------------------
  // Waves
  // ------------------------------------------------------------------

  /// Suis-je ami avec cette personne ? **Une seule source, le carnet.**
  Future<bool> _isFriend(String userId) async =>
      (await _keyBook.all()).containsKey(userId);

  /// **« Ton ami est tout près »** — la notification INSTANTANÉE.
  ///
  /// ⚠️ **Elle n'est pas enregistrée**, ni sur l'appareil ni au serveur
  /// (décision de Jay, 2026-08-30). Ce n'est pas un souvenir, c'est une
  /// information sur l'instant : l'historique de `Profil → ♥` ne contient que
  /// des presque. Lui donner une ligne serveur reviendrait à tenir le journal
  /// de qui a été près de qui, ce que le presque, lui, assume et borne.
  ///
  /// ⚠️ **C'est ELLE que le palier accélère depuis le 2026-08-30**, et plus le
  /// presque : voir [PresqueDelai].
  Future<void> _notifierToutPres(String userId, String nom) async {
    final profile = await ref.read(myProfileProvider.future);
    // ⚠️ **Le contrôleur ne connaît AUCUN palier et n'en lit aucune règle.** Il
    // demande un rang au dépôt des amitiés — qui vit hors du ping — et le passe
    // à une règle pure. C'est le strict minimum de contact exigé par la
    // consigne de Jay du 2026-08-28.
    final rang = ref.read(tierOfProvider(userId)).rang;
    final delai = PresqueDelai.pour(
      rangDuPalier: rang,
      tempsReelChoisi: profile?.realtimeWaves ?? false,
    );
    await NotificationService.instance.schedule(
      NotifChannel.waves,
      'Tout près…',
      '$nom est juste à côté.',
      DateTime.now().add(delai),
    );
  }

  /// **Le presque** — rendu UNE HEURE après le contact, jamais avant.
  ///
  /// ## ⚠️ Pourquoi c'est un balayage et pas une notification programmée
  ///
  /// L'ancienne version décidait tout de suite et programmait la notification
  /// plus tard. Ce n'est plus possible : la règle 3 de Jay regarde **l'heure
  /// qui suit** le croisement, donc la réponse n'existe pas encore au moment du
  /// croisement. On ne peut programmer qu'un **re-examen**, pas un verdict.
  ///
  /// ⚠️ **Le verdict est marqué même quand il est NÉGATIF.** « Pas de presque »
  /// est une réponse aussi définitive que « presque » : sans la marque, chaque
  /// tour rejugerait les mêmes contacts pour toujours.
  Future<void> _rendreVerdicts() async {
    if (ref.read(currentUserIdProvider) == null) return;
    for (final murs in await _presences.aJuger()) {
      await _presences.marquerJuge(murs.userId, murs.contact);
      if (!WaveRules.wave(historique: murs.historique, contact: murs.contact)) {
        continue;
      }
      if (!await _isFriend(murs.userId)) continue;
      if (!await _journal.mayWave(murs.userId, waveCooldown)) continue;
      await _journal.noteWave(murs.userId);
      await _envoyerPresque(murs.userId);
    }
  }

  /// Notifie et consigne un presque confirmé.
  Future<void> _envoyerPresque(String userId) async {
    final nom =
        (await ref.read(profileByIdProvider(userId).future))?.displayName ??
        "Quelqu'un";
    await NotificationService.instance.schedule(
      NotifChannel.waves,
      'Le presque…',
      '$nom est passé tout près de toi.',
      DateTime.now(),
    );
    await ref.read(pingStoreProvider).enqueue({
      'type': 'wave',
      'peerId': userId,
      'notifyAfter': DateTime.now().toUtc().toIso8601String(),
    });
    unawaited(ref.read(proximitySyncProvider).pushOutbox());
  }

  // ------------------------------------------------------------------

  /// **Acquisition** : ce que la radio constate, publié tel quel.
  ///
  /// Synchrone, sans disque, sans réseau. C'est ce qui permet de l'appeler à la
  /// fréquence des annonces. Décider si l'interface doit se redessiner n'est pas
  /// son travail : `presence_feed.dart` compare, avec la définition de
  /// « différent » qui appartient à l'affichage.
  void _publishPresence() {
    _presence?.publish(_network?.presence.peers ?? const []);
  }
}

// ⚠️ **`_RadioAdapter` a été SUPPRIMÉ le 2026-08-27**, avec l'interface
// `RadioCommands` qu'il implémentait. Il traduisait `connect` / `disconnect` /
// `send` vers `BleRadio`. Le réseau de pairs ne donne plus **aucun** ordre à la
// radio : il ne fait qu'écouter ce qu'elle constate.

/// Vrai si [userId] est à portée **maintenant**.
///
/// Point d'entrée unique pour tout ce qui exige la présence physique — la
/// barrière fondatrice du produit.
///
/// ⚠️ **Ce commentaire promettait déjà « jamais un souvenir », et le code ne le
/// tenait pas.** La liste qu'il interroge tolérait 25 secondes d'absence
/// d'annonce, et l'infini pour un pair encore relié. C'était le troisième
/// commentaire de ce chantier à affirmer une règle que son code n'appliquait
/// pas.
///
/// Elle est désormais vraie par construction : le flux de présence ne contient
/// que les pairs frais au sens de [PresenceRules.freshFor], parce que le
/// registre refuse d'en projeter d'autres.
///
/// ⚠️ Alias de `isNearbyProvider` : **un seul calcul de la présence**, exposé
/// sous le nom que le reste du produit utilise déjà.
final peerInRangeProvider = Provider.family<bool, String>(
  (ref, userId) => ref.watch(isNearbyProvider(userId)),
);

/// ⚠️ **C'est CE provider qui démarre toute la proximité.** Le construire lance
/// le réseau de pairs, la synchro des clés et le balayage des constats ; plus
/// personne ne l'observe, plus rien ne tourne. `PingScreen` l'observe pour
/// cette raison, et pour elle seule — il n'en lit aucune valeur.
final proximityControllerProvider =
    AsyncNotifierProvider<ProximityController, void>(ProximityController.new);
