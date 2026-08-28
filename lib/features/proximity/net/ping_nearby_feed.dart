import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/derived_list.dart';
import '../proximity_identity.dart';
import 'ping_beacon_service.dart';
import 'ping_repository.dart';
import 'proximity_supervisor.dart';

/// **L'USAGE du ping de proximité : qui est là, et qui l'est ENCORE.**
///
/// ⚠️ **Deux objets, deux rythmes**, comme `presence_feed.dart` pour le BLE :
///
/// | Objet | Rôle | Rythme |
/// |---|---|---|
/// | [pingNearbySourceProvider] | ce que le serveur constate, brut | toutes les 10 s |
/// | [pingNearbyProvider] | qui est affiché **maintenant** | quand la liste change vraiment |
///
/// L'horloge bat sans réveiller personne tant que la liste ne change pas —
/// c'est [DerivedList] qui arrête la propagation. Ce n'est qu'à la seconde où
/// quelqu'un dépasse le délai de grâce que l'écran l'apprend.

// ⚠️ **kPingGrace (30 s) a été SUPPRIMÉE le 2026-08-28** : plus aucun lecteur
// depuis que la présence se constate en local. Les deux délais qui décident
// vraiment sont [kPingLocalGrace] (la radio) et [kPingGraceServeur] (le filet).
// Une constante que seuls des commentaires citent finit par être lue comme la
// règle appliquée — elle ne l'était plus.

/// Le silence radio au bout duquel on considère que la personne est partie.
///
/// ⚠️ **C'est ce délai qui décide de l'affichage depuis le 2026-08-27**, et il
/// ne coûte **aucun appel réseau** : la radio crie ~10 fois par seconde, donc
/// dix secondes de silence sont une centaine d'annonces manquées d'affilée.
///
/// ⚠️ **Il a remplacé un délai de 30 s compté sur une date SERVEUR**, qu'il
/// fallait aller rechercher toutes les dix secondes pour qu'elle reste vraie.
/// Ici, la question « est-il encore là ? » se répond avec ce que la radio
/// entend déjà.
const kPingLocalGrace = Duration(seconds: 10);

/// **Ce que la radio entend, ici, maintenant** : jeton → dernier instant entendu.
///
/// ⚠️ **Acquisition pure.** Publie fidèlement, à la fréquence des annonces, et
/// ne décide de rien. C'est [pingNearbyProvider] qui compare — avec sa propre
/// définition de « différent » — exactement comme `presence_feed.dart` le fait
/// pour les amis.
class EcouteLocale extends Notifier<Map<String, DateTime>> {
  @override
  Map<String, DateTime> build() => const {};

  void publish(Map<String, DateTime> heardAt) => state = heardAt;

  void clear() => state = const {};
}

final ecouteLocaleProvider =
    NotifierProvider<EcouteLocale, Map<String, DateTime>>(EcouteLocale.new);

