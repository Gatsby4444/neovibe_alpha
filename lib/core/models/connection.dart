import 'profile.dart';

enum ConnectionStatus {
  partial,
  full;

  static ConnectionStatus fromDb(String value) =>
      ConnectionStatus.values.byName(value);
}

class Connection {
  const Connection({
    required this.id,
    required this.userLow,
    required this.userHigh,
    required this.status,
    this.partialExpiresAt,
    this.confirmedLow = false,
    this.confirmedHigh = false,
    this.peer,
  });

  final String id;
  final String userLow;
  final String userHigh;
  final ConnectionStatus status;
  final DateTime? partialExpiresAt;
  final bool confirmedLow;
  final bool confirmedHigh;

  /// Profil de l'autre membre (joint côté requête).
  final Profile? peer;

  String peerIdFor(String me) => me == userLow ? userHigh : userLow;

  /// Est-ce que MOI ([me]) j'ai déjà confirmé ce lien partiel ?
  bool confirmedBy(String me) => me == userLow ? confirmedLow : confirmedHigh;

  factory Connection.fromJson(Map<String, dynamic> json, {Profile? peer}) =>
      Connection(
        id: json['id'] as String,
        userLow: json['user_low'] as String,
        userHigh: json['user_high'] as String,
        status: ConnectionStatus.fromDb(json['status'] as String),
        partialExpiresAt: json['partial_expires_at'] == null
            ? null
            : DateTime.parse(json['partial_expires_at'] as String),
        confirmedLow: json['confirmed_low'] as bool? ?? false,
        confirmedHigh: json['confirmed_high'] as bool? ?? false,
        peer: peer,
      );

  // ⚠️ **Égalité de VALEUR, posée le 2026-08-25 (checkup `RAPPELS.md` #52).**
  //
  // Sans elle, `listEquals` retombe sur l'identité et tout `DerivedList` est
  // inopérant — en silence. Deux objets décrivant la même ligne, relus depuis
  // le réseau, doivent être égaux : c'est ce qui permet à un flux qui réémet
  // la même chose de ne réveiller personne.
  @override
  bool operator ==(Object other) =>
      other is Connection &&
      other.id == id &&
      other.userLow == userLow &&
      other.userHigh == userHigh &&
      other.status == status &&
      other.partialExpiresAt == partialExpiresAt &&
      other.confirmedLow == confirmedLow &&
      other.confirmedHigh == confirmedHigh &&
      other.peer == peer;

  @override
  int get hashCode => Object.hash(
    id,
    userLow,
    userHigh,
    status,
    partialExpiresAt,
    confirmedLow,
    confirmedHigh,
    peer,
  );
}
