import 'package:flutter/foundation.dart';

/// **Les objets du mode événement** — décisions de Jay du 2026-09-12
/// (`docs/vision-produit.md` §8.4, `docs/evenements.md`).
///
/// Quatre objets, quatre durées de vie, jamais le même rangement :
///
/// | Objet | Ce que c'est | Vit |
/// |---|---|---|
/// | [NeoEvent] | l'événement — ce qui est COMMUN aux deux origines | jusqu'à la purge, 5 jours après la fermeture |
/// | [EventPerson] | quelqu'un de l'événement : invité et/ou présent | le temps de l'événement |
/// | [HotSpot] | une case de la carte de chaleur — une VUE DÉRIVÉE | l'instant |
/// | [NearbyEvent] | une soirée d'établissement autour de moi | tant qu'elle est ouverte |
///
/// ⚠️ **Tous portent leur `==`.** Les vues dérivées (`DerivedList`,
/// `select`) ne réveillent leurs lecteurs que si la valeur change — et pour
/// ça il faut qu'une valeur puisse se comparer. Un modèle sans `==` rend ces
/// outils inopérants **en silence** (règle de `CLAUDE.md`).

/// D'où vient un événement — et donc **qui a le droit d'y entrer**.
///
/// Les règles d'entrée ne partagent rien (règle 2 de `CLAUDE.md`) :
/// - **privé** : être invité au groupe d'événement **et** sur place — un
///   **moment** (`NeoEvent.autoCreated`) est un privé ouvert par le serveur
///   quand des amis sont ensemble ;
/// - **établissement** : être sur place ;
/// - **ouvert** (2026-09-21) : être sur place — la règle d'un établissement,
///   ouvert par un utilisateur, visible de qui passe à portée. On découvre
///   une SOIRÉE, jamais une personne.
enum EventKind {
  private,
  venue,
  open;

  static EventKind fromDb(String value) => switch (value) {
    'venue' => EventKind.venue,
    'open' => EventKind.open,
    _ => EventKind.private,
  };

  /// On y entre en étant sur place, sans invitation.
  bool get joinOnPlace => this != EventKind.private;
}

/// Le rôle dans un groupe d'événement privé. **Tous admin par défaut**
/// (Jay, 2026-09-12 : « comme sur WhatsApp ») ; le créateur peut rétrograder.
enum EventRole {
  admin,
  member;

  static EventRole? fromDb(String? value) => switch (value) {
    'admin' => EventRole.admin,
    'member' => EventRole.member,
    _ => null,
  };
}

/// Ce que le serveur sait de la personne, vis-à-vis de MOI. C'est le
/// **libellé du lien** que `RAPPELS.md` #99 exigeait avant tout mode
/// événement : un inconnu de soirée n'est jamais présenté comme un ami.
enum PersonRelation {
  me,
  friend,

  /// Présent·e dans le même événement, ou invité·e au même événement privé.
  event,

  /// Aucun lien — ne devrait pas arriver dans une liste d'événement, mais le
  /// serveur reste seul juge.
  none;

  static PersonRelation fromDb(String? value) => switch (value) {
    'me' => PersonRelation.me,
    'friend' => PersonRelation.friend,
    'event' => PersonRelation.event,
    _ => PersonRelation.none,
  };
}

/// **La taille d'une soirée** (Jay, 2026-09-25) : son rayon d'ENTRÉE. On en
/// sort à deux fois ce rayon (`event_rules.exit_factor`). Les nombres sont
/// ceux du serveur (`event_rules.size_*_m`), qui refuse toute autre valeur.
enum EventSize {
  bar(50, 'Bar / appartement', 'On entre à 50 m'),
  grand(120, 'Grand lieu', 'Club, salle — 120 m'),
  pleinAir(300, 'Plein air / festival', 'Parc, festival — 300 m');

  const EventSize(this.radiusM, this.label, this.detail);
  final int radiusM;
  final String label;
  final String detail;

