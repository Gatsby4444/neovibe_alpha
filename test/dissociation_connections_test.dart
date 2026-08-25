import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/clock.dart';
import 'package:neovibe/core/models/connection.dart';
import 'package:neovibe/features/connections/connections_repository.dart';

/// **Ce que ces tests MESURENT : le coût d'un défaut qui n'affiche rien de faux.**
///
/// Checkup demandé par Jay (`RAPPELS.md` #52), à l'aune de la règle de
/// dissociation acquisition / usage. Le module de proximité a sa version
/// corrigée et son test (`test/presence_feed_test.dart`) ; les connexions, non.
///
/// Ces tests ne vérifient pas que l'écran affiche la bonne chose — il l'affiche.
/// Ils comptent les **notifications**, c'est-à-dire les reconstructions
/// d'interface. C'est la seule façon de voir ce défaut : il ne lève aucune
/// erreur, et les tests fonctionnels passent tous.
///
/// ⚠️ Ces tests **échouent aujourd'hui**, volontairement : ils décrivent ce que
/// la règle exige. Voir `docs/checkup-acquisition-usage.md`.
Connection _conn({
  required String id,
  ConnectionStatus status = ConnectionStatus.full,
  DateTime? expire,
}) => Connection(
  id: id,
  userLow: 'u-low-$id',
  userHigh: 'u-high-$id',
  status: status,
  partialExpiresAt: expire,
);

/// Un container dont la SOURCE est pilotable à la main, sans réseau.
///
/// ⚠️ **L'abonnement est ouvert DÈS la création**, et c'est indispensable : un
/// provider Riverpod est paresseux, il ne s'abonne à sa source qu'au premier
/// lecteur. Sans ce `listen`, la première émission part **avant** que quiconque
/// écoute et se perd — et les tests comptaient alors des notifications qui
/// n'étaient pas celles qu'ils annonçaient.
({
  ProviderContainer container,
  StreamController<List<Connection>> source,
  StreamController<DateTime> horloge,
})
_harnais() {
  final source = StreamController<List<Connection>>.broadcast();
  final horloge = StreamController<DateTime>.broadcast();
  final container = ProviderContainer(
    overrides: [
      connectionsStreamProvider.overrideWith((ref) => source.stream),
      // ⚠️ **Le temps est pilote, jamais attendu.** Un test qui dort pour voir
      // expirer quelque chose mesure la vitesse de la machine autant que le
      // code, et il echoue un jour sur dix sans rien apprendre a personne.
      tickProvider(kExpiryTick).overrideWith((ref) => horloge.stream),
    ],
  );
  // Les DEUX sources doivent etre abonnees avant la premiere emission :
  // un flux `broadcast` ne rejoue rien. Oubli fait trois fois de suite
  // pendant ce chantier, chaque fois avec un compteur qui semblait bon.
  container.listen(connectionsStreamProvider, (_, _) {});
  container.listen(expiryClockProvider, (_, _) {});
  return (container: container, source: source, horloge: horloge);
}

/// Refuse de conclure si la source n'est pas arrivée.
///
/// ⚠️ Sans ce contrôle, **un compteur à zéro ressemble à une réussite** alors
/// qu'il ne prouve que le silence de l'instrument. Deux versions de ce fichier
/// s'y sont fait prendre.
void _sourceArrivee(ProviderContainer c, int attendu) {
  expect(
    c.read(connectionsStreamProvider).value,
    hasLength(attendu),
    reason:
        'La source n\'a pas traversé : rien de ce qui suit ne prouverait '
        'quoi que ce soit.',
  );
}

