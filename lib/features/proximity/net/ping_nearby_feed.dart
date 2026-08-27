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

/// Le délai de grâce quand quelqu'un sort de portée.
///
/// ⚠️ **Décision de Jay** : 30 s avant de retirer quelqu'un de l'écran. Sans
/// elle, une personne à la limite de portée clignoterait — le BLE perd des
/// annonces en permanence, et une porte qui s'ouvre suffit à couper le signal
/// une seconde.
///
/// ⚠️ **Elle vit ICI, pas côté serveur.** Le serveur publie un fait
/// (`last_seen_at`) ; l'indulgence est une décision d'affichage, et deux écrans
/// pourraient légitimement en vouloir deux différentes.
const kPingGrace = Duration(seconds: 30);

/// Le silence radio au bout duquel on considère que la personne est partie.
///
/// ⚠️ **C'est ce délai qui décide de l'affichage depuis le 2026-08-27**, et il
/// ne coûte **aucun appel réseau** : la radio crie ~10 fois par seconde, donc
/// dix secondes de silence sont une centaine d'annonces manquées d'affilée.
///
/// ⚠️ **Il remplace [kPingGrace] quand on connaît le jeton de la personne.** Le
/// délai de grâce de 30 s se comptait sur une date **serveur**, qu'il fallait
/// aller chercher toutes les dix secondes pour qu'elle reste vraie. Ici, la
/// question « est-il encore là ? » se répond avec ce que la radio entend déjà.
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
    Future.microtask(refresh);
    return _last;
  }

  /// Le créneau du dernier appel : au changement, les jetons de tout le monde
  /// changent et il faut les réapprendre.
  int _slot = -1;

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
  Future<void> _peutEtre() async {
    final creneau = ProximityIdentity.slotIndex(DateTime.now());
    if (creneau != _slot) {
      await refresh();
      return;
    }
    final connus = {for (final p in _last) p.token}..remove(null);
    final entendus = ref.read(ecouteLocaleProvider).keys;
    if (entendus.any((jeton) => !connus.contains(jeton))) await refresh();
  }

  Future<void> refresh() async {
    _slot = ProximityIdentity.slotIndex(DateTime.now());
    try {
      state = _last = await ref.read(pingRepositoryProvider).nearby();
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
/// | on ne le connaît pas encore | la date du serveur | [kPingGrace] élargi |
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

/// Le filet, quand on ne connaît pas encore le jeton de quelqu'un.
///
/// ⚠️ **Il doit couvrir un changement de créneau** : le pair republie sa balise
/// au plus tard 60 s après, et on refait un appel dans la foulée. Deux minutes
/// laissent la marge, sans jamais devenir le régime normal.
const kPingGraceServeur = Duration(minutes: 2);

final pingNearbyProvider = NotifierProvider<PingNearby, List<NearbyPerson>>(
  PingNearby.new,
);

/// **Le canal de proximité avec [userId] est-il encore OUVERT ?**
///
/// ## ⚠️ La même question que le serveur, posée à la même source
///
/// Écrire dans un canal de proximité exige, **côté serveur**, une paire mutuelle
/// constatée depuis moins de dix minutes (politique `messages_insert_member` →
/// `private.can_write_in_conversation`, 2026-08-27). Or `ping_nearby` rend
/// exactement les paires de moins de dix minutes : c'est donc
/// [pingNearbySourceProvider] — la source, **pas** la vue à 30 s — qui répond à
/// la question du serveur, sans requête de plus.
///
/// ⚠️ **Ne pas prendre [pingNearbyProvider] ici.** Il applique le délai de grâce
/// d'affichage de 30 secondes, qui répond à « est-il là *maintenant* ? ». Le
/// canal, lui, ne se ferme pas parce qu'une porte a coupé le signal trois
/// secondes — le BLE en perd en permanence, et c'est précisément pour ça que ce
/// délai de grâce existe. Deux questions, deux seuils, et il faut prendre celui
/// que le serveur applique, sinon l'écran interdit ce que le serveur accepte.
///
/// ⚠️ **Ping coupé = canal fermé**, et c'est volontaire. La liste se vide quand
/// l'utilisateur coupe sa visibilité ; l'écran est alors **plus strict que le
/// serveur** pendant au plus dix minutes. C'est le bon sens du produit : le
/// canal vit tant que la proximité est *prouvée*, et couper le ping, c'est
/// cesser de la prouver. Une interface plus stricte que le serveur ne laisse
/// jamais passer ce que la règle refuse — l'inverse serait un défaut.
///
/// ⚠️ **Le `.select` n'est pas décoratif** : il réduit une liste à un booléen,
/// donc l'écran de conversation n'est réveillé que quand **cette** personne
/// entre ou sort de la fenêtre — pas à chaque tour du ping, toutes les dix
/// secondes.
final canalProximiteOuvertProvider = Provider.family<bool, String>((
  ref,
  userId,
) {
  // ⚠️ **On lit la vue AFFICHÉE, pas la source.** La source, c'est « le serveur
  // nous a appariés il y a moins de dix minutes » ; la vue, c'est « je l'entends
  // maintenant ». Depuis que la présence se constate en local (2026-08-27), la
  // seconde est à la fois plus juste et gratuite.
  //
  // ⚠️ **L'écran est donc plus strict que le serveur, et c'est le bon sens.**
  // Le serveur tolère `private.fenetre_canal()` (3 min) parce qu'il ne peut pas
  // savoir mieux — c'est son filet contre un client muet ou en retard. L'écran,
  // lui, sait en dix secondes. Une interface plus stricte que la règle ne laisse
  // jamais passer ce que la règle refuse ; l'inverse serait un défaut.
  return ref.watch(
    pingNearbyProvider.select((gens) => gens.any((p) => p.userId == userId)),
  );
});