  /// La marge de précision à l'entrée (`event_rules.entry_margin_max_m`).
  static const entryMarginM = 30;

  /// Le nom attendu par `set_event_size`.
  String get dbValue => switch (this) {
    EventSize.bar => 'bar',
    EventSize.grand => 'grand',
    EventSize.pleinAir => 'plein_air',
  };

  /// La taille d'un rayon ; nul si ce n'en est pas une (soirée d'avant).
  static EventSize? fromRadius(int? radiusM) {
    for (final s in values) {
      if (s.radiusM == radiusM) return s;
    }
    return null;
  }
}

/// L'événement, tel que `my_events()` le rend.
@immutable
class NeoEvent {
  const NeoEvent({
    required this.id,
    required this.kind,
    this.autoCreated = false,
    required this.title,
    this.venueName,
    required this.createdBy,
    required this.conversationId,
    this.lat,
    this.lon,
    this.radiusM,
    required this.startsAt,
    this.scheduledEndAt,
    this.openedAt,
    this.closedAt,
    required this.membersCanAdd,
    required this.membersCanRemove,
    this.libraryRevealAt,
    required this.presentCount,
    required this.guestCount,
    required this.iAmPresent,
    this.myRole,
    required this.iManage,
    this.description,
    this.posterPath,
    this.friendsPresent = const [],
  });

  final String id;
  final EventKind kind;

  /// **Un moment** : ouvert par le serveur parce que des amis étaient
  /// ensemble (Jay, 2026-09-21 : « peut-être essentiel »). Privé, sans lieu ;
  /// sa preuve de présence est la vue mutuelle par le ping.
  final bool autoCreated;
  final String title;

  /// Le nom du lieu — établissement seulement.
  final String? venueName;
  final String createdBy;

  /// Le groupe d'événement : une conversation de type `event`.
  final String conversationId;

  /// Le lieu déclaré, s'il y en a un. Un voyage n'en a pas.
  final double? lat;
  final double? lon;
  final int? radiusM;
  final DateTime startsAt;
  final DateTime? scheduledEndAt;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final bool membersCanAdd;
  final bool membersCanRemove;

  /// Nul tant que l'événement est ouvert : la bibliothèque est **retardée**.
  final DateTime? libraryRevealAt;
  final int presentCount;
  final int guestCount;
  final bool iAmPresent;

  /// Mon rôle dans le groupe d'événement — privé seulement.
  final EventRole? myRole;

  /// Je gère l'établissement de cette soirée.
  final bool iManage;

  /// Le « profil » de la soirée, posé par l'organisateur (2026-09-25) : une
  /// description courte et une affiche 3:4 (chemin dans `event_posters`).
  final String? description;
  final String? posterPath;

  /// MES amis présents en ce moment — jamais un inconnu (le serveur les
  /// choisit, `private.friends_present`).
  final List<String> friendsPresent;

  bool get isClosed => closedAt != null;
  bool get isOpen => closedAt == null;
  bool get hasPlace => lat != null && lon != null;

  /// Pas encore commencé : on ne peut pas encore le rejoindre.
  bool notStartedAt(DateTime now) => startsAt.isAfter(now);

  /// Ce que je peux régler : créateur d'un privé ou d'un ouvert, gérant
  /// d'un établissement.
  bool canSettings(String me) =>
      isOpen && ((kind != EventKind.venue && createdBy == me) || iManage);

  /// Fermer à la main : le créateur (privé) ou le gérant (établissement).
  bool canClose(String me) => canSettings(me);

  /// Inviter : le créateur toujours ; un admin si le créateur l'a laissé.
  bool canInvite(String me) =>
      isOpen &&
      kind == EventKind.private &&
      (createdBy == me || (myRole == EventRole.admin && membersCanAdd));

  bool canRemove(String me) =>
      isOpen &&
      kind == EventKind.private &&
      (createdBy == me || (myRole == EventRole.admin && membersCanRemove));

