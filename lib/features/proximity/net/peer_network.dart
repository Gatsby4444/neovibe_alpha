import 'dart:async';
import 'dart:typed_data';

import '../ping_store.dart';
import '../proximity_identity.dart';
import 'advert_plan.dart';
import 'peer_session.dart';
import 'radio_status.dart';

/// Ce que le réseau constate, une fois les octets devenus du sens.
///
/// C'est la frontière : en dessous, on parle radio et jetons ; au-dessus, on
/// parle de personnes présentes. **Aucune fonction produit ne descend sous
/// cette ligne.**
sealed class PeerEvent {
  const PeerEvent();
}

/// La présence a changé — quelqu'un est arrivé, parti, ou vient d'être
/// identifié. L'interface se redessine là-dessus, et sur rien d'autre.
class PresenceChanged extends PeerEvent {
  const PresenceChanged();
}

/// Un pair s'est révélé : on sait maintenant QUI il est.
///
/// ⚠️ Il n'y a pas de `isFriend` ici, et c'est délibéré : le réseau dit **qui**,
/// jamais **ce que cette personne est pour moi** — cette question-là se pose au
/// carnet, au moment du rendu.
class PeerIdentified extends PeerEvent {
  const PeerIdentified(this.address, this.snapshot);
  final String address;
  final PingPeerSnapshot snapshot;
}

/// Un pair a quitté la portée.
class PeerLost extends PeerEvent {
  const PeerLost(this.peer);
  final PresencePeer peer;
}

/// La présence de proximité : qui la radio entend, et depuis quand.
///
/// ## Ce qu'il fait
///
/// Il transforme un flux d'annonces BLE en un flux d'événements de présence :
/// il reconnaît les jetons d'amis, tient un [PeerSession] par personne, et
/// publie ce qu'il constate.
///
/// ## Ce qu'il ne fait pas
///
/// Il ne sait pas ce qu'est un ami, un croisement ou une demande de connexion.
/// Il dit **qui est là** ; ce sont les fonctions, au-dessus, qui décident quoi
/// en faire.
///
/// ## ⚠️ Ce qui a changé le 2026-08-27 — le transport BLE est parti
///
/// Ce fichier portait aussi les **liens GATT** : ouverture de connexion, canal
/// chiffré, découpage de trames, poignée de main, envoi de messages
/// applicatifs. Soit un peu plus de la moitié de ses lignes.
///
/// Décision de Jay du 2026-08-27 : *« on n'utilise plus la poignée de main
/// GATT ‹…› le BLE ne sert qu'à valider et authentifier la proximité réelle »*.
/// Tout ce que le canal transportait est passé au serveur — identité d'un
/// inconnu (`ping_nearby`), messagerie (conversation de proximité), demande
/// d'ami (`request_connection_from_proximity`).
///
/// ⚠️ **La barrière de présence physique n'est pas partie avec le canal** :
/// elle était tenue par la portée de la radio, elle est désormais une condition
/// **écrite et vérifiée côté serveur**. Le BLE reste ce qui la prouve.
///
/// Ce qui reste ici est ce que le serveur ne saura jamais faire : reconnaître un
/// ami **hors ligne, app fermée**, à son jeton rotatif, et mesurer sa distance.
class PeerNetwork {
  PeerNetwork({
    required FriendKeyStore keyBook,
    required ProximityIdentity identity,
    DateTime Function()? clock,
    // Les champs sont privés : un paramètre formel initialisant les exposerait
    // sous leur nom privé, que les appelants ne peuvent pas nommer.
    // ignore: prefer_initializing_formals
  }) : _keyBook = keyBook,
       // ignore: prefer_initializing_formals
       _identity = identity,
       _clock = clock ?? DateTime.now {
    presence = PeerRegistry(clock: clock);
  }

  final ProximityIdentity _identity;
  final FriendKeyStore _keyBook;
  final DateTime Function() _clock;

  /// **L'heure de la proximité.** Une seule autorité pour toute la
  /// fonctionnalité : le registre expire les sessions contre cette horloge, et
  /// tout ce qui juge une session doit la lire ici.
  ///
  /// ⚠️ Le balayage des croisements appelait `DateTime.now()` directement
  /// (audit du 2026-08-18, point G). Sans effet en production — les deux
  /// valaient la même chose — mais sous horloge simulée, le registre et le
  /// balayage n'étaient plus au même instant, et ce chemin devenait intestable.
  DateTime now() => _clock();

  /// Le registre des pairs. Nommé `presence` parce que c'est la question qu'on
  /// lui pose.
  late final PeerRegistry presence;

  /// Table jeton reçu → ami, reconstruite à chaque créneau.
  ///
  /// ⚠️ **Elle ne contient pas de clés, seulement des jetons attendus.** Le
  /// carnet range des clés publiques ; `AdvertPlanner` en dérive ce qu'on
  /// s'attend à recevoir. Le réseau, lui, ne fait que comparer.
  RecognitionTable _recognition = const RecognitionTable(
    fromSlot: 0,
    toSlot: -1,
    byToken: {},
  );
  Map<String, FriendKeys> _friends = {};
  int _slot = -1;

