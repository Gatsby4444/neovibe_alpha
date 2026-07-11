import 'package:flutter_test/flutter_test.dart';

import 'package:neovibe/core/models/card.dart';

void main() {
  test('les types de Cards ont chacun un tag et une couleur distincts', () {
    final tags = CardType.values.map((t) => t.tag).toSet();
    final colors = CardType.values.map((t) => t.color).toSet();
    expect(tags.length, CardType.values.length);
    expect(colors.length, CardType.values.length);
  });

  test('mapping DB aller-retour des types de Cards', () {
    for (final type in CardType.values) {
      expect(CardType.fromDb(type.dbValue), type);
    }
  });
}