/// **L'ACQUISITION.** Ce que le serveur constate, sans filtre ni jugement.
///
/// ⚠️ **Ne tourne que si le ping est actif.** Interroger le serveur quand
/// l'utilisateur a coupé le ping, c'est continuer à demander « qui est autour
/// de moi ? » après qu'il a dit non.
class PingNearbySource extends Notifier<List<NearbyPerson>>
    with DerivedList<NearbyPerson> {
  static const pollEvery = Duration(seconds: 10);

  Timer? _poll;

  /// Le dernier constat du serveur, **conservé à travers les reconstructions**.
  ///
  /// ⚠️ **C'est ce qui remplace `return state;`**, qui levait
  /// `Bad state: Tried to read the state of an uninitialized provider` à chaque
  /// lancement avec le ping actif (relevé sur les deux appareils de Jay le
  /// 2026-08-26). Riverpod n'expose pas l'état pendant `build` — il n'existe
  /// pas encore, et lors d'une reconstruction il a déjà été remis à zéro. Un
  /// champ, lui, survit : le notifier est le même objet.
  ///
  /// Sans lui, une simple bascule d'un dépendance vidait l'écran, puis le
  /// rafraîchissement suivant le remplissait — un clignotement pour rien.
  List<NearbyPerson> _last = const [];

  @override
  List<NearbyPerson> build() {
    ref.onDispose(() {
      _poll?.cancel();
      _poll = null;
    });

    final wants = ref.watch(
      proximitySupervisorProvider.select((r) => r.wantsVisible),
    );
    // ⚠️ Le service de balise doit tourner : sans balise publiée, le serveur ne
    // rend rien, et interroger `ping_nearby` ne ferait que du bruit réseau.
    ref.watch(pingBeaconProvider);

    _poll?.cancel();
    _poll = null;
    if (!wants) {
      // Le ping coupé, le souvenir n'a plus de sens : le garder ferait
      // réapparaître d'anciens voisins à la réactivation.
      _last = const [];
      return const [];
    }

    _poll = Timer.periodic(pollEvery, (_) => unawaited(_peutEtre()));
    // ⚠️ **Un appel FORCÉ seulement au premier tour.** `build` se ré-exécute à
    // chaque changement de `pingBeaconProvider` — donc à chaque tour de balise
    // et à chaque dépôt de jetons. Y appeler `refresh()` sans condition
    // ajoutait deux appels par minute que rien ne demandait.
    Future.microtask(() => _last.isEmpty ? refresh() : _peutEtre());
    return _last;
  }

  /// Le créneau du dernier appel : au changement, les jetons de tout le monde
  /// changent et il faut les réapprendre.
  int _slot = -1;

  /// Les jetons qu'on a demandés au serveur **et qu'il n'a pas nommés**, avec
  /// l'instant du **premier** refus.
  ///
  /// ## 🔴 Le défaut que ceci corrige — mesuré le 2026-08-27 à 20 h 16
  ///
  /// `ping_nearby` écarte délibérément les **amis** : cette liste sert à
  /// découvrir des inconnus, et un ami est déjà reconnu par la radio, avec une
  /// meilleure information. Mais les deux appareils continuent de **crier leur
  /// identifiant public** — donc, une fois devenus amis, chacun entend de
  /// l'autre un jeton que le serveur **refusera toujours** de nommer.
  ///
  /// La règle « je demande tant que j'entends un jeton que je ne sais pas
  /// nommer » ne terminait donc jamais : **122 appels à `ping_nearby` en
  /// 7 minutes** relevés dans les journaux du serveur, soit huit par minute et
  /// par appareil — exactement le gaspillage que ce chantier devait supprimer.
  ///
  /// ⚠️ **Rien ne l'affichait.** L'écran montrait la bonne chose ; seule la
  /// facture changeait. Il a fallu **compter dans les journaux** pour le voir.
  ///
  /// ## Pourquoi un COMPTEUR et pas un simple abandon
  ///
  /// Renoncer au premier refus casserait la découverte : au moment où deux
  /// inconnus se croisent, le serveur ne peut nommer personne tant qu'il n'a
  /// pas reçu le constat **des deux côtés**.
  ///
  /// ## 🔴 Deux défauts corrigés le 2026-08-28
  ///
  /// **1. Le seuil était calibré trop court.** Il valait six tours de dix
  /// secondes, soit **60 s** — exactement l'ordre de grandeur du pire cas
  /// d'appariement : le jeton d'en face n'entre dans ma liste d'écoute qu'après
  /// **sa** republication de balise (PingBeaconService.refreshEvery = 60 s),
  /// plus un aller-retour serveur. On renonçait donc au moment précis où le
  /// serveur devenait capable de répondre.
  ///
  /// **2. Un compte de tours dépend d'un rythme qu'il ne nomme pas.** Changer
  /// [pollEvery] changeait silencieusement la durée du renoncement. On énonce
  /// la règle telle qu'elle se pense — voir [_abandonApres].
  final _sansReponse = <String, DateTime>{};

  /// Au bout de combien de temps on cesse de demander le nom d'un jeton.
  ///
  /// Trois minutes couvrent largement les 60 s de republication d'en face, son
  /// dépôt et le nôtre. Au-delà, le jeton appartient à un ami (que
  /// `ping_nearby` écarte par construction) ou à quelqu'un qui ne nous confirme
  /// pas : redemander n'apprendra rien.
  ///
  /// ⚠️ **Le renoncement se RÉARME**, et c'est la seconde moitié du correctif :
  /// [_noteCeQuiResteSansNom] oublie tout jeton qu'on n'entend plus. Un jeton
  /// réentendu après une coupure repart donc de zéro, au lieu de rester
  /// abandonné jusqu'au prochain créneau — soit jusqu'à quinze minutes.
  static const _abandonApres = Duration(minutes: 3);

  /// **N'appelle le serveur que s'il a quelque chose à nous apprendre.**
  ///
  /// ## ⚠️ Le gaspillage que ça supprime
  ///
  /// Cette boucle interrogeait le serveur **toutes les dix secondes, sans
  /// condition** — y compris seul dans un champ, radio muette : 360 appels par
  /// heure pour s'entendre répondre « personne ». La radio, elle, savait déjà.
  ///
  /// ## Les trois seules raisons d'appeler
  ///
  /// 1. **un jeton entendu qu'on ne sait pas nommer** — c'est une découverte en
  ///    cours, et c'est le seul cas qui presse ;
  /// 2. **le créneau a changé** (15 min) — tous les jetons ont tourné, il faut
  ///    réapprendre celui de chacun, sans quoi on croirait tout le monde parti ;
  /// 3. un geste explicite de l'utilisateur ([refresh]).
  ///
  /// ⚠️ **Ne PAS ajouter « et quand quelqu'un est présent ».** C'est ce que
  /// faisait l'ancienne boucle : une fois la personne connue, sa présence se
  /// constate en local, et redemander au serveur n'apprend rien de plus.
  /// Compte les jetons entendus que la réponse du serveur n'a pas nommés.
  ///
  /// ⚠️ **Appelé APRÈS chaque réponse, jamais avant.** C'est ce qui distingue
  /// « le serveur n'a pas encore le constat des deux côtés » (on réessaie) de
  /// « le serveur ne nommera jamais ce jeton » (on renonce).
  void _noteCeQuiResteSansNom() {
    final entendus = ref.read(ecouteLocaleProvider);
    final connus = {for (final p in _last) p.token}.whereType<String>().toSet();

    // ⚠️ **Ce qu'on n'entend plus redevient une question ouverte.** Sans cette
    // ligne, un jeton abandonné le restait jusqu'au changement de créneau —
    // jusqu'à quinze minutes —, même réentendu entre-temps. La liste d'écoute
    // se purge d'elle-même après [kPingGraceServeur] : s'y adosser fait
    // repartir le compte à la prochaine rencontre, sans second réglage.
    _sansReponse.removeWhere((jeton, _) => !entendus.containsKey(jeton));

    final maintenant = DateTime.now();
    for (final jeton in entendus.keys) {
      if (connus.contains(jeton)) {
        // Nommé : s'il avait été refusé avant, on oublie ce refus.
        _sansReponse.remove(jeton);
      } else {
        _sansReponse.putIfAbsent(jeton, () => maintenant);
      }
    }
  }

  Future<void> _peutEtre() async {
    if (doitDemander(
      creneauCourant: ProximityIdentity.slotIndex(DateTime.now()),
      creneauDernierAppel: _slot,
      jetonsConnus: _last.map((p) => p.token),
      jetonsEntendus: ref.read(ecouteLocaleProvider).keys,
      abandonnes: _abandonnes(DateTime.now()),
    )) {
      await refresh();
    }
  }

  /// Les jetons dont on a cessé d'attendre un nom, à cet instant.
  Set<String> _abandonnes(DateTime maintenant) => {
    for (final e in _sansReponse.entries)
      if (maintenant.difference(e.value) >= _abandonApres) e.key,
  };

  /// **Faut-il redemander au serveur ?** Fonction pure, donc éprouvable.
  ///
  /// ⚠️ **Elle est ici, séparée et sans état, parce que se tromper ici ne lève
  /// RIEN.** Répondre « oui » trop souvent rend l'économie nulle sans que rien
  /// ne s'affiche de faux ; répondre « non » à tort rend des gens invisibles.
  /// Les deux défauts se comptent, ils ne se voient pas — d'où le test.
  static bool doitDemander({
    required int creneauCourant,
    required int creneauDernierAppel,
    required Iterable<String?> jetonsConnus,
    required Iterable<String> jetonsEntendus,
    Set<String> abandonnes = const {},
  }) {
    // ① Le créneau a tourné : tous les jetons du monde ont changé, celui de
    // chacun est à réapprendre. Sans ça, on croirait tout le monde parti.
    if (creneauCourant != creneauDernierAppel) return true;

    // ② On entend quelqu'un qu'on ne sait pas nommer : découverte en cours.
    //    C'est le seul cas qui presse.
    //
    // ⚠️ **Sauf ceux qu'on a déjà renoncé à nommer.** Le serveur écarte les
    // amis de cette liste, et deux amis continuent de crier leur identifiant
    // public : sans ce filtre, chacun redemande éternellement le nom d'un
    // jeton que le serveur ne donnera jamais. Voir [_sansReponse].
    final connus = jetonsConnus.whereType<String>().toSet();
    return jetonsEntendus.any(
      (jeton) => !connus.contains(jeton) && !abandonnes.contains(jeton),
    );
  }

  Future<void> refresh() async {
    final creneau = ProximityIdentity.slotIndex(DateTime.now());
    // Les jetons ont tous changé : ce qu'on avait renoncé à nommer redevient
    // une question ouverte.
    if (creneau != _slot) _sansReponse.clear();
    _slot = creneau;
    try {
      state = _last = await ref.read(pingRepositoryProvider).nearby();
      _noteCeQuiResteSansNom();
    } catch (_) {
      // ⚠️ **On ne vide PAS sur erreur.** Une panne réseau ferait alors
      // disparaître tout le monde de l'écran, ce qui est indiscernable de
      // « ils sont partis » — exactement le mensonge qu'on refuse ailleurs.
      // La panne est déjà dite par `pingBeaconProvider.lastError`.
    }
  }
}

