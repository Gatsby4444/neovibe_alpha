import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/theme.dart';

/// ⚠️ **Un `FilledButton` réclame TOUTE la largeur disponible.**
///
/// Le thème pose `minimumSize: Size.fromHeight(52)`. Or `Size.fromHeight` vaut
/// `Size(double.infinity, 52)` — une **largeur minimale infinie**, pas
/// « seulement une hauteur ». Le nom du constructeur dit le contraire de ce
/// qu'il fait, et c'est ce qui a permis au défaut de vivre.
///
/// C'est **voulu** : sous un parent à largeur bornée, l'infini est raboté et le
/// bouton remplit la ligne — le rendu qu'on veut pour les ~40 gros boutons de
/// l'app. Une `Row`, elle, ne borne rien pour ses enfants non-flexibles : le
/// bouton part alors **hors de l'écran**, et **en release aucune assertion ne
/// le signale**.
///
/// Constaté le 2026-08-17 sur la carte « Charles veut se connecter avec toi » :
/// deux boutons dans le code, **un seul à l'écran**, et celui qui manquait était
/// « Accepter » — la demande d'ami était donc impossible à accepter.
///
/// Ces deux tests gardent le **contrat**, dans les deux sens : le motif protégé
/// doit passer, le motif nu doit rester détectable. Si un jour quelqu'un retire
/// la largeur infinie du thème, le second test le dira — et il faudra alors
/// repasser sur les boutons qui comptaient dessus pour être pleine largeur.
void main() {
  Future<void> pomper(WidgetTester tester, Widget ligne) => tester.pumpWidget(
    MaterialApp(
      theme: NeoTheme.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: Card(
              child: Padding(padding: const EdgeInsets.all(12), child: ligne),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('protégé par Expanded : les deux boutons tiennent', (
    tester,
  ) async {
    await pomper(
      tester,
      Row(
        children: [
          Expanded(
            child: TextButton(onPressed: () {}, child: const Text('Refuser')),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: () {},
              child: const Text('Accepter'),
            ),
          ),
        ],
      ),
    );

    expect(tester.takeException(), isNull);

    // Et surtout : les deux sont VISIBLES. `findsOneWidget` ne l'aurait pas dit
    // — un widget peint hors de l'écran est présent dans l'arbre. C'est
    // exactement pourquoi aucun test existant n'avait vu le défaut.
    final ecran = tester.getSize(find.byType(MaterialApp)).width;
    for (final libelle in ['Refuser', 'Accepter']) {
      final boite = tester.getRect(find.text(libelle));
      expect(
        boite.left,
        greaterThanOrEqualTo(0),
        reason: '$libelle déborde à gauche',
      );
      expect(
        boite.right,
        lessThanOrEqualTo(ecran),
        reason: '$libelle déborde à droite',
      );
    }
  });

  test('le thème impose bien une largeur minimale INFINIE', () {
    // ⚠️ **Le contrat, énoncé une fois.** C'est cette valeur qui rend pleine
    // largeur les ~40 gros boutons de l'app sans que personne ne l'écrive — et
    // c'est elle qui, dans une `Row` non bornée, envoie le bouton hors de
    // l'écran sans un mot en release.
    //
    // Le vérifier ici plutôt qu'en pompant le mauvais motif : une erreur de
    // mise en page produit des dizaines d'exceptions par image, que le
    // framework compte et qui rendent un test « j'attends l'erreur »
    // ininterprétable.
    final taille = NeoTheme.dark().filledButtonTheme.style?.minimumSize
        ?.resolve({});

    expect(
      taille?.width,
      double.infinity,
      reason:
          'le thème n\'impose plus de largeur infinie. Ce n\'est pas forcément '
          'une régression — mais il faut alors repasser sur les boutons qui '
          'comptaient dessus pour remplir leur ligne. Voir le commentaire de '
          '`_filledStyle()` dans lib/core/theme.dart.',
    );
    expect(taille?.height, 52);
  });
}
