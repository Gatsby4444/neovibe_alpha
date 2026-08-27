import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/clock.dart';
import 'package:neovibe/features/proximity/net/ping_beacon_service.dart';
import 'package:neovibe/features/proximity/net/ping_nearby_feed.dart';
import 'package:neovibe/features/proximity/net/ping_repository.dart';
import 'package:neovibe/features/proximity/net/proximity_supervisor.dart';
import 'package:neovibe/features/proximity/net/radio_status.dart';

/// Ce que ces tests protègent : **la présence se constate EN LOCAL.**
///
/// ## ⚠️ Ce qui a changé le 2026-08-27
///
/// Cette vue filtrait sur `last_seen_at`, une date **serveur** — donc il fallait
/// la rechercher toutes les dix secondes pour qu'elle reste vraie. C'était tout
/// le coût réseau du ping, pour une question à laquelle la radio répond déjà :
/// *j'entends son jeton, donc il est là*.
///
/// Question de Jay : *« pourquoi on redemande toujours au serveur une fois
/// qu'une connexion a été vérifiée ? Cela consomme beaucoup de réseau et de
/// batterie. »* Il avait raison.
///
/// ## Les deux régimes, et le second n'est qu'un filet
///
/// | Quand | Ce qui décide | Délai |
/// |---|---|---|
/// | on connaît son jeton | **la radio, en local** | 10 s |
/// | on ne le connaît pas encore | la date du serveur | 2 min |
///
/// ⚠️ **Le piège reste le même qu'avant** : l'indulgence se paie en réveils. Une
/// horloge qui bat toutes les 5 s pourrait reconstruire l'écran douze fois par
/// minute pour ne rien changer (`RAPPELS.md` #52). Ça ne se voit qu'en
/// **comptant**, et ces tests comptent.

NearbyPerson _personne(String id, DateTime vu, {String? jeton}) => NearbyPerson(
  userId: id,
  displayName: 'P-$id',
  lastSeenAt: vu,
  token: jeton,
);

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