  factory NeoEvent.fromJson(Map<String, dynamic> json) => NeoEvent(
    id: json['id'] as String,
    kind: EventKind.fromDb(json['kind'] as String),
    autoCreated: json['auto_created'] as bool? ?? false,
    title: json['title'] as String,
    venueName: json['venue_name'] as String?,
    createdBy: json['created_by'] as String,
    conversationId: json['conversation_id'] as String,
    lat: (json['lat'] as num?)?.toDouble(),
    lon: (json['lon'] as num?)?.toDouble(),
    radiusM: (json['radius_m'] as num?)?.toInt(),
    startsAt: DateTime.parse(json['starts_at'] as String),
    scheduledEndAt: _date(json['scheduled_end_at']),
    openedAt: _date(json['opened_at']),
    closedAt: _date(json['closed_at']),
    membersCanAdd: json['members_can_add'] as bool? ?? true,
    membersCanRemove: json['members_can_remove'] as bool? ?? true,
    libraryRevealAt: _date(json['library_reveal_at']),
    presentCount: (json['present_count'] as num?)?.toInt() ?? 0,
    guestCount: (json['guest_count'] as num?)?.toInt() ?? 0,
    iAmPresent: json['i_am_present'] as bool? ?? false,
    myRole: EventRole.fromDb(json['my_role'] as String?),
    iManage: json['i_manage'] as bool? ?? false,
    description: json['description'] as String?,
    posterPath: json['poster_path'] as String?,
    friendsPresent: _ids(json['friends_present']),
  );

  static List<String> _ids(Object? v) =>
      v == null ? const [] : [for (final x in v as List) x as String];

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.parse(v as String);

  @override
  bool operator ==(Object other) =>
      other is NeoEvent &&
      other.id == id &&
      other.kind == kind &&
      other.autoCreated == autoCreated &&
      other.title == title &&
      other.venueName == venueName &&
      other.createdBy == createdBy &&
      other.conversationId == conversationId &&
      other.lat == lat &&
      other.lon == lon &&
      other.radiusM == radiusM &&
      other.startsAt == startsAt &&
      other.scheduledEndAt == scheduledEndAt &&
      other.openedAt == openedAt &&
      other.closedAt == closedAt &&
      other.membersCanAdd == membersCanAdd &&
      other.membersCanRemove == membersCanRemove &&
      other.libraryRevealAt == libraryRevealAt &&
      other.presentCount == presentCount &&
      other.guestCount == guestCount &&
      other.iAmPresent == iAmPresent &&
      other.myRole == myRole &&
      other.iManage == iManage &&
      other.description == description &&
      other.posterPath == posterPath &&
      listEquals(other.friendsPresent, friendsPresent);

  @override
  int get hashCode => Object.hashAll([
    id,
    kind,
    title,
    venueName,
    createdBy,
    conversationId,
    lat,
    lon,
    radiusM,
    startsAt,
    scheduledEndAt,
    openedAt,
    closedAt,
    membersCanAdd,
    membersCanRemove,
    libraryRevealAt,
    presentCount,
    guestCount,
    iAmPresent,
    myRole,
    iManage,
    description,
    posterPath,
    Object.hashAll(friendsPresent),
  ]);
}

/// Quelqu'un de l'événement — invité (privé) et/ou présent.
@immutable
class EventPerson {
  const EventPerson({
    required this.userId,
    required this.displayName,
    this.tagName,
    this.avatarUrl,
    this.role,
    required this.invited,
    required this.present,
    required this.relation,
  });

  final String userId;
  final String displayName;
  final String? tagName;
  final String? avatarUrl;
  final EventRole? role;
  final bool invited;
  final bool present;
  final PersonRelation relation;

  String get chatName =>
      (tagName != null && tagName!.isNotEmpty) ? tagName! : displayName;

