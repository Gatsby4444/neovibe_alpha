enum LibraryVisibility {
  connections,
  restricted;

  static LibraryVisibility fromDb(String value) =>
      LibraryVisibility.values.byName(value);
}

class Profile {
  const Profile({
    required this.id,
    required this.displayName,
    this.tagName,
    this.bio,
    this.avatarUrl,
    this.libraryVisibility = LibraryVisibility.connections,
    this.realtimeWaves = false,
    this.bleToken,
  });

  final String id;

  /// Username UNIQUE par utilisateur (consigne Jay 2026-07-12).
  final String displayName;

  /// Tag name optionnel et libre — c'est LUI qui s'affiche en conversation ;
  /// vide → le username prend le relais.
  final String? tagName;
  final String? bio;
  final String? avatarUrl;
  final LibraryVisibility libraryVisibility;
  final bool realtimeWaves;

  /// Identifiant diffusé en BLE — présent uniquement sur son propre profil.
  final String? bleToken;

  /// Nom affiché dans les conversations : tag name, sinon username.
  String get chatName =>
      (tagName != null && tagName!.isNotEmpty) ? tagName! : displayName;

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    displayName: json['display_name'] as String,
    tagName: json['tag_name'] as String?,
    bio: json['bio'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    libraryVisibility: LibraryVisibility.fromDb(
      json['library_visibility'] as String? ?? 'connections',
    ),
    realtimeWaves: json['realtime_waves'] as bool? ?? false,
    bleToken: json['ble_token'] as String?,
  );
}
