import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/nearby_user.dart';
import 'package:neovibe/features/proximity/net/presence_tracker.dart';
import 'package:neovibe/features/proximity/ping_store.dart';

/// Horloge pilotée : le suivi de présence est une machine à états dans le
/// TEMPS. La tester avec l'horloge réelle reviendrait à faire dormir le test —
/// donc à ne le lancer jamais.
class Horloge {
  DateTime instant = DateTime(2026, 8, 16, 12);
  DateTime call() => instant;
  void avance(Duration d) => instant = instant.add(d);
}

const profil = PingPeerSnapshot(
  userId: 'u-1',
  username: 'Mimi',
  verified: true,
);

void main() {
  test('un inconnu détecté EXISTE, avant même d\'être identifié', () {
    final t = PresenceTracker();
    t.observe('AA', -70);

    // C'est tout le défaut B5 : l'ancienne couche n'avait pas d'endroit où
    // ranger celui-ci, donc l'écran disait « personne ».
    expect(t.length, 1);
    expect(t.peers.single.stage, PresenceStage.detected);
    expect(t.identifiedCount, 0);
  });

  test('un ami reconnu à son ID rotatif est identifié sans aucun échange', () {
    final t = PresenceTracker();
    t.observe('AA', -70, friend: profil);

    expect(t.peers.single.stage, PresenceStage.identified);
    expect(t.peers.single.isFriend, isTrue);
    expect(t.isInRange('u-1'), isTrue);
  });

  test('une poignée de main ratée retombe sur « détecté », pas sur rien', () {
    final t = PresenceTracker();
    t.observe('AA', -70);
    t.markIdentifying('AA');
    expect(t.peers.single.stage, PresenceStage.identifying);

    t.markIdentificationFailed('AA');

    // Le pair est toujours là — la radio le voit. Le supprimer dirait
    // « personne à proximité » alors que quelqu'un est bien là.
    expect(t.length, 1);
    expect(t.peers.single.stage, PresenceStage.detected);
  });

  test('une identité acquise ne se reperd pas sur une annonce suivante', () {
    final t = PresenceTracker();
    t.observe('AA', -70);
    t.markIdentified('AA', profil);
    t.observe('AA', -72); // annonce nue, sans reconnaissance

    expect(t.peers.single.stage, PresenceStage.identified);
    expect(t.peers.single.userId, 'u-1');
  });

  test(
    'le RSSI est lissé : une mesure aberrante ne fait pas tout basculer',
    () {
      final t = PresenceTracker();
      t.observe('AA', -80);
      t.observe('AA', -30); // pic isolé, typique d'une réflexion

      // Sans lissage on serait passé net à -30 et l'étiquette aurait sauté.
      expect(t.peers.single.rssi, greaterThan(-80));
      expect(t.peers.single.rssi, lessThan(-50));
      expect(t.peers.single.level, ProximityLevel.close);
    },
  );

  test('l\'hystérésis empêche le clignotement à la frontière', () {
    final t = PresenceTracker();
    // On monte franchement en « très proche ».
    for (var i = 0; i < 20; i++) {
      t.observe('AA', -40);
    }
    expect(t.peers.single.level, ProximityLevel.veryClose);

    // Puis on repasse JUSTE sous le seuil d'entrée (-58), mais au-dessus du
    // seuil de sortie (-66) : sans hystérésis, ça basculerait ici.
    for (var i = 0; i < 20; i++) {
      t.observe('AA', -60);
    }
    expect(t.peers.single.level, ProximityLevel.veryClose);

    // En dessous du seuil de sortie, on redescend.
    for (var i = 0; i < 20; i++) {
      t.observe('AA', -75);
    }
    expect(t.peers.single.level, ProximityLevel.close);
  });

  test('un pair non revu est retiré après le délai de grâce, pas avant', () {
    final h = Horloge();
    final t = PresenceTracker(clock: h.call);
    t.observe('AA', -70);

    h.avance(const Duration(seconds: 20));
    expect(
      t.prune(),
      isEmpty,
      reason: 'une annonce manquée n\'est pas un départ',
    );
    expect(t.length, 1);

    h.avance(const Duration(seconds: 10));
    final partis = t.prune();
    expect(partis.single.address, 'AA');
    expect(t.length, 0);
  });

  test('la durée de contact se compte depuis la PREMIÈRE vue', () {
    final h = Horloge();
    final t = PresenceTracker(clock: h.call);
    t.observe('AA', -70);
    h.avance(const Duration(seconds: 12));
    t.observe('AA', -70);

    // C'est la mesure sur laquelle repose le certificat de croisement (10 s de
    // contact continu). La compter depuis la dernière annonce la remettrait à
    // zéro toutes les secondes.
    expect(t.contactDuration('AA'), const Duration(seconds: 12));
  });

  test('la radio qui s\'arrête vide la présence', () {
    final t = PresenceTracker();
    t.observe('AA', -70, friend: profil);
    t.clear();

    // Garder la liste présenterait un SOUVENIR comme une observation.
    expect(t.length, 0);
    expect(t.isInRange('u-1'), isFalse);
  });

  test('les identifiés passent devant, puis le signal décide', () {
    final t = PresenceTracker();
    t.observe('AA', -40); // inconnu très proche
    t.observe('BB', -85, friend: profil); // ami lointain

    expect(t.peers.first.address, 'BB');
    expect(t.peers.last.address, 'AA');
  });
  test('un ami qui change d\'adresse BLE ne compte QU\'UNE fois', () {
    final h = Horloge();
    final t = PresenceTracker(clock: h.call);

    // Android change périodiquement l'adresse MAC de l'appareil, pour empêcher
    // le pistage. La même personne apparaît donc sous deux adresses.
    t.observe('AA:ancienne', -70, friend: profil);
    h.avance(const Duration(seconds: 2));
    t.observe('BB:nouvelle', -65, friend: profil);

    // Jay, au test du 2026-08-16 : « j'ai deux fois mimi sur mon téléphone ».
    expect(t.length, 1);
    expect(t.peers.single.address, 'BB:nouvelle');
    expect(t.byUser('u-1'), isNotNull);
  });

  test('la fusion garde l\'adresse vue le plus RÉCEMMENT', () {
    final h = Horloge();
    final t = PresenceTracker(clock: h.call);

    t.observe('BB:nouvelle', -65, friend: profil);
    h.avance(const Duration(seconds: 3));
    // Une annonce en retard, émise sous l'ancienne adresse, arrive après.
    t.observe('AA:ancienne', -70, friend: profil);

    // C'est la plus récente qui gagne : c'est par elle que le pair nous parle
    // maintenant, donc c'est elle qui portera le lien GATT.
    expect(t.length, 1);
    expect(t.peers.single.address, 'AA:ancienne');
  });

  test('deux personnes distinctes ne fusionnent jamais', () {
    final t = PresenceTracker();
    const autre = PingPeerSnapshot(
      userId: 'u-2',
      username: 'Bob',
      verified: true,
    );
    t.observe('AA', -70, friend: profil);
    t.observe('BB', -70, friend: autre);

    expect(t.length, 2);
  });
}
