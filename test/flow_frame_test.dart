import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/widgets/action_button.dart';
import 'package:neovibe/features/library/feed/flow_frame.dart';

/// **Le cadre d'un Flow en plein écran** (Jay, 2026-09-20 : l'auteur et la
/// légende *dans* la vidéo, le cœur au milieu de l'écran).
///
/// Ce que ce test défend : un habillage posé à côté de la vidéo ne lève
/// aucune erreur — il se voit seulement à l'œil, sur l'appareil, chez Jay.
void main() {
  const page = Size(400, 800);

  group('Le rectangle de la vidéo', () {
    test('un Flow 9:16 sur une page 9:16 : tout l\'écran', () {
      final r = FlowFrame.rectFor(ratio: 9 / 16, page: const Size(450, 800));
      expect(r, const Rect.fromLTWH(0, 0, 450, 800));
    });

    test('un Flow carré : pleine largeur, centré, deux bandes', () {
      final r = FlowFrame.rectFor(ratio: 1, page: page);
      expect(r, const Rect.fromLTWH(0, 200, 400, 400));
    });

    test('un Flow 4:5 : pleine largeur, centré', () {
      final r = FlowFrame.rectFor(ratio: 4 / 5, page: page);
      expect(r.left, 0);
      expect(r.width, 400);
      expect(r.height, 500);
      expect(r.top, 150);
    });

    test('un Flow plus haut que la page : la hauteur borne, centré', () {
      // Une vidéo bien plus haute que la page : c'est la hauteur qui borne.
      final r = FlowFrame.rectFor(ratio: 1 / 4, page: page);
      expect(r.height, 800);
      expect(r.width, 200);
      expect(r.left, 100);
    });

    test('un ratio absurde ne casse rien : toute la page', () {
      expect(FlowFrame.rectFor(ratio: 0, page: page), Offset.zero & page);
      expect(
        FlowFrame.rectFor(ratio: double.nan, page: page),
        Offset.zero & page,
      );
    });
  });

  group('Ce que la vidéo rend aux bords de l\'écran', () {
    test('une vidéo qui monte sous l\'encoche la rend ; une autre non', () {
      final plein = FlowFrame.rectFor(ratio: 1 / 2, page: page);
      expect(FlowFrame.topInset(rect: plein, safeTop: 40), 40);
      final carre = FlowFrame.rectFor(ratio: 1, page: page);
      expect(FlowFrame.topInset(rect: carre, safeTop: 40), 0);
    });

    test('idem pour la barre du bas', () {
      final plein = FlowFrame.rectFor(ratio: 1 / 2, page: page);
      expect(
        FlowFrame.bottomInset(rect: plein, page: page, safeBottom: 24),
        24,
      );
      final carre = FlowFrame.rectFor(ratio: 1, page: page);
      expect(FlowFrame.bottomInset(rect: carre, page: page, safeBottom: 24), 0);
    });

    test('la place du bouton Fermer : seulement si l\'auteur y arrive', () {
      final plein = FlowFrame.rectFor(ratio: 1 / 2, page: page);
      // L'auteur au bord de la vidéo, sous l'encoche : à la hauteur du bouton.
      expect(
        FlowFrame.closeReserve(
          rect: plein,
          page: page,
          safeTop: 40,
          authorTop: 40,
        ),
        56,
      );
      // Une ligne de boutons l'a fait descendre à 40 + 56 : plus de réserve.
      expect(
        FlowFrame.closeReserve(
          rect: plein,
          page: page,
          safeTop: 40,
          authorTop: 96,
        ),
        0,
      );
      // Une vidéo carrée commence à 200 : bien sous le bouton (40 + 56).
      final carre = FlowFrame.rectFor(ratio: 1, page: page);
      expect(
        FlowFrame.closeReserve(
          rect: carre,
          page: page,
          safeTop: 40,
          authorTop: carre.top,
        ),
        0,
      );
      // Une vidéo étroite, en hauteur : le bouton n'empiète que de 56 - 100.
      final etroite = FlowFrame.rectFor(ratio: 1 / 4, page: page);
      expect(
        FlowFrame.closeReserve(
          rect: etroite,
          page: page,
          safeTop: 40,
          authorTop: 40,
        ),
        0,
      );
    });

    test('sous une ligne de boutons, l\'auteur descend d\'autant', () {
      final plein = FlowFrame.rectFor(ratio: 1 / 2, page: page);
      expect(FlowFrame.topInset(rect: plein, safeTop: 40 + 56), 96);
      // Une vidéo carrée (dès 200) reste sous la ligne : rien à rendre.
      final carre = FlowFrame.rectFor(ratio: 1, page: page);
      expect(FlowFrame.topInset(rect: carre, safeTop: 40 + 56), 0);
    });
  });

  group('Le cœur au milieu de l\'écran', () {
    test('sans bandeau, la page est l\'écran : son milieu', () {
      expect(FlowFrame.heartCenter(page: page, screenHeight: 800), 400);
    });

    test('sous un bandeau de 80, la page est plus courte : plus haut', () {
      // Page de 720 au bas d'un écran de 800 : le milieu de l'écran (400)
      // est à 320 du haut de la page.
      expect(
        FlowFrame.heartCenter(page: const Size(400, 720), screenHeight: 800),
        320,
      );
    });
  });

  testWidgets('un bouton d\'action pleine taille fait 48 — mesuré', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ActionIconButton(
              icon: const Icon(Icons.favorite_border),
              color: Colors.white,
              tooltip: 'Aimer',
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(ActionIconButton));
    expect(size.height, ActionMetrics.extent(false));
    expect(size.width, ActionMetrics.extent(false));
  });
}