/// Laisse le flux traverser Riverpod.
///
/// ⚠️ `Duration.zero` ne suffit PAS : un `StreamController` passe par la boucle
/// d'événements, et l'`AsyncValue` n'est pas encore à jour au tour suivant. Une
/// première version de ce fichier comptait donc **zéro notification parce que
/// rien n'était arrivé** — un compteur à zéro qui ressemblait à une réussite.
Future<void> _propage() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('Amplification : une connexion qui change en réveille combien ?', () {
    test(
      'un changement qui ne concerne QUE les partielles ne doit pas réveiller '
      'les complètes',
      () async {
        final h = _harnais();
        addTearDown(h.container.dispose);
        addTearDown(h.source.close);

        final demain = DateTime.now().add(const Duration(days: 1));
        h.source.add([
          _conn(id: 'a'),
          _conn(id: 'b', status: ConnectionStatus.partial, expire: demain),
        ]);
        await _propage();
        _sourceArrivee(h.container, 2);
        expect(h.container.read(fullConnectionsProvider), hasLength(1));

        var reveilsComplets = 0;
        h.container.listen(
          fullConnectionsProvider,
          (_, _) => reveilsComplets++,
        );

        // Seule la partielle bouge : sa date d'expiration recule.
        h.source.add([
          _conn(id: 'a'),
          _conn(
            id: 'b',
            status: ConnectionStatus.partial,
            expire: demain.add(const Duration(hours: 1)),
          ),
        ]);
        await _propage();

        // La liste des complètes est identique — personne ne devrait bouger.
        expect(
          reveilsComplets,
          0,
          reason:
              'La liste des connexions complètes est inchangée. Chaque '
              'notification ici est une reconstruction d\'écran gratuite.',
        );
      },
    );

    test('deux émissions au contenu identique ne doivent produire qu\'un seul '
        'réveil', () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.source.close);

      h.source.add([_conn(id: 'a')]);
      await _propage();
      _sourceArrivee(h.container, 1);

      var reveils = 0;
      h.container.listen(fullConnectionsProvider, (_, _) => reveils++);

      // Le serveur réémet la même chose — cas courant : une colonne sans
      // rapport change, ou le flux temps réel se réabonne.
      h.source.add([_conn(id: 'a')]);
      h.source.add([_conn(id: 'a')]);
      await _propage();

      expect(
        reveils,
        0,
        reason:
            'Le contenu affiché n\'a pas changé. En Dart, l\'égalité d\'une '
            'List est l\'IDENTITÉ : une nouvelle liste au contenu identique '
            'notifie quand même. C\'est le défaut mesuré ici.',
      );
    });
  });

  group('Le temps : une source a part entiere, pilotee', () {
    test('un lien partiel expire disparait au battement suivant, sans aucun '
        'evenement de la base', () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.source.close);
      addTearDown(h.horloge.close);

      final t0 = DateTime.utc(2026, 8, 25, 12);
      h.horloge.add(t0);
      h.source.add([
        _conn(
          id: 'b',
          status: ConnectionStatus.partial,
          expire: t0.add(const Duration(seconds: 30)),
        ),
      ]);
      await _propage();
      _sourceArrivee(h.container, 1);
      expect(h.container.read(partialConnectionsProvider), hasLength(1));

      var reveils = 0;
      h.container.listen(partialConnectionsProvider, (_, _) => reveils++);

      // Le temps passe, mais pas assez : rien ne doit bouger.
      h.horloge.add(t0.add(const Duration(seconds: 10)));
      await _propage();
      expect(
        reveils,
        0,
        reason:
            "L'horloge a battu et la liste est inchangee. Un battement qui "
            "reveille l'ecran pour rien serait le defaut qu'on remplace, pas "
            "celui qu'on installe.",
      );

      // Le temps passe l'echeance : la, et la seulement, ca bouge.
      h.horloge.add(t0.add(const Duration(seconds: 31)));
      await _propage();

      expect(h.container.read(partialConnectionsProvider), isEmpty);
      expect(
        reveils,
        1,
        reason: 'Exactement un reveil, au moment ou le contenu change.',
      );
    });

    test("la vue BRUTE des liens partiels ignore l'horloge", () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.source.close);
      addTearDown(h.horloge.close);

      final t0 = DateTime.utc(2026, 8, 25, 12);
      h.horloge.add(t0);
      h.source.add([
        _conn(
          id: 'b',
          status: ConnectionStatus.partial,
          expire: t0.add(const Duration(seconds: 1)),
        ),
      ]);
      await _propage();

      h.horloge.add(t0.add(const Duration(hours: 1)));
      await _propage();

      expect(
        h.container.read(allPartialConnectionsProvider),
        hasLength(1),
        reason:
            "L'acquisition publie ce qui EST en base. La peremption est une "
            "decision d'affichage : elle appartient a la vue qui l'applique, "
            "pas a celle qui lit la table.",
      );
      expect(h.container.read(partialConnectionsProvider), isEmpty);
    });
  });
}
