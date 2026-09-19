import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/widgets/back_guard.dart';
import 'package:neovibe/core/widgets/cover_host.dart';

/// **La couverture posée sur un écran, et le geste qui la retire** (Jay,
/// 2026-09-19). Ce qui est vérifié :
///
/// - poser / retirer, et le retour système qui retire avant de quitter ;
/// - un balayage vers la droite parti d'une zone libre découvre ; un
///   balayage court ne découvre pas ;
/// - sur un contenu (un carrousel, quelle que soit l'image), le même geste
///   ne découvre jamais : le contenu le garde.
void main() {
  var quitte = 0;
  late CoverHostState host;

  Widget app({Widget? contenuCouverture}) => MaterialApp(
    home: BackGuard(
      onUnhandled: () => quitte++,
      child: Scaffold(
        body: CoverHost(
          child: Builder(
            builder: (context) {
              host = CoverHost.maybeOf(context)!;
              return const Center(child: Text('profil'));
            },
          ),
        ),
      ),
    ),
  );

  setUp(() => quitte = 0);

  Future<void> poser(WidgetTester tester, Widget cover) async {
    await tester.pumpWidget(app());
    host.show(cover);
    await tester.pumpAndSettle();
  }

  testWidgets('poser, puis le retour système retire la couverture — sans '
      'quitter', (tester) async {
    await poser(tester, const ColoredBox(color: Colors.red));
    expect(host.isCovered, isTrue);
    expect(find.byType(ColoredBox), findsWidgets);

    // Le retour système, tel que Flutter le reçoit.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(host.isCovered, isFalse);
    expect(quitte, 0, reason: 'la couverture a pris le retour');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(quitte, 1, reason: 'plus de couverture : la coquille décide');
  });

  testWidgets('un balayage vers la droite sur une zone libre découvre', (
    tester,
  ) async {
    await poser(tester, const ColoredBox(color: Colors.red));
    await tester.drag(find.byType(Uncoverable), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(host.isCovered, isFalse);
  });

  testWidgets('un balayage court ne découvre pas', (tester) async {
    await poser(tester, const ColoredBox(color: Colors.red));
    await tester.drag(find.byType(Uncoverable), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(host.isCovered, isTrue);
  });

  group('un carrousel dans la couverture', () {
    Widget carrousel(PageController c) => PageView(
      controller: c,
      children: const [
        ColoredBox(color: Colors.red),
        ColoredBox(color: Colors.blue),
        ColoredBox(color: Colors.green),
      ],
    );

    testWidgets('première image : balayer vers la droite ne découvre PAS — '
        'un contenu garde le geste', (tester) async {
      // Jay, 2026-09-19 : la sortie n'existe qu'en dehors de tout contenu.
      final c = PageController();
      await poser(tester, carrousel(c));
      await tester.drag(find.byType(PageView), const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(host.isCovered, isTrue);
      c.dispose();
    });

    testWidgets('autre image : le même geste change d\'image, la couverture '
        'reste', (tester) async {
      final c = PageController(initialPage: 1);
      await poser(tester, carrousel(c));
      // Plus d'une demi-page (l'écran de test fait 800 px) : la page change.
      await tester.drag(find.byType(PageView), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(host.isCovered, isTrue);
      expect(c.page, 0, reason: 'on est revenu à la première image');
      c.dispose();
    });
  });

  test('shouldUncover : loin OU vite, jamais pour un souffle', () {
    expect(Uncoverable.shouldUncover(dx: 150, velocity: 0, width: 400), isTrue);
    expect(
      Uncoverable.shouldUncover(dx: 40, velocity: 900, width: 400),
      isTrue,
    );
    expect(
      Uncoverable.shouldUncover(dx: 40, velocity: 100, width: 400),
      isFalse,
    );
    expect(
      Uncoverable.shouldUncover(dx: 5, velocity: 2000, width: 400),
      isFalse,
    );
  });
}
