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
/// | [NearbyVenueEvent] | une soirée d'établissement autour de moi | tant qu'elle est ouverte |
///
/// ⚠️ **Tous portent leur `==`.** Les vues dérivées (`DerivedList`,
/// `select`) ne réveillent leurs lecteurs que si la valeur change — et pour
/// ça il faut qu'une valeur puisse se comparer. Un modèle sans `==` rend ces
/// outils inopérants **en silence** (règle de `CLAUDE.md`).

/// D'où vient un événement — et donc **qui a le droit d'y entrer**.
///
/// Les deux règles d'entrée ne partagent rien (règle 2 de `CLAUDE.md`) :
/// - **privé** : être invité au groupe d'événement **et** sur place ;
/// - **établissement** : être sur place.
enum EventKind {
  private,
  venue;

  static EventKind fromDb(String value) => switch (value) {
    'venue' => EventKind.venue,
    _ => EventKind.private,
  };
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

/// L'événement, tel que `my_events()` le rend.
@immutable
class NeoEvent {
  const NeoEvent({
    required this.id,
    required this.kind,
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
  });

  final String id;
  final EventKind kind;
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

  bool get isClosed => closedAt != null;
  bool get isOpen => closedAt == null;
  bool get hasPlace => lat != null && lon != null;

  /// Pas encore commencé : on ne peut pas encore le rejoindre.
  bool notStartedAt(DateTime now) => startsAt.isAfter(now);

  /// Ce que je peux régler : créateur d'un privé, gérant d'un établissement.
  bool canSettings(String me) =>
      isOpen && ((kind == EventKind.private && createdBy == me) || iManage);

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
  );

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.parse(v as String);

  @override
  bool operator ==(Object other) =>
      other is NeoEvent &&
      other.id == id &&
      other.kind == kind &&
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
      other.iManage == iManage;

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
class NearbyVenueEvent {
  const NearbyVenueEvent({
    required this.id,
    required this.title,
    required this.venueName,
    this.venueAddress,
    required this.lat,
    required this.lon,
    required this.radiusM,
    required this.startsAt,
    this.scheduledEndAt,
    required this.presentCount,
    required this.distanceM,
  });

  final String id;
  final String title;
  final String venueName;
  final String? venueAddress;
  final double lat;
  final double lon;
  final int radiusM;
  final DateTime startsAt;
  final DateTime? scheduledEndAt;
  final int presentCount;
  final int distanceM;

  /// Assez près pour entrer — le serveur reste seul juge, ceci ne sert qu'à
  /// dire à l'utilisateur ce qui va se passer.
  bool get withinReach => distanceM <= radiusM + 100;

  factory NearbyVenueEvent.fromJson(Map<String, dynamic> json) =>
      NearbyVenueEvent(
        id: json['id'] as String,
        title: json['title'] as String,
        venueName: json['venue_name'] as String? ?? 'Un lieu',
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
      );

  @override
  bool operator ==(Object other) =>
      other is NearbyVenueEvent &&
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
      other.distanceM == distanceM;

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
  );
}
