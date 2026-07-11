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
}
