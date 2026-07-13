/// Estimation grossière de la distance d'un pair BLE.
/// Jamais de distance précise (spec 4.2) — deux niveaux seulement.
enum ProximityLevel {
  veryClose, // signal fort
  close; // signal détecté

  String get label => this == veryClose ? 'Très proche' : 'Proche';
}