final pingNearbySourceProvider =
    NotifierProvider<PingNearbySource, List<NearbyPerson>>(
      PingNearbySource.new,
    );

/// **L'USAGE.** Qui est affiché à cet instant.
///
/// ## ⚠️ La présence se constate EN LOCAL depuis le 2026-08-27
///
/// Cette vue filtrait sur `last_seen_at`, une date **serveur** — donc il fallait
/// aller la rechercher toutes les dix secondes pour qu'elle reste vraie. C'est
/// tout le coût réseau du ping, pour une question à laquelle la radio répond
/// déjà : *j'entends son jeton, donc il est là*.
///
/// ## Deux régimes, et le second n'est qu'un filet
///
/// | Quand | Ce qui décide | Délai |
/// |---|---|---|
/// | on connaît son jeton | **la radio, en local** | [kPingLocalGrace] (10 s) |
/// | on ne le connaît pas encore | la date du serveur | [kPingGraceServeur] |
///
/// ⚠️ **Le second cas n'est pas un oubli, il est nécessaire** : le jeton tourne
/// toutes les 15 minutes, et le nouveau n'est connu qu'après que le pair a
/// republié sa balise (≤ 60 s). Sans ce filet, tout le monde disparaîtrait de
/// l'écran à chaque changement de créneau. On tolère donc [kPingGraceServeur],
/// le temps de réapprendre — et `_peutEtre` force justement un appel au
/// changement de créneau pour que ce trou soit le plus court possible.
class PingNearby extends Notifier<List<NearbyPerson>>
    with DerivedList<NearbyPerson> {
  @override
  List<NearbyPerson> build() {
    final now = ref.watch(expiryClockProvider);
    final entendus = ref.watch(ecouteLocaleProvider);
    return ref
        .watch(pingNearbySourceProvider)
        .where((p) => _present(p, entendus, now))
        .toList(growable: false);
  }

  static bool _present(
    NearbyPerson p,
    Map<String, DateTime> entendus,
    DateTime now,
  ) {
    final jeton = p.token;
    if (jeton != null) {
      final vu = entendus[jeton];
      // ⚠️ **Le jeton connu tranche seul.** S'il n'a jamais été entendu, c'est
      // que la personne n'est pas à portée BLE — le serveur peut la savoir
      // « appariée » depuis deux minutes, elle n'est plus là.
      return vu != null && now.difference(vu) <= kPingLocalGrace;
    }
    // Jeton inconnu : sa balise a expiré, ou le créneau vient de tourner.
    return now.difference(p.lastSeenAt) <= kPingGraceServeur;
  }
}

