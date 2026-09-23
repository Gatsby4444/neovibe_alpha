import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/diagnostics/radio_reading.dart';

/// Ce que ces tests protègent : **la première phrase du diagnostic.**
///
/// Le 2026-09-23 elle affirmait « l'écoute marche » sur un téléphone sourd
/// depuis une heure, parce qu'elle lisait un cumul au lieu de l'état présent.
void main() {
  // Le relevé de 11:58 du 2026-09-23, tel quel pour ce qui compte ici.
  const releveDu23 = <String, Object?>{
    'rawScans': 22969,
    'neoScans': 0,
    'otherVersionScans': 0,
    'scanMode': 'aucun scan',
  };

  test(
    "un scan arrêté l'emporte sur un gros cumul (le relevé du 2026-09-23)",
    () {
      final l = lireEcoute(releveDu23)!;
      expect(l, contains("L'ÉCOUTE EST ARRÊTÉE"));
      expect(l, isNot(contains('fonctionne')));
      expect(l, isNot(contains("L'écoute tourne")));
    },
  );

  test('la panne dit depuis quand et combien de refus', () {
    final l = lireEcoute({
      ...releveDu23,
      'ecouteVoulue': true,
      'scanRefus': 3,
      'scanPanneDepuisMillis': 65 * 60 * 1000,
    })!;
    expect(l, contains('depuis 1 h 05'));
    expect(l, contains('3 fois'));
  });

  test("ping éteint : aucun scan n'est pas une panne", () {
    final l = lireEcoute({...releveDu23, 'ecouteVoulue': false})!;
    expect(l, contains('voulu'));
    expect(l, isNot(contains('ARRÊTÉE')));
  });

  test("l'écoute qui tourne sans NeoVibe autour", () {
    final l = lireEcoute({...releveDu23, 'scanMode': 'cyclique'})!;
    expect(l, contains("L'écoute tourne"));
  });

  test('zéro annonce, écoute en marche', () {
    final l = lireEcoute({
      'rawScans': 0,
      'neoScans': 0,
      'scanMode': 'continu',
    })!;
    expect(l, contains('ZÉRO'));
  });

  test('service absent : pas de lecture', () {
    expect(lireEcoute(const {}), isNull);
  });
}
