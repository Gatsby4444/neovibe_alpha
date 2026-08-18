import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/nearby_user.dart';
import 'package:neovibe/features/proximity/net/peer_session.dart';
import 'package:neovibe/features/proximity/ping_store.dart';

/// Horloge pilotée : la présence est une machine à états **dans le temps**. La
/// tester avec l'horloge réelle reviendrait à faire dormir le test — donc à ne
/// jamais le lancer.
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
const autre = PingPeerSnapshot(userId: 'u-2', username: 'Bob', verified: true);

void main() {
  group('ce que le registre montre', () {
    test('un inconnu détecté EXISTE, avant même d\'être identifié', () {
      final r = PeerRegistry();
      r.observe('AA', -70);

      // C'est le défaut B5 : l'ancienne couche n'avait pas d'endroit où ranger
      // celui-ci, donc l'écran disait « personne à proximité » pendant que deux
      // téléphones se parlaient.
      expect(r.length, 1);
      expect(r.peers.single.stage, PresenceStage.detected);
      expect(r.identifiedCount, 0);
    });

    test('le stade se DÉDUIT, il ne se range pas', () {
      final r = PeerRegistry();
      final s = r.observe('AA', -70);
      expect(s.stage, PresenceStage.detected);

      r.identify(s, profil);
      expect(s.stage, PresenceStage.identified);

      // ⚠️ Le stade était un champ que trois chemins devaient penser à écrire,
      // et l'un d'eux l'oubliait toujours : un ami identifié par poignée de
      // main s'affichait comme un inconnu. Un état dérivé ne peut pas être
      // oublié.
      expect(r.peers.single.stage, PresenceStage.identified);
    });

    test('les identifiés passent devant, puis le signal décide', () {
      final r = PeerRegistry();
      r.observe('AA', -40); // inconnu très proche
      r.identify(r.observe('BB', -85), profil); // ami lointain

      expect(r.peers.first.address, 'BB');
      expect(r.peers.last.address, 'AA');
    });
  });

  group('« il est là » ne se dit qu\'avec une preuve récente', () {
    test('passé le délai de fraîcheur, le pair n\'est plus montré', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);
      r.identify(r.observe('AA', -70), profil);
      expect(r.isPresent('u-1'), isTrue);

      h.avance(PresenceRules.freshFor + const Duration(seconds: 1));

      // ⚠️ **C'est la correction du mensonge le plus coûteux du chantier.** La
      // liste tolérait 25 secondes d'absence d'annonce, et l'infini pour un
      // pair encore relié — alors que le commentaire du fournisseur promettait
      // « jamais un souvenir ». On pouvait écrire à quelqu'un parti depuis
      // plusieurs minutes.
      expect(r.peers, isEmpty);
      expect(r.isPresent('u-1'), isFalse);
      expect(
        r.length,
        1,
        reason: 'la session vit encore, elle n\'est pas montrée',
      );
    });

    test('une trame reçue rafraîchit autant qu\'une annonce', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);
      final s = r.identify(r.observe('AA', -70), profil).session;

      h.avance(PresenceRules.freshFor + const Duration(seconds: 1));
      expect(r.isPresent('u-1'), isFalse);

      // ⚠️ Sans cette règle, il faudrait un SECOND délai de grâce pour ne pas
      // couper une conversation en cours — et l'on aurait de nouveau deux
      // horloges qui se contredisent, ce qui a coûté cinq itérations.
      s.noteTraffic(h.call());
      expect(r.isPresent('u-1'), isTrue);
    });

    test('la session est oubliée, et pas seulement masquée', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);
      r.observe('AA', -70);

      h.avance(PresenceRules.freshFor + const Duration(seconds: 1));
      expect(
        r.expired(),
        isEmpty,
        reason: 'une annonce manquée n\'est pas un départ',
      );

      h.avance(PresenceRules.forgetAfter);
      expect(r.expired().single.addresses, contains('AA'));
    });
  });

  group('le seuil anti-passant', () {
    test('quelques annonces brèves ne suffisent pas', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);
      final s = r.observe('AA', -70);

      h.avance(const Duration(seconds: 3));
      r.observe('AA', -70);

      // ⚠️ L'objection de Jay : ne pas payer une poignée de main complète pour
      // quelqu'un qui traverse le couloir ou une voiture qui s'arrête au feu.
      expect(s.isStable(h.call()), isFalse);
    });

    test('un contact continu assez long, avec assez d\'annonces, suffit', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);
      final s = r.observe('AA', -70);
      for (var i = 0; i < PresenceRules.minSightings; i++) {
        h.avance(const Duration(seconds: 3));
        r.observe('AA', -70);
      }
      expect(s.isStable(h.call()), isTrue);
    });

    test('beaucoup d\'annonces en un instant ne suffisent PAS', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);
      final s = r.observe('AA', -70);
      for (var i = 0; i < 50; i++) {
        r.observe('AA', -70);
      }

      // ⚠️ **C'est pourquoi la mesure est une durée et non un compte.**
      // L'advertising BLE tourne à ~100 ms : « 15 pings » serait atteint en
      // moins de deux secondes et ne filtrerait rien du tout.
      expect(s.sightings, greaterThan(15));
      expect(s.isStable(h.call()), isFalse);
    });

    test('la durée de contact se compte depuis la PREMIÈRE vue', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);
      final s = r.observe('AA', -70);
      h.avance(const Duration(seconds: 12));
      r.observe('AA', -70);

      // La compter depuis la dernière annonce la remettrait à zéro toutes les
      // 100 ms, et aucun croisement ne serait jamais certifié.
      expect(s.contactDuration(h.call()), const Duration(seconds: 12));
    });
  });

  group('le signal', () {
    test('le RSSI est lissé : une mesure aberrante ne bascule pas tout', () {
      final r = PeerRegistry();
      r.observe('AA', -80);
      r.observe('AA', -30); // pic isolé, typique d'une réflexion

      expect(r.peers.single.rssi, greaterThan(-80));
      expect(r.peers.single.rssi, lessThan(-50));
      expect(r.peers.single.level, ProximityLevel.close);
    });

    test('l\'hystérésis empêche le clignotement à la frontière', () {
      final r = PeerRegistry();
      for (var i = 0; i < 20; i++) {
        r.observe('AA', -40);
      }
      expect(r.peers.single.level, ProximityLevel.veryClose);

      // Juste sous le seuil d'entrée (-58) mais au-dessus du seuil de sortie
      // (-66) : sans hystérésis, ça basculerait ici.
      for (var i = 0; i < 20; i++) {
        r.observe('AA', -60);
      }
      expect(r.peers.single.level, ProximityLevel.veryClose);

      for (var i = 0; i < 20; i++) {
        r.observe('AA', -75);
      }
      expect(r.peers.single.level, ProximityLevel.close);
    });
  });

  group('une personne, une session', () {
    test('un changement d\'adresse MAC ne compte QU\'UNE fois', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);

      // Android change périodiquement l'adresse MAC pour empêcher le pistage :
      // la même personne apparaît sous deux adresses. Jay, le 2026-08-16 :
      // « j'ai deux fois mimi sur mon téléphone ».
      r.identify(r.observe('AA:ancienne', -70), profil);
      h.avance(const Duration(seconds: 2));
      final apres = r.identify(r.observe('BB:nouvelle', -65), profil);

      expect(r.length, 1);
      expect(
        apres.session.addresses,
        containsAll(['AA:ancienne', 'BB:nouvelle']),
      );
      expect(r.byUser('u-1'), isNotNull);
    });

    test('les deux adresses restent des clés de la même session', () {
      final r = PeerRegistry();
      r.identify(r.observe('AA', -70), profil);
      r.identify(r.observe('BB', -65), profil);

      // ⚠️ **C'est ce qui supprime la famille « adresse abandonnée ».** L'ancien
      // code retirait l'entrée perdante et se promettait de refermer son
      // transport au battement suivant — jusqu'à 3 secondes pendant lesquelles
      // une adresse sans identité gardait un canal vivant.
      expect(identical(r.byAddress('AA'), r.byAddress('BB')), isTrue);
    });

    test('la fusion garde le contact le plus ANCIEN', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);
      r.identify(r.observe('AA', -70), profil);
      h.avance(const Duration(seconds: 8));
      final apres = r.identify(r.observe('BB', -65), profil);

      // Sinon un renouvellement de MAC remettrait la durée de contact à zéro,
      // et un croisement ne serait jamais certifié sur un appareil qui change
      // d'adresse souvent.
      expect(apres.session.contactDuration(h.call()).inSeconds, 8);
    });

    test('l\'adresse annoncée suit, l\'adresse du lien ne bouge pas', () {
      final h = Horloge();
      final r = PeerRegistry(clock: h.call);
      final s = r.identify(r.observe('AA', -70), profil).session;
      s.linkAddress = 'AA';
      h.avance(const Duration(seconds: 2));
      r.identify(r.observe('BB', -65), profil);

      // Une connexion GATT survit au renouvellement de la MAC : elle est liée
      // au lien, pas à l'adresse annoncée. Viser aveuglément la plus récente
      // rouvrait une connexion alors qu'une session vivante existait déjà.
      expect(s.advertAddress, 'BB');
      expect(s.address, 'AA', reason: 'on parle par le lien tant qu\'il vit');
    });

    test('deux personnes distinctes ne fusionnent jamais', () {
      final r = PeerRegistry();
      r.identify(r.observe('AA', -70), profil);
      r.identify(r.observe('BB', -70), autre);
      expect(r.length, 2);
    });
  });

  test('fermer une session ne peut pas se faire à moitié', () {
    final r = PeerRegistry();
    final s = r.identify(r.observe('AA', -70), profil).session;
    s.linkAddress = 'AA';
    s.profileSent = true;
    s.certified = true;
    s.connecting = true;
    s.awaitingSince = DateTime.now();

    s.release();

    // ⚠️ **La raison d'être de cet objet.** Chaque défaut du chantier était « la
    // collection X a été nettoyée, la Y non » — au point que la boucle de
    // nettoyage existait en deux exemplaires aux corps divergents.
    expect(s.link, isNull);
    expect(s.channel, isNull);
    expect(s.linkAddress, isNull);
    expect(s.profileSent, isFalse);
    expect(s.connecting, isFalse);
    expect(s.awaitingSince, isNull);
  });

  test('la radio qui s\'arrête rend TOUTES les sessions à fermer', () {
    final r = PeerRegistry();
    r.identify(r.observe('AA', -70), profil);
    r.observe('BB', -70);

    final restantes = r.drain();

    // Garder la liste présenterait un souvenir comme une observation ; la vider
    // sans rendre les sessions laisserait des canaux vivants que plus rien ne
    // désigne — le second chemin, jamais soupçonné avant le 2026-08-18.
    expect(restantes.length, 2);
    expect(r.length, 0);
    expect(r.isPresent('u-1'), isFalse);
  });
}
