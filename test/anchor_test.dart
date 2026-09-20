import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/location/anchor.dart';

/// **L'ancre gommée** : l'app et le serveur (`private.gomme_ancre`) doivent
/// donner LA MÊME case pour le même point — sinon l'un dirait plus précis
/// que l'autre. Les valeurs attendues sont celles relevées en base le
/// 2026-09-20 pour (48.85661, 2.35222).
void main() {
  test('gomme à 100 m, comme le serveur', () {
    final a = ContentAnchor.gomme(48.85661, 2.35222);
    expect(a.lat, closeTo(48.8564498742364, 1e-9));
    expect(a.lng, closeTo(2.3524511733862, 1e-9));
  });

  test('deux points de la même case tombent au même endroit', () {
    final a = ContentAnchor.gomme(48.85661, 2.35222);
    final b = ContentAnchor.gomme(48.85665, 2.35230);
    expect(a, b);
  });

  test('le point exact n\'est pas conservé', () {
    final a = ContentAnchor.gomme(48.856612345, 2.352223456);
    expect(a.lat, isNot(48.856612345));
    expect(a.lng, isNot(2.352223456));
  });
}