  factory EventPerson.fromJson(Map<String, dynamic> json) => EventPerson(
    userId: json['user_id'] as String,
    displayName: json['display_name'] as String? ?? 'Quelqu\'un',
    tagName: json['tag_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    role: EventRole.fromDb(json['role'] as String?),
    invited: json['invited'] as bool? ?? false,
    present: json['present'] as bool? ?? false,
    relation: PersonRelation.fromDb(json['relation'] as String?),
  );

  @override
  bool operator ==(Object other) =>
      other is EventPerson &&
      other.userId == userId &&
      other.displayName == displayName &&
      other.tagName == tagName &&
      other.avatarUrl == avatarUrl &&
      other.role == role &&
      other.invited == invited &&
      other.present == present &&
      other.relation == relation;

  @override
  int get hashCode => Object.hash(
    userId,
    displayName,
    tagName,
    avatarUrl,
    role,
    invited,
    present,
    relation,
  );
}

/// Une case de la carte de chaleur. `headcount` vaut 0 pour le lieu déclaré.
@immutable
class HotSpot {
  const HotSpot({
    required this.lat,
    required this.lon,
    required this.headcount,
  });

  final double lat;
  final double lon;
  final int headcount;

  factory HotSpot.fromJson(Map<String, dynamic> json) => HotSpot(
    lat: (json['lat'] as num).toDouble(),
    lon: (json['lon'] as num).toDouble(),
    headcount: (json['headcount'] as num?)?.toInt() ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is HotSpot &&
      other.lat == lat &&
      other.lon == lon &&
      other.headcount == headcount;

  @override
  int get hashCode => Object.hash(lat, lon, headcount);
}

/// Une soirée d'établissement autour de moi.
@immutable
/// Une soirée à portée — d'un établissement ou ouverte par quelqu'un —
/// avec **« N personnes connectées ici »** ([presentCount], Jay 2026-09-21),
/// vérifié par le serveur à chaque relevé de présence.
class NearbyEvent {
  const NearbyEvent({
    required this.id,
    required this.kind,
    required this.title,
    this.venueName,
    this.venueAddress,
    required this.lat,
    required this.lon,
    required this.radiusM,
    required this.startsAt,
    this.scheduledEndAt,
    required this.presentCount,
    required this.distanceM,
    this.description,
    this.posterPath,
    this.friendsPresent = const [],
  });

  final String id;
  final EventKind kind;
  final String title;

  /// Nul pour un événement ouvert : il n'a pas d'établissement.
  final String? venueName;
  final String? venueAddress;
  final double lat;
  final double lon;
  final int radiusM;
  final DateTime startsAt;
  final DateTime? scheduledEndAt;
  final int presentCount;
  final int distanceM;

  /// Le profil de la soirée (2026-09-25) — voir [NeoEvent.description].
  final String? description;
  final String? posterPath;

  /// MES amis présents (jamais un inconnu).
  final List<String> friendsPresent;

  /// Assez près pour entrer — le serveur reste seul juge, ceci ne sert qu'à
  /// dire à l'utilisateur ce qui va se passer.
  ///
  /// La marge est celle du serveur pour ENTRER (`event_rules.entry_margin_max_m`,
  /// 30 m depuis le 2026-09-25) — elle valait 100 m ici, et « Tu y es »
  /// s'affichait à des soirées où le serveur refusait l'entrée.
  bool get withinReach => distanceM <= radiusM + EventSize.entryMarginM;

  factory NearbyEvent.fromJson(Map<String, dynamic> json) => NearbyEvent(
    id: json['id'] as String,
    kind: EventKind.fromDb(json['kind'] as String? ?? 'venue'),
    title: json['title'] as String,
    venueName: json['venue_name'] as String?,
    venueAddress: json['venue_address'] as String?,
    lat: (json['lat'] as num).toDouble(),
    lon: (json['lon'] as num).toDouble(),
    radiusM: (json['radius_m'] as num?)?.toInt() ?? 60,
    startsAt: DateTime.parse(json['starts_at'] as String),
    scheduledEndAt: json['scheduled_end_at'] == null
        ? null
        : DateTime.parse(json['scheduled_end_at'] as String),
    presentCount: (json['present_count'] as num?)?.toInt() ?? 0,
    distanceM: (json['distance_m'] as num?)?.toInt() ?? 0,
    description: json['description'] as String?,
    posterPath: json['poster_path'] as String?,
    friendsPresent: NeoEvent._ids(json['friends_present']),
  );

