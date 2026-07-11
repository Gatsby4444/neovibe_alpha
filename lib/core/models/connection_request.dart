import 'profile.dart';

enum RequestStatus {
  pending,
  accepted,
  declined,
  expired;

  static RequestStatus fromDb(String value) =>
      RequestStatus.values.byName(value);
}

/// Demande de connexion envoyée pendant une proximité BLE active.
/// Expire dès que les appareils sortent de portée (heartbeat sur expires_at).
class ConnectionRequest {
  const ConnectionRequest({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.status,
    required this.expiresAt,
    this.sender,
  });

  final String id;
  final String senderId;
  final String receiverId;
  final RequestStatus status;
  final DateTime expiresAt;
  final Profile? sender;

  bool get isActive =>
      status == RequestStatus.pending && expiresAt.isAfter(DateTime.now());

  factory ConnectionRequest.fromJson(Map<String, dynamic> json) =>
      ConnectionRequest(
        id: json['id'] as String,
        senderId: json['sender_id'] as String,
        receiverId: json['receiver_id'] as String,
        status: RequestStatus.fromDb(json['status'] as String),
        expiresAt: DateTime.parse(json['expires_at'] as String),
        sender: json['sender'] == null
            ? null
            : Profile.fromJson(json['sender'] as Map<String, dynamic>),
      );
}
