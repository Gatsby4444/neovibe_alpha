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
    if (!wants) return const [];

    _poll = Timer.periodic(pollEvery, (_) => unawaited(refresh()));
    Future.microtask(refresh);
    return state;
  }

  Future<void> refresh() async {
    try {
      state = await ref.read(pingRepositoryProvider).nearby();
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
