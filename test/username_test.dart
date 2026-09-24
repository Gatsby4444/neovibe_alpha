import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/username.dart';

void main() {
  group('la frappe convertie au format', () {
    test('comme la migration du 2026-09-24', () {
      expect(Username.normalize('Camille Martin'), 'camille.martin');
      expect(Username.normalize('Léa'), 'lea');
      expect(Username.normalize('Chloé  Petit'), 'chloe.petit');
      expect(Username.normalize('jay_B'), 'jay_b');
    });

    test('ce qui n\'est pas permis disparaît', () {
      expect(Username.normalize('jay!@#b'), 'jayb');
      expect(Username.normalize('a..b'), 'a.b');
    });
  });

  group('les règles', () {
    test('3 à 20 caractères', () {
      expect(Username.problem('ab'), isNotNull);
      expect(Username.problem('abc'), isNull);
      expect(Username.problem('a' * 20), isNull);
      expect(Username.problem('a' * 21), isNotNull);
    });

    test('le format de la base (profiles_display_name_check)', () {
      expect(Username.isValid('camille.martin'), isTrue);
      expect(Username.isValid('Camille'), isFalse, reason: 'majuscule');
      expect(Username.isValid('lé.a'), isFalse, reason: 'accent');
      expect(Username.isValid('a b c'), isFalse, reason: 'espace');
    });
  });

  test('le champ ne laisse pas dépasser 20 caractères', () {
    const f = UsernameInputFormatter();
    final out = f.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: 'Un Username Beaucoup Trop Long'),
    );
    expect(out.text.length, Username.maxLength);
    expect(Username.isValid(out.text), isTrue);
  });
}
