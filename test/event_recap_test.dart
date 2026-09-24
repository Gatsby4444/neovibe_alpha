import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/event.dart';
import 'package:neovibe/core/models/library_vibe.dart';
import 'package:neovibe/core/models/profile.dart';
import 'package:neovibe/core/supabase_providers.dart';
import 'package:neovibe/features/events/event_recap_screen.dart';
import 'package:neovibe/features/events/events_providers.dart';
import 'package:neovibe/features/library_vibes/library_vibes_repository.dart';

/// Le générique de fin de soirée : il s'affiche avec ce que le serveur rend,
/// et avance quand on le touche. Rien n'est lu en base ici.
class _MeNull extends MyProfile {
  @override
  Future<Profile?> build() async => null;
}

void main() {
  final event = NeoEvent(
    id: 'e1',
    kind: EventKind.venue,
    title: 'Jeudi électro',
    venueName: 'Goat',
    createdBy: 'x',
    conversationId: 'c1',
    startsAt: DateTime.now().subtract(const Duration(hours: 4)),
    closedAt: DateTime.now(),
    membersCanAdd: true,
    membersCanRemove: true,
    presentCount: 23,
    guestCount: 0,
    iAmPresent: false,
    iManage: false,
  );

  Widget app() => ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('me'),
      myProfileProvider.overrideWith(_MeNull.new),
      eventByIdProvider('e1').overrideWithValue(event),
      eventRecapProvider('e1').overrideWith(
        (ref) async => const EventRecap(
          presentCount: 23,
          vibeCount: 41,
          metCount: 7,
          newFriendCount: 2,
          friendsPresent: [],
        ),
      ),
      eventPeopleProvider('e1').overrideWith((ref) async => const []),
      conversationLibraryProvider(
        'c1',
      ).overrideWith((ref) async => const <LibraryVibe>[]),
    ],
    child: const MaterialApp(home: EventRecapScreen(eventId: 'e1')),
  );

  testWidgets('le générique ouvre sur la soirée, puis ses chiffres', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Goat'), findsOneWidget);
    expect(find.text('Jeudi électro'), findsOneWidget);

    // Toucher à droite : l'image suivante.
    await tester.tapAt(const Offset(700, 400));
    // Plusieurs pas : les chiffres apparaissent l'un après l'autre, puis
    // montent en comptant.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.text('en chiffres'), findsOneWidget);
    expect(find.text('41'), findsOneWidget);
    expect(find.text('vraies rencontres'), findsOneWidget);

    // Fermer, pour que les minuteries s'arrêtent avec l'écran.
    await tester.pumpWidget(const SizedBox());
  });
}
