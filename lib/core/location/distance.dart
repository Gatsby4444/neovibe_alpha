import 'dart:math' as math;

/// **La distance entre deux points, en mètres** (formule de haversine) — la
/// même que celle du serveur (`private.meters_between`), écrite une fois
/// côté app.
///
/// Sert à l'AFFICHAGE (la distance qui bouge quand on marche, le point qui
/// glisse). Ce qui DÉCIDE — entrer dans une soirée, en sortir — reste au
/// serveur, qui refait son propre calcul.
double metersBetween(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.sqrt(a));
}
