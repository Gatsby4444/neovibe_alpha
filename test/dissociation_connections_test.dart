import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
({ProviderContainer container, StreamController<List<Connection>> source})
_harnais() {
  final source = StreamController<List<Connection>>.broadcast();
  final container = ProviderContainer(
    overrides: [connectionsStreamProvider.overrideWith((ref) => source.stream)],
  );
  container.listen(connectionsStreamProvider, (_, _) {});
  return (container: container, source: source);
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

  group('Le temps : une valeur périmable qui ne se réévalue jamais', () {
    test(
      'une connexion partielle expirée doit disparaître sans qu\'un événement '
      'sans rapport ne survienne',
      () async {
        final h = _harnais();
        addTearDown(h.container.dispose);
        addTearDown(h.source.close);

        // Elle expire dans 200 ms : personne n'écrira en base entre-temps.
        h.source.add([
          _conn(
            id: 'b',
            status: ConnectionStatus.partial,
            expire: DateTime.now().add(const Duration(milliseconds: 200)),
          ),
        ]);
        await _propage();
        _sourceArrivee(h.container, 1);
        expect(h.container.read(partialConnectionsProvider), hasLength(1));

        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(
          h.container.read(partialConnectionsProvider),
          isEmpty,
          reason:
              'Le filtre appelle DateTime.now(), mais le provider ne se '
              'recalcule que si la SOURCE change. Une connexion partielle '
              'expirée reste donc affichée tant que personne n\'écrit dans la '
              'table — exactement la « disparition buggée » déjà rencontrée '
              'sur les messages le 2026-07-13, corrigée là-bas et pas ici.',
        );
      },
    );
  });
}
