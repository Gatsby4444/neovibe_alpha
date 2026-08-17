import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/theme.dart';

/// ⚠️ **Un `FilledButton` réclame TOUTE la largeur disponible.**
///
/// `_filledStyle()` pose `minimumSize: Size.fromHeight(52)`. Or `Size.fromHeight`
/// vaut `Size(double.infinity, 52)` — c'est une **largeur minimale infinie**, pas
/// « seulement une hauteur ». Le nom du constructeur suggère le contraire, et
/// c'est ce qui a permis au défaut de vivre.
///
/// Conséquence : posé dans une `Row` à côté d'un autre bouton, il exige plus de
/// place qu'il n'en existe. La `Row` déborde, et **en build de release le
/// débordement est silencieux** — aucune bande jaune, aucune erreur, juste un
/// bouton qui n'est plus là.
///
/// C'est ce que Jay a constaté le 2026-08-17 sur la carte « Charles veut se
/// connecter avec toi » : deux boutons dans le code, **un seul à l'écran**, et
/// celui qui manquait était « Accepter » — donc la demande d'ami était
/// impossible à accepter.
///
/// Ce test vaut pour l'app entière, pas pour cette carte : il échoue partout où
/// un `FilledButton` partage une `Row`.
void main() {
  Future<void> pomper(WidgetTester tester, Widget enfant) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NeoTheme.dark(),
        home: Scaffold(
          body: Center(child: SizedBox(width: 360, child: enfant)),
        ),
      ),
    );
  }

  testWidgets('deux boutons dans une Row tiennent tous les deux à l\'écran', (
    tester,
  ) async {
    await pomper(
      tester,
      const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [_Refuser(), SizedBox(width: 8), _Accepter()],
          ),
        ),
      ),
    );

    // ⚠️ **Les deux sont dans l'arbre, et ce n'est pas la question.**
    // `findsOneWidget` passe même quand le bouton est peint hors de l'écran :
    // c'est précisément pourquoi aucun test existant n'a vu ce défaut.
    expect(find.text('Refuser'), findsOneWidget);
    expect(find.text('Accepter'), findsOneWidget);

    // La vraie question est la mise en page. Le bouton impose
    // `BoxConstraints(w=Infinity)` à son parent : en test l'assertion de
    // Flutter lève, **en release elle est compilée hors du binaire** et la mise
    // en page se poursuit avec une largeur infinie. Le bouton part alors à
    // droite de l'écran, sans un mot.
    expect(
      tester.takeException(),
      isNull,
      reason:
          'le FilledButton force une largeur INFINIE dans la Row '
          '(minimumSize: Size.fromHeight(52) == Size(infinity, 52)). '
          'En release, rien ne le signale et « Accepter » sort de l\'écran.',
    );
  });
}

class _Refuser extends StatelessWidget {
  const _Refuser();
  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: () {}, child: const Text('Refuser'));
}

class _Accepter extends StatelessWidget {
  const _Accepter();
  @override
  Widget build(BuildContext context) =>
      FilledButton(onPressed: () {}, child: const Text('Accepter'));
}