/// « La radio vient d'entendre ces jetons, à cet instant. »
void _entend(ProviderContainer c, DateTime quand, List<String> jetons) => c
    .read(ecouteLocaleProvider.notifier)
    .publish({for (final j in jetons) j: quand});

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
      "jeton connu : il part au bout de 10 s de SILENCE RADIO, sans un appel",
      () async {
        final h = _harnais();
        addTearDown(h.container.dispose);
        addTearDown(h.horloge.close);

        final t0 = DateTime.utc(2026, 8, 26, 12);
        h.horloge.add(t0);
        h.source.publier([_personne('a', t0, jeton: 'JETON-A')]);
        _entend(h.container, t0, ['JETON-A']);
        await _propage();
        expect(h.container.read(pingNearbyProvider), hasLength(1));

        var reveils = 0;
        h.container.listen(pingNearbyProvider, (_, _) => reveils++);

        // 8 s de silence : encore là. Le BLE perd des annonces en permanence,
        // une porte qui s'ouvre suffit — on ne fait pas clignoter les gens.
        h.horloge.add(t0.add(const Duration(seconds: 8)));
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

        // 11 s de silence : parti.
        //
        // ⚠️ **Et `lastSeenAt` n'a pas bougé d'un pouce.** C'est tout le sujet :
        // la personne disparaît sans qu'on ait posé la moindre question au
        // serveur. Avant le 2026-08-27, il aurait fallu six appels pour
        // apprendre ce que la radio savait déjà.
        h.horloge.add(t0.add(const Duration(seconds: 11)));
        await _propage();

        expect(h.container.read(pingNearbyProvider), isEmpty);
        expect(
          reveils,
          1,
          reason: "Exactement un réveil, quand le contenu change vraiment.",
        );
      },
    );

    test("entendre de nouveau le ramène, toujours sans appel", () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.horloge.close);

      final t0 = DateTime.utc(2026, 8, 26, 12);
      h.horloge.add(t0);
      h.source.publier([_personne('a', t0, jeton: 'JETON-A')]);
      _entend(h.container, t0, ['JETON-A']);
      await _propage();

      h.horloge.add(t0.add(const Duration(seconds: 11)));
      await _propage();
      expect(h.container.read(pingNearbyProvider), isEmpty);

      // Il repasse derrière la porte : la radio l'entend, il revient.
      final t1 = t0.add(const Duration(seconds: 12));
      _entend(h.container, t1, ['JETON-A']);
      h.horloge.add(t1);
      await _propage();

      expect(h.container.read(pingNearbyProvider), hasLength(1));
    });

    test(
      "jeton INCONNU : on retombe sur la date du serveur, pas sur le silence",
      () async {
        final h = _harnais();
        addTearDown(h.container.dispose);
        addTearDown(h.horloge.close);

        final t0 = DateTime.utc(2026, 8, 26, 12);
        h.horloge.add(t0);
        // Pas de jeton : la balise du pair a expiré, ou le créneau vient de
        // tourner et son nouveau jeton n'est pas encore connu.
        h.source.publier([_personne('a', t0)]);
        await _propage();

        // ⚠️ **Sans ce filet, TOUT LE MONDE disparaîtrait de l'écran à chaque
        // changement de créneau** — toutes les 15 minutes, pendant une minute.
        h.horloge.add(t0.add(const Duration(seconds: 40)));
        await _propage();
        expect(
          h.container.read(pingNearbyProvider),
          hasLength(1),
          reason: "jeton inconnu : le silence radio ne prouve rien",
        );

        // Mais le filet a une fin : deux minutes.
        h.horloge.add(t0.add(const Duration(minutes: 2, seconds: 1)));
        await _propage();
        expect(h.container.read(pingNearbyProvider), isEmpty);
      },
    );

    test(
      "un jeton entendu qui n'est PAS le sien ne le fait pas apparaître",
      () async {
        final h = _harnais();
        addTearDown(h.container.dispose);
        addTearDown(h.horloge.close);

        final t0 = DateTime.utc(2026, 8, 26, 12);
        h.horloge.add(t0);
        h.source.publier([_personne('a', t0, jeton: 'JETON-A')]);
        // On entend quelqu'un d'autre, fort et clair.
        _entend(h.container, t0, ['JETON-DE-QUELQU-UN-DAUTRE']);
        await _propage();

        expect(
          h.container.read(pingNearbyProvider),
          isEmpty,
          reason:
              "Entendre du monde n'est pas entendre CETTE personne. Sans cette "
              "distinction, une foule ferait apparaître n'importe qui.",
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

  _troncature();

  group("l'ACQUISITION démarre sans lire un état qui n'existe pas", () {
    // ⚠️ **La panne du 2026-08-26.** `build()` finissait par `return state;` —
    // or Riverpod n'expose pas l'état pendant la construction : au premier
    // passage avec le ping actif, le provider partait en
    // `Bad state: Tried to read the state of an uninitialized provider`, et
    // toute la section « Autour de toi » avec lui. Relevé sur les deux
    // appareils, à chaque lancement.

    ProviderContainer conteneur({required bool visible}) => ProviderContainer(
      overrides: [
        proximitySupervisorProvider.overrideWith(
          () => _SuperviseurFaux(visible: visible),
        ),
        pingBeaconProvider.overrideWith(_BaliseFausse.new),
        pingRepositoryProvider.overrideWith((ref) => _DepotFaux(ref)),
      ],
    );

    test('ping actif : la première lecture ne lève pas', () {
      final c = conteneur(visible: true);
      addTearDown(c.dispose);
      expect(c.read(pingNearbySourceProvider), isEmpty);
      expect(c.read(pingNearbyProvider), isEmpty);
    });

    test('le dernier constat SURVIT à une reconstruction', () async {
      final c = conteneur(visible: true);
      addTearDown(c.dispose);
      c.listen(pingNearbySourceProvider, (_, _) {});
      await _propage();
      expect(c.read(pingNearbySourceProvider), hasLength(1));

      // Une dépendance bouge — ici la balise. Sans le champ conservé, l'écran
      // se viderait puis se remplirait : un clignotement pour rien.
      (c.read(pingBeaconProvider.notifier) as _BaliseFausse).bouger();
      await _propage();
      expect(
        c.read(pingNearbySourceProvider),
        hasLength(1),
        reason: "une reconstruction ne doit pas effacer ce qu'on sait deja",
      );
    });

    test('ping coupé : la liste est vide, et le souvenir est jeté', () async {
      final c = conteneur(visible: false);
      addTearDown(c.dispose);
      c.listen(pingNearbySourceProvider, (_, _) {});
      await _propage();
      expect(c.read(pingNearbySourceProvider), isEmpty);
    });
  });
}

/// Ce que ce groupe protège : **un plafond n'est pas une mesure.**
///
/// `ping_shortlist` coupe à 500. Le client affichait ce nombre comme un total —
/// « 500 personne(s) ont le ping actif » — alors qu'il y en avait peut-être
/// trois mille. C'est le motif que ce projet traque partout : un chiffre qui a
/// l'air d'être un fait alors que c'est la limite de l'instrument.
class _DepotPlein extends PingRepository {
  _DepotPlein(super.ref, this.rendus);

  final int rendus;
  final limitesRecues = <int>[];

  @override
  Future<PingShortlist> shortlist({
    int limit = PingRepository.shortlistLimit,
  }) async {
    limitesRecues.add(limit);
    return PingShortlist(
      tokens: {for (var i = 0; i < rendus; i++) 'jeton-$i'},
      atLeast: rendus >= limit,
    );
  }
}

void _troncature() {
  group("un plafond atteint se DIT, il ne se lit pas comme un total", () {
    _DepotPlein depot(int rendus) {
      final c = ProviderContainer(
        overrides: [
          pingRepositoryProvider.overrideWith(
            (ref) => _DepotPlein(ref, rendus),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c.read(pingRepositoryProvider) as _DepotPlein;
    }

    test("liste pleine : le compte est un PLANCHER", () async {
      final liste = await depot(500).shortlist();
      expect(liste.length, 500);
      expect(
        liste.atLeast,
        isTrue,
        reason:
            "recevoir exactement ce qu'on demande ne prouve pas qu'il n'y en "
            "avait pas plus — donc on n'affiche pas un total",
      );
    });

    test("liste partielle : le compte est un TOTAL", () async {
      final liste = await depot(3).shortlist();
      expect(liste.length, 3);
      expect(liste.atLeast, isFalse);
    });

    test(
      "le client impose SA limite, il ne subit pas celle du serveur",
      () async {
        // Une limite subie doit être connue de celui qui la subit : sans la
        // passer, le client ne peut pas savoir si la liste a été coupée.
        final d = depot(10);
        await d.shortlist(limit: 10);
        expect(d.limitesRecues, [10]);
        expect(PingRepository.shortlistLimit, 500);
      },
    );
  });
}

/// Superviseur figé : on ne teste ici que l'intention, pas la radio.
class _SuperviseurFaux extends ProximitySupervisor {
  _SuperviseurFaux({required this.visible});
  final bool visible;

  @override
  ProximityRuntime build() => ProximityRuntime(
    wantsVisible: visible,
    status: const RadioIdle(),
    intentLoaded: true,
  );
}

/// Balise figée — mais qui sait notifier, pour provoquer la reconstruction.
class _BaliseFausse extends PingBeaconService {
  @override
  PingBeaconState build() => const PingBeaconState();

  void bouger() => state = const PingBeaconState(listening: 1);
}

class _DepotFaux extends PingRepository {
  _DepotFaux(super.ref);

  @override
  Future<List<NearbyPerson>> nearby() async => [
    _personne('a', DateTime.now().toUtc()),
  ];
}
