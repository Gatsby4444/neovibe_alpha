import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/distance_estimate.dart';
import 'package:neovibe/features/proximity/net/peer_session.dart';
import 'package:neovibe/features/proximity/ping_store.dart';
import 'package:neovibe/features/proximity/presence_feed.dart';

/// Ce que ces tests protègent : **la séparation acquisition / usage**.
///
/// La couche d'acquisition publie à la fréquence des annonces BLE. Si la couche
/// d'affichage ne déduplique pas, on retombe exactement sur le défaut qu'on
/// vient de corriger — sauf qu'il serait invisible, puisque l'écran afficherait
/// quand même la bonne chose. C'est un coût qui ne lève aucune erreur : il ne se
/// voit qu'en comptant les notifications.
PresencePeer _peer({
  String address = 'AA:BB',
  double rssi = -70,
  PresenceStage stage = PresenceStage.identified,
  ProximityBand band = ProximityBand.room,
  ProximityTrend trend = ProximityTrend.stable,
  String userId = 'u-1',
}) {
  final now = DateTime.utc(2026, 8, 20, 12);
  return PresencePeer(
    address: address,
    stage: stage,
    rssi: rssi,
    firstSeen: now,
    lastSeen: now,
    band: band,
    trend: trend,
    txPower: -59,
    snapshot: stage == PresenceStage.identified
        ? PingPeerSnapshot(userId: userId, username: 'Léo', verified: true)
        : null,
  );
}

void main() {
  group('PeerView — l’égalité EST la règle de redessin', () {
    test('un RSSI qui bouge sans changer l’affichage donne la même vue', () {
      final a = PeerView.of(_peer(rssi: -70.0));
      final b = PeerView.of(_peer(rssi: -70.02));
      expect(a.distanceLabel, b.distanceLabel);
      expect(a, b);
    });

    test('un changement de bande donne une vue différente', () {
      expect(
        PeerView.of(_peer(band: ProximityBand.room)),
        isNot(PeerView.of(_peer(band: ProximityBand.contact))),
      );
    });

    test('un changement de tendance donne une vue différente', () {
      expect(
        PeerView.of(_peer(trend: ProximityTrend.stable)),
        isNot(PeerView.of(_peer(trend: ProximityTrend.approaching))),
      );
    });

    test('une distance affichée différente donne une vue différente', () {
      final loin = PeerView.of(_peer(rssi: -95));
      final pres = PeerView.of(_peer(rssi: -45));
      expect(loin.distanceLabel, isNot(pres.distanceLabel));
      expect(loin, isNot(pres));
    });
  });

  group('la tuile ne se reconstruit que quand ELLE change', () {
    test('du bruit de signal ne notifie pas', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Le pair est déjà là : son apparition, elle, est bien un changement.
      container.read(presenceProvider.notifier).publish([_peer(rssi: -70.0)]);
      var notifications = 0;
      container.listen(peerViewProvider('AA:BB'), (_, _) => notifications++);

      container.read(presenceProvider.notifier).publish([_peer(rssi: -70.01)]);
      container.read(presenceProvider.notifier).publish([_peer(rssi: -70.02)]);

      await Future<void>.delayed(Duration.zero);
      expect(notifications, 0);
    });

    test('un changement de bande notifie une fois', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(presenceProvider.notifier).publish([_peer()]);
      var notifications = 0;
      container.listen(peerViewProvider('AA:BB'), (_, _) => notifications++);

      container.read(presenceProvider.notifier).publish([
        _peer(band: ProximityBand.contact),
      ]);
      container.read(presenceProvider.notifier).publish([
        _peer(band: ProximityBand.contact),
      ]);

      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
    });

    test('le voisin qui bouge ne réveille pas ma tuile', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(presenceProvider.notifier).publish([
        _peer(address: 'AA:BB', userId: 'u-1'),
        _peer(address: 'CC:DD', userId: 'u-2'),
      ]);
      var notifications = 0;
      container.listen(peerViewProvider('AA:BB'), (_, _) => notifications++);

      container.read(presenceProvider.notifier).publish([
        _peer(address: 'AA:BB', userId: 'u-1'),
        _peer(address: 'CC:DD', userId: 'u-2', band: ProximityBand.contact),
      ]);

      await Future<void>.delayed(Duration.zero);
      expect(notifications, 0);
    });
  });

  group('PresenceKeys — la composition de la liste', () {
    test('un pair qui bouge sans arriver ni partir ne notifie pas', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(presenceProvider.notifier).publish([_peer()]);
      var notifications = 0;
      container.listen(presenceKeysProvider, (_, _) => notifications++);

      container.read(presenceProvider.notifier).publish([
        _peer(band: ProximityBand.contact, trend: ProximityTrend.approaching),
      ]);

      await Future<void>.delayed(Duration.zero);
      expect(notifications, 0);
    });

    test('une arrivée notifie', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(presenceProvider.notifier).publish([_peer()]);
      var notifications = 0;
      container.listen(presenceKeysProvider, (_, _) => notifications++);

      container.read(presenceProvider.notifier).publish([
        _peer(),
        _peer(address: 'CC:DD', userId: 'u-2'),
      ]);

      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
    });

    test('un pair non identifié ne fait ni tuile NI reconstruction', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      var notifications = 0;
      container.listen(presenceKeysProvider, (_, _) => notifications++);

      container.read(presenceProvider.notifier).publish([_peer()]);
      expect(container.read(presenceKeysProvider).identified, ['AA:BB']);
      final apresLePremier = notifications;

      // Un inconnu apparaît. Plus rien ne l'affiche depuis le 2026-08-27 :
      // son identité ne peut venir que du serveur, jamais de la radio.
      container.read(presenceProvider.notifier).publish([
        _peer(),
        _peer(address: 'CC:DD', stage: PresenceStage.detected),
      ]);

      expect(container.read(presenceKeysProvider).identified, ['AA:BB']);
      expect(container.read(bleNearbyUserIdsProvider), {'u-1'});
      // ⚠️ **C'est ce que MESURE ce test.** Tant que `PresenceKeys` portait un
      // compteur `pending`, cette apparition changeait sa valeur et
      // reconstruisait la liste de l'écran — pour quelque chose d'invisible.
      expect(
        notifications,
        apresLePremier,
        reason: 'un inconnu que rien n\'affiche ne doit rien redessiner',
      );
    });
  });
}