  @override
  bool operator ==(Object other) =>
      other is NearbyEvent &&
      other.id == id &&
      other.title == title &&
      other.venueName == venueName &&
      other.venueAddress == venueAddress &&
      other.lat == lat &&
      other.lon == lon &&
      other.radiusM == radiusM &&
      other.startsAt == startsAt &&
      other.scheduledEndAt == scheduledEndAt &&
      other.presentCount == presentCount &&
      other.distanceM == distanceM &&
      other.description == description &&
      other.posterPath == posterPath &&
      listEquals(other.friendsPresent, friendsPresent);

  @override
  int get hashCode => Object.hash(
    id,
    title,
    venueName,
    venueAddress,
    lat,
    lon,
    radiusM,
    startsAt,
    scheduledEndAt,
    presentCount,
    distanceM,
    description,
    posterPath,
    Object.hashAll(friendsPresent),
  );
}

/// Le récap d'un événement (`event_recap`, 2026-09-21) : ce qu'on y a vécu,
/// en nombres — la matière du « lendemain » et de la galerie.
class EventRecap {
  const EventRecap({
    required this.presentCount,
    required this.vibeCount,
    required this.metCount,
    required this.newFriendCount,
    required this.friendsPresent,
  });

  /// Tous ceux qui sont passés, pas seulement ceux qui restent.
  final int presentCount;
  final int vibeCount;

  /// Les gens que J'Y ai rencontrés (présence commune ≥ 30 min).
  final int metCount;

  /// Les amitiés nouées depuis le début de l'événement avec quelqu'un qui y était.
  final int newFriendCount;

  /// Mes amis qui y étaient.
  final List<String> friendsPresent;

  factory EventRecap.fromJson(Map<String, dynamic> json) => EventRecap(
    presentCount: (json['present_count'] as num?)?.toInt() ?? 0,
    vibeCount: (json['vibe_count'] as num?)?.toInt() ?? 0,
    metCount: (json['met_count'] as num?)?.toInt() ?? 0,
    newFriendCount: (json['new_friend_count'] as num?)?.toInt() ?? 0,
    friendsPresent: [
      for (final id in json['friends_present'] as List? ?? const [])
        id as String,
    ],
  );

