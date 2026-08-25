import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/clock.dart';
import 'package:neovibe/features/proximity/net/ping_nearby_feed.dart';
import 'package:neovibe/features/proximity/net/ping_repository.dart';

/// Ce que ces tests protègent : **le délai de grâce de 30 s, et son coût.**
///
/// Décision de Jay : quelqu'un qui sort de portée reste affiché 30 secondes.
/// Sans elle, une personne à la limite clignoterait — le BLE perd des annonces
/// en permanence, et une porte qui s'ouvre suffit à couper le signal.
///
/// ⚠️ **Le piège est que l'indulgence se paie en réveils.** Une horloge qui bat
/// toutes les 5 s pourrait reconstruire l'écran 12 fois par minute pour ne rien
/// changer. C'est le défaut mesuré au checkup du 2026-08-25 (`RAPPELS.md` #52),
/// et il ne se voit qu'en **comptant**.

NearbyPerson _personne(String id, DateTime vu) =>
    NearbyPerson(userId: id, displayName: 'P-$id', lastSeenAt: vu);

/// La source, pilotable à la main — pas de réseau, pas de radio.
class _SourceFausse extends PingNearbySource {
  @override
  List<NearbyPerson> build() => const [];

  void publier(List<NearbyPerson> gens) => state = gens;
}

({
  ProviderContainer container,
  _SourceFausse source,
  StreamController<DateTime> horloge,
})
_harnais() {
  final horloge = StreamController<DateTime>.broadcast();
  final source = _SourceFausse();
  final container = ProviderContainer(
    overrides: [
      pingNearbySourceProvider.overrideWith(() => source),
      // ⚠️ **Le temps est piloté, jamais attendu.** Un test qui dort mesure la
      // vitesse de la machine autant que le code.
      tickProvider(kExpiryTick).overrideWith((ref) => horloge.stream),
    ],
  );
  // Les DEUX abonnements ouverts avant la première émission : un flux
  // `broadcast` ne rejoue rien, et un provider Riverpod est paresseux.
  container.listen(pingNearbySourceProvider, (_, _) {});
  container.listen(expiryClockProvider, (_, _) {});
  return (container: container, source: source, horloge: horloge);
}

Future<void> _propage() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group("Le délai de grâce — qui est ENCORE là", () {
    test("quelqu'un vu à l'instant est affiché", () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.horloge.close);

      final t0 = DateTime.utc(2026, 8, 26, 12);
      h.horloge.add(t0);
      h.source.publier([_personne('a', t0)]);
      await _propage();

      expect(h.container.read(pingNearbyProvider), hasLength(1));
    });

    test(
      "il reste affiché pendant 30 s après avoir cessé d'être vu, puis part",
      () async {
        final h = _harnais();
        addTearDown(h.container.dispose);
        addTearDown(h.horloge.close);

        final t0 = DateTime.utc(2026, 8, 26, 12);
        h.horloge.add(t0);
        h.source.publier([_personne('a', t0)]);
        await _propage();
        expect(h.container.read(pingNearbyProvider), hasLength(1));

        var reveils = 0;
        h.container.listen(pingNearbyProvider, (_, _) => reveils++);

        // 25 s plus tard : encore dans la grâce.
        h.horloge.add(t0.add(const Duration(seconds: 25)));
        await _propage();
        expect(h.container.read(pingNearbyProvider), hasLength(1));
        expect(
          reveils,
          0,
          reason:
              "L'horloge a battu et la liste est inchangée. Un battement qui "
              "reconstruit l'écran pour rien est le défaut qu'on remplace, pas "
              "celui qu'on installe.",
        );

        // 31 s : la grâce est dépassée.
        h.horloge.add(t0.add(const Duration(seconds: 31)));
        await _propage();

        expect(h.container.read(pingNearbyProvider), isEmpty);
        expect(
          reveils,
          1,
          reason: "Exactement un réveil, quand le contenu change vraiment.",
        );
      },
    );

    test("un voisin qui bouge ne réveille pas la liste", () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.horloge.close);

      final t0 = DateTime.utc(2026, 8, 26, 12);
      h.horloge.add(t0);
      h.source.publier([_personne('a', t0), _personne('b', t0)]);
      await _propage();

      var reveils = 0;
      h.container.listen(pingNearbyProvider, (_, _) => reveils++);

      // Le serveur réémet la même chose — cas courant : le sondage suivant.
      h.source.publier([_personne('a', t0), _personne('b', t0)]);
      await _propage();

      expect(
        reveils,
        0,
        reason:
            "Deux listes au contenu identique. Sans DerivedList et sans "
            "l'égalité de NearbyPerson, chaque sondage réveillerait l'écran — "
            "six fois par minute, pour rien.",
      );
    });

    test("une arrivée réelle réveille une fois", () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.horloge.close);

      final t0 = DateTime.utc(2026, 8, 26, 12);
      h.horloge.add(t0);
      h.source.publier([_personne('a', t0)]);
      await _propage();

      var reveils = 0;
      h.container.listen(pingNearbyProvider, (_, _) => reveils++);

      h.source.publier([_personne('a', t0), _personne('b', t0)]);
      await _propage();

      expect(h.container.read(pingNearbyProvider), hasLength(2));
      expect(reveils, 1);
    });
  });
}
