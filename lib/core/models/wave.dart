import 'profile.dart';

/// Wave "le presque" : une connexion est passée à proximité sans interaction.
/// Notification différée par défaut (notify_after), temps réel en opt-in.
class Wave {
  const Wave({
    required this.id,
    required this.peerId,
    required this.detectedAt,
    required this.notifyAfter,
    required this.notified,
    this.peer,
  });

  final String id;
  final String peerId;
  final DateTime detectedAt;
  final DateTime notifyAfter;
  final bool notified;
  final Profile? peer;

  factory Wave.fromJson(Map<String, dynamic> json) => Wave(
    id: json['id'] as String,
    peerId: json['peer_id'] as String,
    detectedAt: DateTime.parse(json['detected_at'] as String),
    notifyAfter: DateTime.parse(json['notify_after'] as String),
    notified: json['notified'] as bool? ?? false,
    peer: json['peer'] == null
        ? null
        : Profile.fromJson(json['peer'] as Map<String, dynamic>),
  );

  // ⚠️ **Égalité de VALEUR, posée le 2026-08-25 (checkup `RAPPELS.md` #52).**
  //
  // Sans elle, `listEquals` retombe sur l'identité et tout `DerivedList` est
  // inopérant — en silence. Deux objets décrivant la même ligne, relus depuis
  // le réseau, doivent être égaux : c'est ce qui permet à un flux qui réémet
  // la même chose de ne réveiller personne.
  @override
  bool operator ==(Object other) =>
      other is Wave &&
      other.id == id &&
      other.peerId == peerId &&
      other.detectedAt == detectedAt &&
      other.notifyAfter == notifyAfter &&
      other.notified == notified &&
      other.peer == peer;

  @override
  int get hashCode =>
      Object.hash(id, peerId, detectedAt, notifyAfter, notified, peer);
}