  static const _planner = AdvertPlanner();

  final _events = StreamController<PeerEvent>.broadcast();
  Stream<PeerEvent> get events => _events.stream;

  Timer? _housekeeping;

  // ⚠️ **`foreignTokenScans` a été RETIRÉ d'ici le 2026-08-28.** Il comptait
  // les jetons privés d'autres paires, et **aucun lecteur ne l'affichait** — le
  // rapport de diagnostic publie celui du natif. Deux compteurs pour une même
  // question, dont un invisible, c'est deux chiffres qui finiront par ne plus
  // dire la même chose sans que personne ne s'en aperçoive.
  //
  // Le natif est le bon endroit : sa table couvre douze heures de créneaux et
  // il compte **aussi quand l'interface est absente**, ce que cette couche-ci
  // ne peut pas faire. Voir `ProximityService.foreignTokenScans`.

  Future<void> start() async {
    // On s'abonne au carnet, on ne le relit pas à heure fixe : peu importe qui
    // arrive en premier, du réseau ou des clés téléchargées.
    _keyBook.changes.addListener(_onBookChanged);
    await refreshFriends();
    _housekeeping ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(tick()),
    );
  }

  void _onBookChanged() => unawaited(refreshFriends());

  Future<void> dispose() async {
    _keyBook.changes.removeListener(_onBookChanged);
    _housekeeping?.cancel();
    _housekeeping = null;
    presence.drain();
    await _events.close();
  }

  /// Recharge le carnet d'amis et la table de reconnaissance du créneau.
  ///
  /// ⚠️ **Le coût est ici, et il est borné.** Un X25519 par ami (mis en cache
  /// par l'identité), puis trois HMAC par ami. Ce qui coûtait le double avant —
  /// la clé « précédente » doublait l'indexation sans changer aucun résultat.
  Future<void> refreshFriends() async {
    _slot = ProximityIdentity.slotIndex(_clock());
    _friends = await _keyBook.all();
    final secrets = await _identity.pairSecrets({
      for (final f in _friends.values) f.userId: f.x25519PublicKey,
    });
    _recognition = await _planner.table(secrets: secrets, slot: _slot);

    // ⚠️ **Une identité vient du carnet ; elle s'en va avec lui.**
    //
    // Sans ces lignes, une session identifiée gardait son identité après le
    // retrait de l'ami : la tuile continuait de le nommer, et l'écran lui
    // proposait un bouton « demander en ami » — sur une personne que la radio
    // n'a plus aucun droit de reconnaître. Le carnet est la seule source de la
    // question « qui est-ce ? » : quand il ne répond plus, la session
    // redevient une simple détection anonyme.
    var change = false;
    for (final session in presence.sessions) {
      final userId = session.userId;
      if (userId == null || _friends.containsKey(userId)) continue;
      presence.deidentify(session);
      change = true;
    }
    if (change) _publish();
  }

  // ------------------------------------------------------------------
  // Entrée : les constats de la radio
  // ------------------------------------------------------------------

  Future<void> onRadioEvent(RadioEvent event) async {
    switch (event) {
      case RadioStatusEvent(:final status):
        // La radio s'arrête : la présence n'est plus qu'un souvenir, et un
        // souvenir présenté comme une observation est exactement ce qu'on
        // supprime partout ici.
        if (!status.isDetecting && presence.length > 0) {
          presence.drain();
          _publish();
        }
      case RadioScan(
        :final address,
        :final advertId,
        :final rssi,
        :final txPower,
        :final type,
        :final at,
      ):
        // ⚠️ **Une annonce trop vieille n'est pas une présence.**
        //
        // Le service natif met de côté ce qu'il capte quand l'interface est
        // absente, et le rejoue à son retour. Ici, la seule définition qui
        // vaille est celle de la présence — [PresenceRules.freshFor] : au-delà,
        // le registre ne le dirait de toute façon plus « là », mais il aurait
        // entre-temps émis `PeerIdentified`, donc **envoyé un « presque » pour
        // quelqu'un parti depuis des heures** (défaut du 2026-08-28).
        //
        // C'est le consommateur qui tranche, avec SA définition : le service de
        // balise, lui, en a une autre. L'acquisition, elle, publie tout.
        if (_clock().difference(at) > PresenceRules.freshFor) return;
        await _onScan(address, advertId, rssi, txPower, type);
    }
  }

  /// **Deux formats d'annonce, deux traitements. Jamais un seul.**
  ///
  /// ⚠️ **Consigne de Jay, 2026-08-25.** Le code affirmait déjà que « croiser un
  /// ami et se rendre découvrable d'inconnus sont deux fonctions distinctes »
  /// (`proximity_supervisor.dart`), mais les deux arrivaient ici comme 16 octets
  /// indifférenciés. Conséquence mesurée au premier test à deux appareils : un
  /// ami qui crie **un jeton par ami** apparaissait une fois comme ami et
  /// **autant de fois comme inconnu** qu'il avait d'autres amis. Jay a vu
  /// « 13 détections » là où il ne pouvait y en avoir qu'une.
  Future<void> _onScan(
    String address,
    Uint8List advertId,
    int rssi,
    int txPower,
    AdvertType type,
  ) async {
    final hex = FriendKeyBook.hex(advertId);
    final friend = _friends[_recognition.match(advertId)];

    // ⚠️ **Un jeton PRIVÉ qu'on ne reconnaît pas n'est PAS un inconnu.** C'est
    // le jeton d'une autre paire, capté au passage. L'afficher comme une
    // découverte, c'est inventer des gens qui n'existent pas.
    // Le natif les compte (`ProximityService.foreignTokenScans`) : ici, on se
    // contente de ne pas inventer quelqu'un.
    if (type == AdvertType.friend && friend == null) return;

    // ⚠️ **Le jeton descend jusqu'au registre.** C'est lui, et non l'adresse,
    // qui regroupe les annonces d'un même appareil : l'adresse change à chaque
    // redemarrage d'annonce, le jeton tient tout un créneau. Voir
    // [PeerRegistry.observe].
    var session = presence.observe(
      address,
      rssi,
      txPower: txPower,
      tokenHex: hex,
    );

    // Un ami est reconnu ICI, sans poignée de main : c'est tout l'intérêt de
    // l'ID rotatif.
    if (friend != null && session.snapshot == null) {
      session = presence.identify(
        session,
        PingPeerSnapshot(
          userId: friend.userId,
          username: friend.username,
          tagName: friend.tagName,
          verified: true,
        ),
      );
      _emit(PeerIdentified(session.address, session.snapshot!));
    }

    _publish();
  }

  // ⚠️ **TOUT LE TRANSPORT A ÉTÉ SUPPRIMÉ LE 2026-08-27** — décision de Jay :
  // *« on n'utilise plus la poignée de main GATT ‹…› le BLE ne sert qu'à valider
  // et authentifier la proximité réelle »*.
  //
  // Ce qui vivait ici, et par quoi c'est remplacé :
  //
  // | Il portait | Désormais |
  // |---|---|
  // | révéler l'identité d'un inconnu | `ping_nearby`, après réciprocité |
  // | la messagerie de proximité | conversation serveur (`ChatScreen`) |
  // | la demande d'ami | `request_connection_from_proximity` |
  // | le certificat de croisement co-signé | `report_sightings` (constat mutuel) |
  //
  // Le côté **receveur** avait été gardé le temps que le parc se mette à jour ;
  // il n'y a que deux appareils de développement, tous deux à jour, et aucune
  // production. Le garder revenait à maintenir un chemin d'entrée que plus
  // personne n'emprunte — exactement la « règle la plus permissive qui gagne en
  // silence » de `CLAUDE.md`.

  // ------------------------------------------------------------------
  // Entretien
  // ------------------------------------------------------------------

  /// Battement régulier : rotation de l'index, pairs oubliés.
  Future<void> tick() async {
    final slot = ProximityIdentity.slotIndex(_clock());
    if (slot != _slot) await refreshFriends();

    for (final session in presence.expired()) {
      final peer = session.toPresence();
      presence.remove(session);
      _emit(PeerLost(peer));
    }

    _publish();
  }

  /// Publie le constat de présence. **Un seul chemin vers « la présence a
  /// bougé ».**
  ///
  /// ## ⚠️ Un seul chemin, et une seule responsabilité
  ///
  /// Sept endroits émettaient `PresenceChanged` à la main, chacun quand son
  /// auteur y pensait. D'où des rafraîchissements en double sur un même
  /// changement, et **aucun** quand un pair cessait simplement d'être frais —
  /// personne n'émet pour un non-événement.
  ///
  /// ## ⚠️ Ce qui a changé le 2026-08-20 — règle de dissociation de Jay
  ///
  /// Cette méthode filtrait sur une signature `adresse:stade`, c'est-à-dire
  /// qu'**une couche d'acquisition décidait à la place de l'affichage** si
  /// l'écran devait se redessiner. Deux conséquences :
  ///
  /// - la bande, la tendance et la distance ne se rafraîchissaient jamais pour
  ///   un pair identifié et immobile (audit du 2026-08-18, point C) ;
  /// - toute nouveauté visible à l'écran obligeait à venir modifier **ce
  ///   fichier**, qui n'a aucune raison de connaître les champs d'une tuile.
  ///
  /// Le réseau publie donc ce qu'il constate, fidèlement. C'est
  /// `presence_feed.dart` qui compare, avec sa propre définition de
  /// « différent » — l'égalité de ce qu'une tuile affiche. Le chemin est bon
  /// marché de bout en bout : ni disque, ni réseau, rien qu'une comparaison de
  /// valeurs.
  void _publish() => _emit(const PresenceChanged());

  void _emit(PeerEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}
