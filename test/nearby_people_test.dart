import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/nearby_people.dart';
import 'package:neovibe/features/proximity/net/peer_session.dart';
import 'package:neovibe/features/proximity/net/ping_repository.dart';
import 'package:neovibe/features/proximity/net/ping_nearby_feed.dart';
import 'package:neovibe/features/proximity/ping_store.dart';
import 'package:neovibe/features/proximity/presence_feed.dart';

/// Ce que ces tests protègent : **« à portée » a DEUX sources depuis le
/// 2026-08-27, et une vue qui n'en lit qu'une ment sans rien lever.**
///
/// Tant que l'identité d'un inconnu venait de la radio, la présence avait une
/// seule source et une seule réponse. Depuis que le serveur la fournit, un
/// inconnu n'est **jamais** identifié en BLE : la vue d'origine le déclarait
/// donc hors de portée à deux mètres, et la conversation de proximité affichait
/// en permanence « Hors de portée — ce canal se fermera sans échange mutuel ».
///
/// Rien ne le signalait : l'écran affichait quelque chose, c'était simplement
/// faux.
class _PresenceFausse extends PresenceFeed {
  @override
  List<PresencePeer> build() => const [];
}

class _PingFaux extends PingNearby {
  @override
  List<NearbyPerson> build() => const [];
}

NearbyPerson _inconnu(String id) =>
    NearbyPerson(userId: id, displayName: id, lastSeenAt: DateTime.now());

PresencePeer _ami(String id) {
  final registre = PeerRegistry();
  final session = registre.observe('AA-$id', -60);
  registre.identify(
    session,
    PingPeerSnapshot(userId: id, username: id, verified: true),
  );
  return session.toPresence();
}

void main() {
  late ProviderContainer c;
  late _PresenceFausse radio;
  late _PingFaux serveur;

  setUp(() {
    radio = _PresenceFausse();
    serveur = _PingFaux();
    c = ProviderContainer(
      overrides: [
        presenceProvider.overrideWith(() => radio),
        pingNearbyProvider.overrideWith(() => serveur),
      ],
    );
    // Riverpod est paresseux : sans abonnement, la vue ne se construit pas.
    c.listen(nearbyUserIdsProvider, (_, _) {});
    addTearDown(c.dispose);
  });

  test('un AMI vu par la radio est à portée', () {
    radio.publish([_ami('u-ami')]);
    expect(c.read(isNearbyProvider('u-ami')), isTrue);
  });

  test('un INCONNU vu par le serveur est à portée — le défaut corrigé', () {
    serveur.state = [_inconnu('u-inconnu')];
    expect(
      c.read(isNearbyProvider('u-inconnu')),
      isTrue,
      reason:
          "il n'est jamais identifié par la radio : la vue qui ne lisait que "
          "le BLE le déclarait hors de portée à deux mètres",
    );
  });

  test('les deux sources se cumulent, elles ne se remplacent pas', () {
    radio.publish([_ami('u-ami')]);
    serveur.state = [_inconnu('u-inconnu')];
    expect(c.read(nearbyUserIdsProvider), {'u-ami', 'u-inconnu'});
  });

  test("quelqu'un que personne ne voit n'est pas à portée", () {
    expect(c.read(isNearbyProvider('u-absent')), isFalse);
  });

  test('un ensemble inchangé ne réveille personne', () async {
    // ⚠️ Un `Set` n'a pas d'égalité de valeur en Dart : sans `DerivedSet`, cette
    // vue réveillerait ses lecteurs à chaque tour du ping — toutes les dix
    // secondes — pour un ensemble identique. Ce défaut n'affiche rien de faux,
    // il ne se voit qu'en COMPTANT.
    serveur.state = [_inconnu('u-x')];
    var reveils = 0;
    c.listen(nearbyUserIdsProvider, (_, _) => reveils++);

    // ⚠️ Riverpod notifie ses auditeurs de façon ASYNCHRONE : vérifier tout de
    // suite mesurerait la mécanique du framework, pas notre règle.
    serveur.state = [_inconnu('u-x')];
    await Future<void>.delayed(Duration.zero);
    expect(reveils, 0, reason: 'même contenu, aucun réveil');

    serveur.state = [_inconnu('u-x'), _inconnu('u-y')];
    await Future<void>.delayed(Duration.zero);
    expect(reveils, 1, reason: 'une vraie arrivée réveille une fois');
  });
}