/// **Croisés récemment** : ceux qu'on peut encore ajouter, mais qui ne sont
/// plus à portée.
///
/// ## ⚠️ Cette liste ne coûte AUCUNE requête
///
/// Elle est la **différence entre deux vues qui existaient déjà** :
///
/// | | Ce que c'est |
/// |---|---|
/// | [pingNearbySourceProvider] | tout le monde apparié depuis moins de 10 min (le serveur) |
/// | [pingNearbyProvider] | ceux qu'on **entend maintenant** (la radio) |
/// | **cette liste** | la différence — croisés, plus là |
///
/// ## Pourquoi cette fenêtre-là, et pas 24 h
///
/// ⚠️ **Une liste doit permettre d'agir.** Au-delà de dix minutes, le serveur
/// refuse la demande d'ami (`private.fenetre_rencontre()`) : afficher des gens
/// croisés il y a six heures produirait une liste de boutons qui ne peuvent que
/// dire non. Ces dix minutes **sont** la définition utile de « récemment » —
/// c'est le temps qu'il te reste pour ajouter quelqu'un que tu viens de croiser.
///
/// ⚠️ **Ce n'est PAS l'ancienne section « Croisés récemment »**, retirée le
/// 2026-08-27. Celle-là lisait les certificats BLE co-signés — qui n'ont jamais
/// abouti une seule fois, donc elle était **vide en permanence**. Celle-ci a une
/// source qui marche.
/// ## 🔴 Deux défauts corrigés le 2026-08-28
///
/// **1. Aucun filtre de temps.** La liste se contentait de soustraire ceux
/// qu'on entend. Or la source n'est remplacée qu'à un appel serveur, qui peut
/// n'arriver qu'au changement de créneau — **quinze minutes** — alors que le
/// serveur refuse la demande d'ami au-delà de **dix**. La section pouvait donc
/// afficher des gens dont le bouton ne peut plus que dire non : précisément ce
/// que sa conception cherchait à éviter.
///
/// **2. Un Provider qui refabrique une List.** L'égalité d'une liste est
/// l'identité en Dart : chaque recalcul réveillait l'écran, même à contenu
/// identique. [DerivedList] compare le résultat.
class CroisesRecemment extends Notifier<List<NearbyPerson>>
    with DerivedList<NearbyPerson> {
  @override
  List<NearbyPerson> build() {
    // ⚠️ **Le temps est une SOURCE.** Sans l'horloge, la fenêtre ne se
    // fermerait qu'au prochain événement sans rapport.
    final now = ref.watch(expiryClockProvider);
    final aPortee = {for (final p in ref.watch(pingNearbyProvider)) p.userId};
    return ref
        .watch(pingNearbySourceProvider)
        .where(
          (p) =>
              !aPortee.contains(p.userId) &&
              now.difference(p.lastSeenAt) <= kFenetreRencontre,
        )
        .toList(growable: false);
  }
}

