import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// **Une publication en cours, vue de l'app** — l'instantané que le service
/// natif publie (voir `publish/PublishJob.kt`, `snapshot`). Sans secret :
/// ni clé, ni jeton, ni chemin de fichier autre que la couverture.
class PendingPublication {
  const PendingPublication({
    required this.id,
    required this.kind,
    required this.aspectW,
    required this.aspectH,
    required this.phase,
    required this.released,
    required this.progress,
    required this.createdAt,
    this.cover,
    this.error,
  });

  factory PendingPublication.fromMap(Map<Object?, Object?> m) =>
      PendingPublication(
        id: m['id']! as String,
        kind: m['kind']! as String,
        aspectW: (m['aspectW']! as num).toInt(),
        aspectH: (m['aspectH']! as num).toInt(),
        phase: m['phase']! as String,
        released: m['released'] == true,
        progress: (m['progress'] as num?)?.toDouble() ?? 0,
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
        cover: m['cover'] as String?,
        error: m['error'] as String?,
      );

  final String id;

  /// `album` ou `flow`.
  final String kind;
  final int aspectW;
  final int aspectH;

  /// `preparing` · `uploading` · `waiting` · `registering` · `done` ·
  /// `failed` · `cancelled` (voir le Kotlin).
  final String phase;

  /// « Publier » a été pressé : la publication a le droit d'apparaître.
  final bool released;
  final double progress;
  final int createdAt;
  final String? cover;
  final String? error;

  bool get isDone => phase == 'done';
  bool get isFailed => phase == 'failed';
  bool get isActive => !isDone && !isFailed && phase != 'cancelled';
  bool get isFlow => kind == 'flow';

  /// Ce que la case dit, en un mot.
  String get label => switch (phase) {
    'preparing' => 'Préparation',
    'uploading' => 'Envoi',
    'waiting' || 'registering' => 'Publication',
    'done' => 'Publié',
    'failed' => 'Échec',
    _ => '',
  };

  @override
  bool operator ==(Object other) =>
      other is PendingPublication &&
      other.id == id &&
      other.kind == kind &&
      other.aspectW == aspectW &&
      other.aspectH == aspectH &&
      other.phase == phase &&
      other.released == released &&
      other.progress == progress &&
      other.createdAt == createdAt &&
      other.cover == cover &&
      other.error == error;

  @override
  int get hashCode => Object.hash(id, phase, released, progress, error);
}

/// Ce que le service demande à l'app : un jeton frais.
class PublishNeedsToken {
  const PublishNeedsToken();
}

/// **Le pont vers la file de publication native** (`neovibe/publish`).
///
/// L'app y DÉPOSE (une publication, sa légende, une session) et y LIT (les
/// instantanés). Elle ne transcode plus, ne scelle plus, n'envoie plus : tout
/// cela est au service, qui le finit avec ou sans elle (Jay, 2026-09-19).
///
/// Sans natif (tests), les méthodes ne font rien et le flux est vide.
class PublishBridge {
  PublishBridge._();

  static final PublishBridge instance = PublishBridge._();

  static const _channel = MethodChannel('neovibe/publish');
  static const _events = EventChannel('neovibe/publish/events');

  /// Un seul abonnement natif, partagé : chaque `receiveBroadcastStream` en
  /// ouvrirait un autre, et le second `onCancel` couperait le premier.
  late final Stream<Object> events = _events
      .receiveBroadcastStream()
      .map<Object>((raw) {
        final m = raw as Map<Object?, Object?>;
        if (m['needToken'] == true) return const PublishNeedsToken();
        return [
          for (final j in m['jobs']! as List<Object?>)
            PendingPublication.fromMap(j! as Map<Object?, Object?>),
        ];
      })
      .handleError((_) {})
      .asBroadcastStream();

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  /// La session du serveur : à chaque connexion et à chaque renouvellement.
  Future<void> configure({
    required String url,
    required String anonKey,
    required String accessToken,
  }) => _call('configure', {
    'url': url,
    'anonKey': anonKey,
    'accessToken': accessToken,
  });

  Future<void> signOut() => _call('signOut');

  /// Le dossier de travail d'une publication : c'est là que l'app rend ses
  /// photos et écrit sa couverture, avant de déposer.
  Future<String?> jobDir(String id) => _call<String>('jobDir', {'id': id});

  /// Dépose une publication (le JSON de `PublishJob`). Le travail commence.
  Future<void> enqueue(Map<String, Object?> job) =>
      _call('enqueue', {'job': jsonEncode(job)});

  /// « Publier » : la légende et les droits.
  Future<void> release(
    String id, {
    required String? caption,
    required String? captionFont,
    required bool isPublic,
    required bool shareable,
    required bool saveable,
  }) => _call('release', {
    'id': id,
    'caption': caption,
    'captionFont': captionFont,
    'isPublic': isPublic,
    'shareable': shareable,
    'saveable': saveable,
  });

  Future<void> cancel(String id) => _call('cancel', {'id': id});

  Future<void> retry(String id) => _call('retry', {'id': id});

  /// L'app a vu la publication dans sa liste : le natif efface son dossier.
  Future<void> ack(String id) => _call('ack', {'id': id});

  Future<List<PendingPublication>> pending() async {
    final raw = await _call<List<Object?>>('pending');
    return [
      for (final j in raw ?? const [])
        PendingPublication.fromMap(j! as Map<Object?, Object?>),
    ];
  }
}
