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
  _decision();

  group('Croisés récemment — une liste où l\'on peut encore AGIR', () {
    test(
      'quelqu\'un croisé il y a plus de dix minutes disparaît de la liste',
      () async {
        // ⚠️ **Le défaut du 2026-08-28.** Cette liste soustrayait simplement
        // ceux qu'on entend, sans aucune borne de temps. Or sa source n'est
        // remplacée qu'à un appel serveur, qui peut n'arriver qu'au changement
        // de créneau — quinze minutes — alors que le serveur refuse la demande
        // d'ami au-delà de dix (`private.fenetre_rencontre()`). La section
        // affichait donc des gens dont le bouton ne peut plus que dire non.
        final h = _harnais();
        addTearDown(h.container.dispose);
        addTearDown(h.horloge.close);

        final t0 = DateTime.utc(2026, 8, 28, 12);
        h.horloge.add(t0);
        // ⚠️ **Son jeton est connu, mais on ne l'entend pas** : c'est
        // exactement la définition de « croisé, plus à portée ». Sans jeton,
        // on retomberait sur le filet serveur et il compterait comme présent.
        h.source.publier([_personne('a', t0, jeton: 'JETON-A')]);
        await _propage();

        expect(
          h.container.read(pingNearbyProvider),
          isEmpty,
          reason: "jeton connu, jamais entendu : il n'est pas à portée",
        );
        await _propage();

        expect(
          h.container.read(croisesRecemmentProvider),
          hasLength(1),
          reason:
              'croisé à l\'instant, plus entendu : il est bien dans la liste',
        );

        var reveils = 0;
        h.container.listen(croisesRecemmentProvider, (_, _) => reveils++);

        // Neuf minutes : la demande passe encore, la tuile a un sens.
        h.horloge.add(t0.add(const Duration(minutes: 9)));
        await _propage();
        expect(h.container.read(croisesRecemmentProvider), hasLength(1));
        expect(
          reveils,
          0,
          reason:
              'La liste est inchangée. Un battement d\'horloge qui reconstruit '
              'la section pour rien est le défaut qu\'on remplace.',
        );

        // Onze minutes : le serveur dirait non, donc on n'affiche plus.
        h.horloge.add(t0.add(const Duration(minutes: 11)));
        await _propage();
        expect(h.container.read(croisesRecemmentProvider), isEmpty);
        expect(reveils, 1, reason: 'un seul réveil, au moment du changement');
      },
    );

    test('quelqu\'un qu\'on ENTEND n\'est pas « croisé », il est là', () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.horloge.close);

      final t0 = DateTime.utc(2026, 8, 28, 12);
      h.horloge.add(t0);
      h.source.publier([_personne('a', t0, jeton: 'JETON-A')]);
      _entend(h.container, t0, ['JETON-A']);
      await _propage();

      expect(h.container.read(pingNearbyProvider), hasLength(1));
      expect(
        h.container.read(croisesRecemmentProvider),
        isEmpty,
        reason:
            'Les deux listes sont exclusives : la même personne dans les deux '
            'donnerait deux tuiles pour une seule présence.',
      );
    });
  });
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

// ⚠️ **LE GROUPE « un plafond n'est pas une mesure » A ÉTÉ RETIRÉ le 2026-08-28,
// avec son sujet.**
//
// Il protégeait ceci : `ping_shortlist` coupait à 500 jetons, et le client
// affichait ce nombre — « 500 personne(s) ont le ping actif » — alors qu'il y en
// avait peut-être trois mille. Un chiffre qui a l'air d'un fait alors que c'est
// la limite de l'instrument.
//
// **La liste d'écoute n'existe plus.** Le compteur vient de
// `ping_neighbour_count`, un `count(*)` : il rend le vrai nombre, il ne peut
// plus être tronqué, et `listeningTruncated` a disparu avec lui.
//
// ⚠️ **La RÈGLE, elle, n'est pas abandonnée** — elle n'a simplement plus de
// porteur dans ce module. Le jour où un compteur affiché redevient tronqué,
// c'est ce texte qu'il faut relire, pas la règle qu'il faut réinventer.
//
// ⚠️ **Et ce qui a remplacé la liste ne se teste PAS ici.** Ce que la liste
// tenait réellement — la barrière du blocage — est désormais dans
// `confirm_ping`, donc en base. C'est là que c'est vérifié, sous les deux
// identités, sécurité active : blocage → 0 confirmation, 0 paire, 0 demande
// d'ami. Un test Dart ne pourrait que répéter ce que le client croit, pas ce
// que le serveur impose — c'est exactement l'argument que ce fichier tenait
// déjà pour la règle de réciprocité.

/// Superviseur figé : on ne teste ici que l'intention, pas la radio.
class _SuperviseurFaux extends ProximitySupervisor {
  _SuperviseurFaux({required this.visible});
  final bool visible;

