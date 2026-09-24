import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/palette.dart';
import 'package:neovibe/core/theme.dart';

void main() {
  test('Vice6 : les couleurs exactes de Sombre, et un fond vivant', () {
    expect(NeoIdentity.vice6.palette(Brightness.light), NeoPalettes.sombre);
    expect(NeoIdentity.vice6.palette(Brightness.dark), NeoPalettes.sombre);
    expect(NeoIdentity.fromKey('vice6'), NeoIdentity.vice6);
    expect(NeoIdentity.vice6.fondVivant, isTrue);
    expect(NeoIdentity.vice6.lueurs, isTrue);

    final theme = NeoTheme.of(NeoIdentity.vice6, Brightness.dark);
    // Le Scaffold laisse voir les lumières posées derrière l'app.
    expect(theme.scaffoldBackgroundColor, Colors.transparent);
    // Les cartes rayonnent de la couleur d'action.
    expect(theme.cardTheme.elevation, greaterThan(0));
    expect(theme.cardTheme.shadowColor?.a, greaterThan(0));
  });

  test('les autres identités ne rayonnent pas', () {
    for (final id in NeoIdentity.values.where((i) => i != NeoIdentity.vice6)) {
      expect(id.lueurs, isFalse, reason: id.name);
      expect(id.lumieresDerivantes, isFalse, reason: id.name);
      final theme = NeoTheme.of(id, Brightness.dark);
      expect(theme.cardTheme.elevation, 0, reason: id.name);
    }
  });

  testWidgets('sous Vice6, un bouton plein est une pilule qui rayonne', (
    tester,
  ) async {
    Future<BoxDecoration> decorationUnder(NeoIdentity id) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NeoTheme.of(id, Brightness.dark),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: FilledButton(onPressed: () {}, child: const Text('Go')),
              ),
            ),
          ),
        ),
      );
      // Changer de thème s'anime (AnimatedTheme) : on attend la fin.
      await tester.pumpAndSettle();
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(FilledButton),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return box.decoration as BoxDecoration;
    }

    final vice = await decorationUnder(NeoIdentity.vice6);
    expect(vice.boxShadow, isNotEmpty);
    expect(vice.borderRadius, BorderRadius.circular(999));

    final sombre = await decorationUnder(NeoIdentity.sombre);
    expect(sombre.boxShadow, isNull);
  });
}
