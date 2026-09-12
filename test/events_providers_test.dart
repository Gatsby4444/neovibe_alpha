import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/supabase_providers.dart';
import 'package:neovibe/features/events/events_providers.dart';

/// **Le mode événement — ce qui se compte, pas ce qui se voit.**
///
/// Ces tests ne parlent à aucun serveur : ils remplacent les deux flux bruts
/// (mes présences, les présences d'un événement, les invités) par des
/// contrôleurs, et **comptent les réveils** des vues dérivées. Un défaut de
/// dissociation ne lève aucune erreur — il ne se voit qu'en comptant
/// (règle de `CLAUDE.md`).

Map<String, dynamic> _presence({
  required String id,
  required String event,
  required String user,
  bool ouverte = true,
}) => {
  'id': id,
  'event_id': event,
  'user_id': user,
  'joined_at': '2026-09-12T20:00:00Z',
  'left_at': ouverte ? null : '2026-09-12T23:00:00Z',
};

Map<String, dynamic> _invite({required String event, required String user}) => {
  'event_id': event,
  'user_id': user,
  'role': 'admin',
};

({
  ProviderContainer container,
  StreamController<List<Map<String, dynamic>>> miennes,
  StreamController<List<Map<String, dynamic>>> presences,
  StreamController<List<Map<String, dynamic>>> invites,
})
_harnais() {
  final miennes = StreamController<List<Map<String, dynamic>>>.broadcast();
  final presences = StreamController<List<Map<String, dynamic>>>.broadcast();
  final invites = StreamController<List<Map<String, dynamic>>>.broadcast();
  final container = ProviderContainer(
    overrides: [
      currentUserIdProvider.overrideWithValue('moi'),
      realtimeEpochProvider.overrideWithValue(0),
      myPresencesStreamProvider.overrideWith((ref) => miennes.stream),
      // Le même flux pour tout événement : les tests n'en ouvrent qu'un.
      eventPresencesStreamProvider.overrideWith((ref, id) => presences.stream),
      eventGroupMembersStreamProvider.overrideWith((ref) => invites.stream),
    ],
  );
  container.listen(myPresencesStreamProvider, (_, _) {});
  container.listen(eventGroupMembersStreamProvider, (_, _) {});
  return (
    container: container,
    miennes: miennes,
    presences: presences,
    invites: invites,
  );
}

Future<void> _propage() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('currentEventIdProvider — « où suis-je ? »', () {
    test('aucune présence ouverte → nul', () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      h.miennes.add([
        _presence(id: 'p1', event: 'ev-a', user: 'moi', ouverte: false),
      ]);
      await _propage();
      expect(h.container.read(currentEventIdProvider), isNull);
      expect(h.container.read(inEventModeProvider), isFalse);
    });

    test('la présence ouverte désigne l\'événement, les fermées non', () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      h.miennes.add([
        _presence(id: 'p1', event: 'ev-a', user: 'moi', ouverte: false),
        _presence(id: 'p2', event: 'ev-b', user: 'moi'),
      ]);
      await _propage();
      expect(h.container.read(currentEventIdProvider), 'ev-b');
      expect(h.container.read(inEventModeProvider), isTrue);
    });

    test('deux émissions au même contenu → un seul réveil', () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      var reveils = 0;
      h.container.listen(currentEventIdProvider, (_, _) => reveils++);

      h.miennes.add([_presence(id: 'p2', event: 'ev-b', user: 'moi')]);
      await _propage();
      expect(reveils, 1, reason: 'nul → ev-b : un réveil');

      // Le même contenu, une ligne fermée en plus : l'identifiant ne change
      // pas, personne ne doit se réveiller.
      h.miennes.add([
        _presence(id: 'p2', event: 'ev-b', user: 'moi'),
        _presence(id: 'p0', event: 'ev-z', user: 'moi', ouverte: false),
      ]);
      await _propage();
      expect(
        reveils,
        1,
        reason:
            'L\'identifiant est le même : une vue dérivée qui réveille ici '
            'reconstruirait le bandeau à chaque battement du serveur.',
      );

      h.miennes.add([
        _presence(id: 'p2', event: 'ev-b', user: 'moi', ouverte: false),
      ]);
      await _propage();
      expect(reveils, 2, reason: 'ev-b → nul : un réveil');
    });
  });

  group('eventPeerIdsProvider — qui je reconnais grâce à un événement', () {
    test(
      'union des présents de mon événement et des invités, sans moi',
      () async {
        final h = _harnais();
        addTearDown(h.container.dispose);
        h.container.listen(eventPeerIdsProvider, (_, _) {});
        h.miennes.add([_presence(id: 'p2', event: 'ev-b', user: 'moi')]);
        await _propage();
        h.presences.add([
          _presence(id: 'p2', event: 'ev-b', user: 'moi'),
          _presence(id: 'p3', event: 'ev-b', user: 'alice'),
          _presence(id: 'p4', event: 'ev-b', user: 'bob', ouverte: false),
        ]);
        h.invites.add([
          _invite(event: 'ev-c', user: 'moi'),
          _invite(event: 'ev-c', user: 'carol'),
        ]);
        await _propage();
        expect(h.container.read(eventPeerIdsProvider), {'alice', 'carol'});
      },
    );

    test(
      'un mouvement qui ne change pas l\'ensemble ne réveille personne',
      () async {
        final h = _harnais();
        addTearDown(h.container.dispose);
        var reveils = 0;
        h.container.listen(eventPeerIdsProvider, (_, _) => reveils++);
        h.miennes.add([_presence(id: 'p2', event: 'ev-b', user: 'moi')]);
        await _propage();
        h.presences.add([_presence(id: 'p3', event: 'ev-b', user: 'alice')]);
        await _propage();
        final avant = reveils;
        expect(h.container.read(eventPeerIdsProvider), {'alice'});

        // Alice ressort puis revient : deux lignes, le même ensemble.
        h.presences.add([
          _presence(id: 'p3', event: 'ev-b', user: 'alice', ouverte: false),
          _presence(id: 'p5', event: 'ev-b', user: 'alice'),
        ]);
        await _propage();
        expect(h.container.read(eventPeerIdsProvider), {'alice'});
        expect(
          reveils,
          avant,
          reason:
              'L\'ensemble est identique : relire le carnet de clés ici serait '
              'une requête serveur pour rien, à chaque aller-retour de '
              'quelqu\'un.',
        );
      },
    );
  });
}
