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
    this.storiesPublic = false,
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

  /// Stories publiques (consigne Jay 2026-08-02) : quand c'est actif, les
  /// personnes CROISÉES physiquement dans les dernières 24 h voient mes
  /// stories, en plus de mes amis. Faux par défaut — sans ce réglage, seuls
  /// mes amis les voient.
  final bool storiesPublic;

  // NB : plus de `ble_token` — depuis le chantier BLE (2026-07-13), la
  // découverte est 100 % locale et l'identifiant diffusé change toutes les
  // 15 min (rien à stocker côté serveur, donc rien à voler : le risque de
  // pistage disparaît par conception).

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
    storiesPublic: json['stories_public'] as bool? ?? false,
  );

  // ⚠️ **Égalité de VALEUR, posée le 2026-08-25 (checkup `RAPPELS.md` #52).**
  //
  // Sans elle, `listEquals` retombe sur l'identité et tout `DerivedList` est
  // inopérant — en silence. Deux objets décrivant la même ligne, relus depuis
  // le réseau, doivent être égaux : c'est ce qui permet à un flux qui réémet
  // la même chose de ne réveiller personne.
  @override
  bool operator ==(Object other) =>
      other is Profile &&
      other.id == id &&
      other.displayName == displayName &&
      other.tagName == tagName &&
      other.bio == bio &&
      other.avatarUrl == avatarUrl &&
      other.libraryVisibility == libraryVisibility &&
      other.realtimeWaves == realtimeWaves &&
      other.storiesPublic == storiesPublic;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    tagName,
    bio,
    avatarUrl,
    libraryVisibility,
    realtimeWaves,
    storiesPublic,
  );
}
