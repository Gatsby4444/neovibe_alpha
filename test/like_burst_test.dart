import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/content/likes.dart';
import 'package:neovibe/core/widgets/like_burst.dart';
import 'package:neovibe/features/library/feed/publication_caption.dart';

/// Un magasin de likes qui ne parle à personne : on compte les bascules.
class _FauxLikes extends LikesStore {
  _FauxLikes(this.depart);
  final bool depart;
  int bascules = 0;

  @override
  Map<String, LikeState> build() => {'c1': LikeState(count: 3, liked: depart)};

  @override
  Future<void> toggle(String id) async {
    bascules++;
    state = {...state, id: state[id]!.toggled};
  }
}

// ignore: library_private_types_in_public_api
Future<_FauxLikes> poser(
  WidgetTester tester, {
  required bool dejaAime,
  bool doubleTap = false,
}) async {
  final faux = _FauxLikes(dejaAime);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [likesStoreProvider.overrideWith(() => faux)],
      child: MaterialApp(
        home: Scaffold(
          body: LikeBurst(
            contentId: 'c1',
            doubleTap: doubleTap,
            child: const SizedBox(
              key: ValueKey('media'),
              width: 300,
              height: 300,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    ),
  );
  return faux;
}

void main() {
  testWidgets('appui long : ça aime, et le cœur jaillit', (tester) async {
    final faux = await poser(tester, dejaAime: false);

    await tester.longPress(find.byKey(const ValueKey('media')));
    await tester.pump(const Duration(milliseconds: 200));

    expect(faux.bascules, 1);
    expect(faux.state['c1']!.liked, isTrue);
    // Le cœur est là pendant l'animation…
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    await tester.pumpAndSettle();
    // … et il ne reste pas.
    expect(find.byIcon(Icons.favorite), findsNothing);
  });

  testWidgets('déjà aimé : le geste ne défait RIEN', (tester) async {
    final faux = await poser(tester, dejaAime: true);

    await tester.longPress(find.byKey(const ValueKey('media')));
    await tester.pump(const Duration(milliseconds: 200));

    expect(faux.bascules, 0, reason: 'un geste rapide ne retire pas un like');
    expect(faux.state['c1']!.liked, isTrue);
    // L'animation part quand même : le geste a été entendu.
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('double tap : il aime là où il est autorisé, pas ailleurs', (
    tester,
  ) async {
    final avec = await poser(tester, dejaAime: false, doubleTap: true);
    await tester.tap(find.byKey(const ValueKey('media')));
    // Il faut un souffle entre les deux appuis : en dessous de
    // kDoubleTapMinTime, le reconnaisseur ne voit pas un double tap.
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.byKey(const ValueKey('media')));
    await tester.pumpAndSettle();
    expect(avec.bascules, 1);

    final sans = await poser(tester, dejaAime: false);
    await tester.tap(find.byKey(const ValueKey('media')));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.byKey(const ValueKey('media')));
    await tester.pumpAndSettle();
    expect(
      sans.bascules,
      0,
      reason: 'une Vibe : le tap retourne, il n\'aime pas',
    );
  });

  group('La légende', () {
    Future<void> poserLegende(WidgetTester tester, String texte) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  SizedBox(width: 380, child: PublicationCaption(text: texte)),
                ],
              ),
            ),
          ),
        );

    testWidgets('« plus » n\'apparaît que si le texte déborde vraiment', (
      tester,
    ) async {
      await poserLegende(tester, 'Court.');
      expect(find.text('plus'), findsNothing);

      await poserLegende(tester, 'Très long. ' * 60);
      expect(find.text('plus'), findsOneWidget);

      await tester.tap(find.text('plus'));
      await tester.pump();
      expect(find.text('moins'), findsOneWidget);
    });

    test('la limite est de 500 signes, sauts de ligne compris', () {
      expect(kCaptionMax, 500);
    });
  });
}
