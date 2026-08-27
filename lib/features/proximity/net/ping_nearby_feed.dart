import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/derived_list.dart';
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

    _poll = Timer.periodic(pollEvery, (_) => unawaited(refresh()));
    Future.microtask(refresh);
    return _last;
  }

  Future<void> refresh() async {
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

/// **L'USAGE.** Qui est affiché à cet instant, délai de grâce appliqué.
class PingNearby extends Notifier<List<NearbyPerson>>
    with DerivedList<NearbyPerson> {
  @override
  List<NearbyPerson> build() {
    final now = ref.watch(expiryClockProvider);
    return ref
        .watch(pingNearbySourceProvider)
        .where((p) => now.difference(p.lastSeenAt) <= kPingGrace)
        .toList(growable: false);
  }
}

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
  return ref.watch(
    pingNearbySourceProvider.select(
      (gens) => gens.any((p) => p.userId == userId),
    ),
  );
});