final croisesRecemmentProvider =
    NotifierProvider<CroisesRecemment, List<NearbyPerson>>(
      CroisesRecemment.new,
    );

/// Le temps qu'il reste pour demander en ami quelqu'un qu'on vient de croiser.
///
/// ⚠️ **C'est la règle du serveur, recopiée ici en connaissance de cause** :
/// `private.fenetre_rencontre()` vaut dix minutes, et
/// `request_connection_from_proximity` refuse au-delà. L'écran ne peut pas
/// l'interroger sans un appel de plus ; il l'applique donc lui-même, et
/// **jamais plus large** — une interface plus stricte que la règle ne laisse
/// passer que ce que la règle accepte, l'inverse serait un défaut.
const kFenetreRencontre = Duration(minutes: 10);

/// Le filet, quand on ne connaît pas encore le jeton de quelqu'un.
///
/// ⚠️ **Il doit couvrir un changement de créneau** : le pair republie sa balise
/// au plus tard 60 s après, et on refait un appel dans la foulée. Deux minutes
/// laissent la marge, sans jamais devenir le régime normal.
const kPingGraceServeur = Duration(minutes: 2);

final pingNearbyProvider = NotifierProvider<PingNearby, List<NearbyPerson>>(
  PingNearby.new,
);

// ⚠️ **canalProximiteOuvertProvider a été SUPPRIMÉ le 2026-08-28.**
//
// Il répondait à « le canal de proximité avec cette personne est-il encore
// ouvert ? ». ChatScreen a cessé de le lire le 2026-08-27, quand la question a
// été reposée à `peerInRangeProvider` — la seule vue qui combine les deux
// sources de présence, la radio pour les amis et le ping pour les inconnus.
// Celui-ci ne lisait que le ping, donc il répondait **faux pour un ami**.
//
// Le garder aurait laissé deux réponses possibles à une même question, dont
// une fausse : exactement ce que ce fichier existe pour empêcher.
