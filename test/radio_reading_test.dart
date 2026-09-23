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

  group('lirePuissance', () {
    test("sans annonce NeoVibe d'en face, aucune conclusion", () {
      expect(lirePuissance(const {'txAnnonces': 0}), isNull);
      expect(lirePuissance(const {}), isNull);
    });

    test('seule la boîte répond : le défaut est confirmé', () {
      final l = lirePuissance(const {
        'txAnnonces': 40,
        'txEnTetePresent': 0,
        'txBoitePresent': 40,
        'txBoiteDernier': -7,
      })!;
      expect(l, contains('CONFIRMÉ'));
      expect(l, contains('-7'));
    });

    test("l'en-tête répond : la distance est calibrée", () {
      final l = lirePuissance(const {
        'txAnnonces': 40,
        'txEnTetePresent': 40,
        'txBoitePresent': 40,
      })!;
      expect(l, contains('calibrée'));
    });

    test('aucun chemin ne répond', () {
      final l = lirePuissance(const {
        'txAnnonces': 5,
        'txEnTetePresent': 0,
        'txBoitePresent': 0,
      })!;
      expect(l, contains('AUCUN'));
    });
  });
}
