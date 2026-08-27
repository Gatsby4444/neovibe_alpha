import 'profile.dart';

/// Le **palier** d'une relation.
///
/// ⚠️ **Une seule valeur aujourd'hui, et ce n'est pas un oubli.** `partial` a
/// été retirée le 2026-08-28 avec le lien partiel : il n'était pas un palier,
/// c'était une **deuxième porte** vers ce même et unique statut, ouverte
/// automatiquement dès que deux inconnus avaient échangé un message.
///
/// C'est ici que viendront les **paliers de relation** annoncés par Jay le
/// 2026-08-28 — des cercles donnant accès à plus ou moins de fonctionnalités.
/// Ce chantier-là est **séparé du ping** : le ping prouve une rencontre, il ne
/// décide d'aucun palier.
enum ConnectionStatus {
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
    this.peer,
  });

  final String id;
  final String userLow;
  final String userHigh;
  final ConnectionStatus status;

  /// Profil de l'autre membre (joint côté requête).
  final Profile? peer;

  String peerIdFor(String me) => me == userLow ? userHigh : userLow;

  factory Connection.fromJson(Map<String, dynamic> json, {Profile? peer}) =>
      Connection(
        id: json['id'] as String,
        userLow: json['user_low'] as String,
        userHigh: json['user_high'] as String,
        status: ConnectionStatus.fromDb(json['status'] as String),
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
      other.peer == peer;

  @override
  int get hashCode => Object.hash(id, userLow, userHigh, status, peer);
}
