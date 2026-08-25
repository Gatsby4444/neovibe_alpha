import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/derived_list.dart';

/// **Ce que ces tests protègent : les deux primitives de la dissociation.**
///
/// `DerivedList` et `ValueList` sont ce qui empêche un recalcul de traverser
/// jusqu'à l'écran quand le résultat n'a pas changé. Tout ce qui a été corrigé
/// au checkup `RAPPELS.md` #52 repose dessus.
///
/// ⚠️ **Leur défaillance est silencieuse.** Si l'égalité d'un élément se perd —
/// un modèle qui gagne un champ sans l'ajouter à son `==`, un type sans `==` du
/// tout — la comparaison retombe sur l'identité, tout continue de s'afficher
/// correctement, et le coût revient sans que rien ne le signale. D'où ces tests.

/// Un élément avec une égalité de valeur, comme les modèles de `core/models/`.
class _Item {
  const _Item(this.id, this.libelle);
  final int id;
  final String libelle;

  @override
  bool operator ==(Object other) =>
      other is _Item && other.id == id && other.libelle == libelle;

  @override
  int get hashCode => Object.hash(id, libelle);
}

/// Un élément SANS égalité de valeur — le piège que ces primitives ne peuvent
/// pas rattraper toutes seules.
class _Opaque {
  const _Opaque(this.id);
  final int id;
}

class _Source extends Notifier<List<_Item>> {
  @override
  List<_Item> build() => const [];
  void publier(List<_Item> items) => state = items;
}

final _sourceProvider = NotifierProvider<_Source, List<_Item>>(_Source.new);

class _Vue extends Notifier<List<_Item>> with DerivedList<_Item> {
  @override
  List<_Item> build() =>
      ref.watch(_sourceProvider).where((i) => i.id.isEven).toList();
}

final _vueProvider = NotifierProvider<_Vue, List<_Item>>(_Vue.new);

/// Laisse Riverpod propager. Voir `dissociation_connections_test.dart` : trois
/// fois pendant ce chantier, un compteur a zero a semble prouver l'absence de
/// defaut alors qu'il ne prouvait que l'absence de propagation.
Future<void> _propage() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group(
    'DerivedList — un recalcul ne traverse que s\'il change quelque chose',
    () {
      test(
        'une source qui change SANS toucher au résultat ne notifie pas',
        () async {
          final c = ProviderContainer();
          addTearDown(c.dispose);

          c.read(_sourceProvider.notifier).publier([
            const _Item(2, 'a'),
            const _Item(3, 'impair'),
          ]);
          expect(c.read(_vueProvider), hasLength(1));

          var reveils = 0;
          c.listen(_vueProvider, (_, _) => reveils++);

          // Seul l'élément IMPAIR change : la vue ne le contient pas.
          c.read(_sourceProvider.notifier).publier([
            const _Item(2, 'a'),
            const _Item(3, 'impair modifié'),
          ]);
          await _propage();
          // ⚠️ Preuve que la source a bien traversé : sans elle, un compteur a
          // zero ne prouverait que le silence de l'instrument.
          expect(c.read(_sourceProvider), hasLength(2));
          expect(c.read(_sourceProvider)[1].libelle, 'impair modifié');

          expect(
            reveils,
            0,
            reason:
                'La vue est identique champ pour champ. Sans DerivedList, une '
                'nouvelle List suffirait à réveiller tous les abonnés.',
          );
        },
      );

      test('un changement RÉEL du résultat notifie une fois', () async {
        final c = ProviderContainer();
        addTearDown(c.dispose);

        c.read(_sourceProvider.notifier).publier([const _Item(2, 'a')]);
        expect(c.read(_vueProvider), hasLength(1));

        var reveils = 0;
        c.listen(_vueProvider, (_, _) => reveils++);

        c.read(_sourceProvider.notifier).publier([const _Item(2, 'b')]);
        await _propage();
        expect(c.read(_vueProvider).single.libelle, 'b');

        expect(reveils, 1);
      });
    },
  );

  group('ValueList — l\'égalité est celle du contenu', () {
    test('deux listes au contenu identique sont égales', () {
      expect(
        const ValueList([_Item(1, 'x')]),
        const ValueList([_Item(1, 'x')]),
      );
    });

    test('un contenu différent n\'est pas égal', () {
      expect(
        const ValueList([_Item(1, 'x')]),
        isNot(const ValueList([_Item(1, 'y')])),
      );
    });

    test('l\'ordre compte : ce n\'est pas un ensemble', () {
      expect(
        const ValueList([_Item(1, 'x'), _Item(2, 'y')]),
        isNot(const ValueList([_Item(2, 'y'), _Item(1, 'x')])),
      );
    });

    test('elle se lit comme une liste : length et []', () {
      const v = ValueList([_Item(1, 'x'), _Item(2, 'y')]);
      expect(v.length, 2);
      expect(v[1], const _Item(2, 'y'));
      expect(v.isEmpty, isFalse);
      expect(const ValueList<_Item>.empty().isEmpty, isTrue);
    });

    test('SANS égalité de valeur sur l\'élément, la garde est inopérante — '
        'et c\'est le seul piège de ces primitives', () {
      // ⚠️ Sans `const` : deux `const _Opaque(1)` seraient canonicalises par
      // Dart en UNE SEULE instance, donc identiques — le test aurait mesure une
      // optimisation du compilateur, pas l'egalite du type.
      expect(
        ValueList([_Opaque(1)]),
        isNot(ValueList([_Opaque(1)])),
        reason:
            'Deux _Opaque décrivant la même chose ne sont pas égaux, donc la '
            'comparaison retombe sur l\'identité. Un modèle placé dans une '
            'liste dérivée DOIT porter son ==, sinon toute la dissociation '
            'redevient silencieusement inopérante.',
      );
    });
  });
}