  @override
  bool operator ==(Object other) =>
      other is EventRecap &&
      other.presentCount == presentCount &&
      other.vibeCount == vibeCount &&
      other.metCount == metCount &&
      other.newFriendCount == newFriendCount &&
      _sameIds(other.friendsPresent, friendsPresent);

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    presentCount,
    vibeCount,
    metCount,
    newFriendCount,
    Object.hashAll(friendsPresent),
  );
}

/// Un défi posé dans un événement (le premier « jeu », 2026-09-21) : une
/// phrase, à laquelle on répond par une Vibe dans la bibliothèque.
class EventChallenge {
  const EventChallenge({
    required this.id,
    required this.eventId,
    required this.authorId,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String eventId;
  final String authorId;
  final String text;
  final DateTime createdAt;

  factory EventChallenge.fromJson(Map<String, dynamic> json) => EventChallenge(
    id: json['id'] as String,
    eventId: json['event_id'] as String,
    authorId: json['author_id'] as String,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  @override
  bool operator ==(Object other) =>
      other is EventChallenge &&
      other.id == id &&
      other.eventId == eventId &&
      other.authorId == authorId &&
      other.text == text &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, eventId, authorId, text, createdAt);
}

/// **Une rencontre gardée** (`meetings`, 2026-09-21) : qui, où, quand — et
/// ce qu'on est devenus. Deux ans, effaçable.
class Meeting {
  const Meeting({
    required this.id,
    required this.userId,
    required this.displayName,
    this.tagName,
    this.avatarUrl,
    required this.origin,
    this.eventId,
    this.eventTitle,
    this.lat,
    this.lon,
    required this.metAt,
    required this.lastAt,
    required this.connected,
    required this.times,
  });

  final String id;
  final String userId;
  final String displayName;
  final String? tagName;
  final String? avatarUrl;

  /// `ping` (la rue, le bus) ou `event`.
  final String origin;
  final String? eventId;
  final String? eventTitle;

  /// Le lieu, gommé à 100 m ; nul pour un ping.
  final double? lat;
  final double? lon;
  final DateTime metAt;
  final DateTime lastAt;

  /// Amis aujourd'hui.
  final bool connected;

  /// Combien de fois on s'est rencontrés, toutes rencontres gardées.
  final int times;

  /// « Rencontré(e) à Soirée X » ou « Croisé(e) ».
  String get where => switch (origin) {
    'event' =>
      eventTitle == null
          ? 'Rencontré(e) à un événement'
          : 'Rencontré(e) à $eventTitle',
    _ => 'Croisé(e)',
  };

  factory Meeting.fromJson(Map<String, dynamic> json) => Meeting(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    displayName: json['display_name'] as String? ?? '',
    tagName: json['tag_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    origin: json['origin'] as String,
    eventId: json['event_id'] as String?,
    eventTitle: json['event_title'] as String?,
    lat: (json['lat'] as num?)?.toDouble(),
    lon: (json['lon'] as num?)?.toDouble(),
    metAt: DateTime.parse(json['met_at'] as String),
    lastAt: DateTime.parse(json['last_at'] as String),
    connected: json['connected'] as bool? ?? false,
    times: (json['times'] as num?)?.toInt() ?? 1,
  );

  @override
  bool operator ==(Object other) =>
      other is Meeting &&
      other.id == id &&
      other.userId == userId &&
      other.displayName == displayName &&
      other.tagName == tagName &&
      other.avatarUrl == avatarUrl &&
      other.origin == origin &&
      other.eventId == eventId &&
      other.eventTitle == eventTitle &&
      other.lat == lat &&
      other.lon == lon &&
      other.metAt == metAt &&
      other.lastAt == lastAt &&
      other.connected == connected &&
      other.times == times;

  @override
  int get hashCode => Object.hash(id, userId, lastAt, connected, times);
}

/// « Vous vous êtes déjà rencontrés » (`met_before`) : la dernière rencontre
/// gardée avec quelqu'un qui est en face de moi.
class MetBefore {
  const MetBefore({
    required this.origin,
    this.eventTitle,
    required this.metAt,
    required this.times,
  });

  final String origin;
  final String? eventTitle;
  final DateTime metAt;
  final int times;

  /// « Déjà rencontré(e) à Soirée X » / « Déjà croisé(e) ».
  String get label => switch (origin) {
    'event' when eventTitle != null => 'Déjà rencontré(e) à $eventTitle',
    'event' => 'Déjà rencontré(e) à un événement',
    _ => 'Déjà croisé(e)',
  };

  factory MetBefore.fromJson(Map<String, dynamic> json) => MetBefore(
    origin: json['origin'] as String,
    eventTitle: json['event_title'] as String?,
    metAt: DateTime.parse(json['met_at'] as String),
    times: (json['times'] as num?)?.toInt() ?? 1,
  );

  @override
  bool operator ==(Object other) =>
      other is MetBefore &&
      other.origin == origin &&
      other.eventTitle == eventTitle &&
      other.metAt == metAt &&
      other.times == times;

  @override
  int get hashCode => Object.hash(origin, eventTitle, metAt, times);
}
