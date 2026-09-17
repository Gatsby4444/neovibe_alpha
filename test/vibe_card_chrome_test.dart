import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/core/widgets/vibe_face.dart';
import 'package:neovibe/features/cards/flippable_card.dart';
import 'package:neovibe/features/cards/held_pan.dart';
import 'package:neovibe/features/library/feed/vibe_card_chrome.dart';

/// Une fausse face : le format d'une Vibe, sans réseau ni clé.
Widget _face({Widget? overlay}) => VibeFaceFrame(
  key: const ValueKey('cadre'),
  type: CardType.standard,
  overlay: overlay,
  child: const AspectRatio(
    aspectRatio: kVibeFaceRatio,
    child: ColoredBox(color: Colors.blue),
  ),
);

Widget _chrome() => VibeCardChrome(
  header: const SizedBox(key: ValueKey('identite'), height: 34),
  actions: const SizedBox(key: ValueKey('actions'), width: 48, height: 170),
  caption: const SizedBox(key: ValueKey('legende'), height: 34),
);

Future<void> _poser(WidgetTester tester, Widget carte) async {
  tester.view.physicalSize = const Size(411, 731);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: Center(child: carte)),
      ),
    ),
  );
}

void main() {
  testWidgets('le calque ne prend AUCUNE place : la carte reste centrée', (
    tester,
  ) async {
    await _poser(tester, _face());
    final sans = tester.getRect(find.byKey(const ValueKey('cadre')));

    await _poser(tester, _face(overlay: _chrome()));
    final avec = tester.getRect(find.byKey(const ValueKey('cadre')));

    // Le défaut de la v0.9.191 : la place réservée aux boutons poussait la
    // carte sur le côté. Dedans, ils ne coûtent rien.
    expect(avec, sans);
    expect(avec.center.dx, moreOrLessEquals(411 / 2, epsilon: 0.5));
  });

  testWidgets('identité, actions et légende sont DANS la carte', (
    tester,
  ) async {
    await _poser(tester, _face(overlay: _chrome()));

    final cadre = tester.getRect(find.byKey(const ValueKey('cadre')));
    for (final quoi in ['identite', 'actions', 'legende']) {
      final boite = tester.getRect(find.byKey(ValueKey(quoi)));
      expect(cadre.contains(boite.topLeft), isTrue, reason: '$quoi déborde');
      expect(
        cadre.contains(boite.bottomRight - const Offset(0.01, 0.01)),
        isTrue,
        reason: '$quoi déborde',
      );
    }
  });

  testWidgets('la bande de la barre de lecture reste libre', (tester) async {
    await _poser(tester, _face(overlay: _chrome()));

    final cadre = tester.getRect(find.byKey(const ValueKey('cadre')));
    final plancher = cadre.bottom - VibeCardChrome.barreDeLecture;
    for (final quoi in ['actions', 'legende']) {
      final boite = tester.getRect(find.byKey(ValueKey(quoi)));
      expect(
        boite.bottom,
        lessThanOrEqualTo(plancher),
        reason: '$quoi couvre la barre de lecture d\'une vidéo',
      );
    }
  });

  testWidgets('les boutons bougent AVEC la carte quand le doigt l\'incline', (
    tester,
  ) async {
    await _poser(tester, TiltableCard(child: _face(overlay: _chrome())));
    final repos = tester.getRect(find.byKey(const ValueKey('actions')));

    // Un doigt, pas un saut : le geste ne démarre qu'après son seuil.
    final doigt = await tester.startGesture(
      tester.getCenter(find.byType(TiltableCard)),
    );
    // Le doigt s'attarde avant de glisser : c'est ce qui donne la carte
    // (voir [kTempsDePose]). Et chaque événement porte son heure — sans quoi
    // ils auraient tous lieu à l'instant zéro, et une règle fondée sur le
    // temps ne pourrait jamais devenir vraie.
    var t = kTempsDePose + const Duration(milliseconds: 20);
    await tester.pump(t);
    for (var i = 0; i < 30; i++) {
      t += const Duration(milliseconds: 16);
      await doigt.moveBy(const Offset(4, 0), timeStamp: t);
      await tester.pump(const Duration(milliseconds: 16));
    }
    final incline = tester.getRect(find.byKey(const ValueKey('actions')));
    await doigt.up();
    await tester.pumpAndSettle();

    expect(
      incline == repos,
      isFalse,
      reason:
          'les actions sont restées immobiles : elles ne sont pas dans la '
          'carte, elles flottent au-dessus',
    );
  });
}