  @override
  ProximityRuntime build() => ProximityRuntime(
    // Ce fichier teste la DÉCOUVERTE d'inconnus : le croisement d'amis a son
    // propre interrupteur depuis le 2026-08-28 et n'a rien à faire ici.
    wantsFriends: false,
    wantsDiscovery: visible,
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

/// **Ce que ce groupe MESURE : les appels serveur qu'on ne fait plus.**
///
/// Question de Jay du 2026-08-27 : *« pourquoi on redemande toujours au serveur
/// une fois qu'une connexion a été vérifiée ? »* La réponse fut de ne plus le
/// faire — et **ce fichier est la seule chose qui garantit que ça reste vrai**.
///
/// ⚠️ **Ce défaut ne s'affiche jamais.** Une boucle qui redemande trop souvent
/// montre exactement la bonne chose à l'écran ; seule la facture change. Il a
/// d'ailleurs été introduit **et corrigé** le jour même : les jetons entendus
/// s'accumulaient sans jamais être purgés, si bien qu'au changement de créneau
/// les anciens passaient pour « pas encore nommés » et forçaient un appel toutes
/// les dix secondes, pour toujours. Aucun test ne le voyait. Celui-ci le voit.
void _decision() {
  group('quand redemande-t-on au serveur ?', () {
    test("seul, radio muette : JAMAIS", () {
      expect(
        PingNearbySource.doitDemander(
          creneauCourant: 42,
          creneauDernierAppel: 42,
          jetonsConnus: const [],
          jetonsEntendus: const [],
        ),
        isFalse,
        reason:
            "C'est le cas le plus courant, et l'ancienne boucle y faisait "
            "360 appels par heure pour s'entendre répondre « personne ».",
      );
    });

    test("quelqu'un de déjà connu, entendu : JAMAIS", () {
      expect(
        PingNearbySource.doitDemander(
          creneauCourant: 42,
          creneauDernierAppel: 42,
          jetonsConnus: const ['JETON-A'],
          jetonsEntendus: const ['JETON-A'],
        ),
        isFalse,
        reason:
            "Sa présence se constate en local. Redemander n'apprendrait rien.",
      );
    });

    test("un jeton entendu qu'on ne sait pas nommer : OUI", () {
      expect(
        PingNearbySource.doitDemander(
          creneauCourant: 42,
          creneauDernierAppel: 42,
          jetonsConnus: const ['JETON-A'],
          jetonsEntendus: const ['JETON-A', 'JETON-INCONNU'],
        ),
        isTrue,
        reason:
            "C'est une découverte en cours, et c'est le seul cas qui presse.",
      );
    });

    test("le créneau a tourné : OUI, même sans rien entendre", () {
      expect(
        PingNearbySource.doitDemander(
          creneauCourant: 43,
          creneauDernierAppel: 42,
          jetonsConnus: const ['JETON-A'],
          jetonsEntendus: const [],
        ),
        isTrue,
        reason:
            "Tous les jetons ont changé. Sans cet appel, on croirait tout le "
            "monde parti — toutes les 15 minutes.",
      );
    });

    test("🔴 un jeton que le serveur NE NOMMERA JAMAIS : on renonce", () {
      // ⚠️ **Le défaut mesuré chez Jay le 2026-08-27 à 20 h 16, en pleine
      // session de test.** `ping_nearby` écarte délibérément les amis — cette
      // liste sert à découvrir des inconnus. Mais deux amis continuent de
      // crier leur identifiant PUBLIC : chacun entend donc de l'autre un
      // jeton que le serveur refusera toujours de nommer.
      //
      // La règle « je demande tant que j'entends un jeton inconnu » ne
      // terminait jamais : **122 appels en 7 minutes** dans les journaux du
      // serveur, huit par minute et par appareil — exactement le gaspillage
      // que ce chantier supprimait.
      //
      // ⚠️ **Rien ne l'affichait.** L'écran montrait la bonne chose ; seule
      // la facture changeait. Aucun test ne le voyait : celui-ci le voit.
      expect(
        PingNearbySource.doitDemander(
          creneauCourant: 42,
          creneauDernierAppel: 42,
          jetonsConnus: const [],
          jetonsEntendus: const ['JETON-D-UN-AMI'],
          abandonnes: const {'JETON-D-UN-AMI'},
        ),
        isFalse,
      );
    });

    test("mais on INSISTE tant qu'on n'a pas renoncé", () {
      // ⚠️ **Renoncer au premier refus casserait la découverte.** Quand deux
      // inconnus se croisent, le serveur ne peut nommer personne tant qu'il n'a
      // pas reçu le constat des DEUX côtés — il faut donc réessayer.
      expect(
        PingNearbySource.doitDemander(
          creneauCourant: 42,
          creneauDernierAppel: 42,
          jetonsConnus: const [],
          jetonsEntendus: const ['JETON-D-UN-INCONNU'],
          abandonnes: const {},
        ),
        isTrue,
      );
    });

    test(
      "un jeton PÉRIMÉ ne doit plus rien déclencher — le défaut du 2026-08-27",
      () {
        // ⚠️ **Le cas exact du défaut.** Après une rotation de créneau, les
        // anciens jetons restaient dans la table d'écoute. Ils n'étaient dans
        // aucune liste connue, donc chaque tour de 10 s les prenait pour une
        // découverte en cours — et rappelait le serveur, indéfiniment.
        //
        // La purge vit dans `PingBeaconService._oublieLesVieux` : ce test dit
        // ce qu'on attend d'elle, vu d'ici.
        expect(
          PingNearbySource.doitDemander(
            creneauCourant: 42,
            creneauDernierAppel: 42,
            jetonsConnus: const ['JETON-A'],
            // La table a été purgée : le vieux jeton n'y est plus.
            jetonsEntendus: const ['JETON-A'],
          ),
          isFalse,
        );
      },
    );
  });
}
