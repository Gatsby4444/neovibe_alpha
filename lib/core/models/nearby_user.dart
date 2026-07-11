/// Utilisateur NeoVibe détecté à proximité BLE.
/// Jamais de distance précise : uniquement une estimation grossière (spec 4.2).
enum ProximityLevel {
  veryClose, // signal fort
  close; // signal détecté

  String get label => this == veryClose ? 'Très proche' : 'Proche';
}

class NearbyUser {
  const NearbyUser({
    required this.userId,
    required this.displayName,
    this.avatarUrl,
    required this.isConnected,
    required this.proximity,
    required this.lastSeen,
  });

  final String userId;
  final String displayName;
  final String? avatarUrl;

  /// Déjà connecté (ami croisé à nouveau) vs jamais connecté (candidat au Ping).
  final bool isConnected;
  final ProximityLevel proximity;
  final DateTime lastSeen;

  NearbyUser copyWith({ProximityLevel? proximity, DateTime? lastSeen}) =>
      NearbyUser(
        userId: userId,
        displayName: displayName,
        avatarUrl: avatarUrl,
        isConnected: isConnected,
        proximity: proximity ?? this.proximity,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}
