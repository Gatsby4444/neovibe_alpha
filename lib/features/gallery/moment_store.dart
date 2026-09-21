import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// **Un moment de ma galerie** — un événement où j'ai été (soirée, moment
/// entre amis), tel que **mon téléphone** s'en souvient : où, quand, avec
/// qui, ce qu'on y a fait — en nombres — et les Vibes que j'ai pu garder.
///
/// Jay, 2026-09-21 : *« un espace galerie qui regrouperait en albums les
/// différents moments passés, où et quand et avec qui, et les événements
/// auxquels on a participé (avec quels amis…) — NeoVibe serait un peu comme
/// une super galerie »*. **Sur le téléphone** (Jay) : le serveur purge un
/// événement cinq jours après sa fermeture ; l'album, lui, reste — c'est
/// pour ça qu'il est copié ici, pas relu là-bas.
class Moment {
  const Moment({
    required this.id,
    required this.title,
    required this.autoCreated,
    required this.kind,
    required this.startedAt,
    this.closedAt,
    this.lat,
    this.lon,
    this.venueName,
    this.friends = const [],
    this.presentCount = 0,
    this.vibeCount = 0,
    this.metCount = 0,
    this.newFriendCount = 0,
    this.keptVibeIds = const [],
    this.kept = false,
  });

  /// L'identifiant de l'événement — celui du serveur, tant qu'il vit.
  final String id;
  final String title;
  final bool autoCreated;

  /// `private`, `venue`, `open`.
  final String kind;
  final DateTime startedAt;
  final DateTime? closedAt;

  /// Le lieu de l'événement (celui du serveur : un établissement, ou là où
  /// l'organisateur l'a ouvert). Nul pour un moment entre amis.
  final double? lat;
  final double? lon;
  final String? venueName;

  /// Mes amis qui y étaient.
  final List<String> friends;
  final int presentCount;
  final int vibeCount;
  final int metCount;
  final int newFriendCount;

  /// Les Vibes du Drop gardées dans mes Enregistrements (celles que leur
  /// auteur a laissées sauvegardables, et les miennes).
  final List<String> keptVibeIds;

  /// Le Drop a été passé en revue à la fermeture : rien de plus à garder.
  final bool kept;

  bool get isOpen => closedAt == null;

  Moment copyWith({
    String? title,
    DateTime? closedAt,
    List<String>? friends,
    int? presentCount,
    int? vibeCount,
    int? metCount,
    int? newFriendCount,
    List<String>? keptVibeIds,
    bool? kept,
  }) => Moment(
    id: id,
    title: title ?? this.title,
    autoCreated: autoCreated,
    kind: kind,
    startedAt: startedAt,
    closedAt: closedAt ?? this.closedAt,
    lat: lat,
    lon: lon,
    venueName: venueName,
    friends: friends ?? this.friends,
    presentCount: presentCount ?? this.presentCount,
    vibeCount: vibeCount ?? this.vibeCount,
    metCount: metCount ?? this.metCount,
    newFriendCount: newFriendCount ?? this.newFriendCount,
    keptVibeIds: keptVibeIds ?? this.keptVibeIds,
    kept: kept ?? this.kept,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'autoCreated': autoCreated,
    'kind': kind,
    'startedAt': startedAt.toIso8601String(),
    'closedAt': closedAt?.toIso8601String(),
    'lat': lat,
    'lon': lon,
    'venueName': venueName,
    'friends': friends,
    'presentCount': presentCount,
    'vibeCount': vibeCount,
    'metCount': metCount,
    'newFriendCount': newFriendCount,
    'keptVibeIds': keptVibeIds,
    'kept': kept,
  };

  factory Moment.fromJson(Map<String, dynamic> j) => Moment(
    id: j['id'] as String,
    title: j['title'] as String,
    autoCreated: j['autoCreated'] as bool? ?? false,
    kind: j['kind'] as String? ?? 'private',
    startedAt: DateTime.parse(j['startedAt'] as String),
    closedAt: j['closedAt'] == null
        ? null
        : DateTime.parse(j['closedAt'] as String),
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    venueName: j['venueName'] as String?,
    friends: [for (final f in j['friends'] as List? ?? const []) f as String],
    presentCount: (j['presentCount'] as num?)?.toInt() ?? 0,
    vibeCount: (j['vibeCount'] as num?)?.toInt() ?? 0,
    metCount: (j['metCount'] as num?)?.toInt() ?? 0,
    newFriendCount: (j['newFriendCount'] as num?)?.toInt() ?? 0,
    keptVibeIds: [
      for (final v in j['keptVibeIds'] as List? ?? const []) v as String,
    ],
    kept: j['kept'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is Moment &&
      other.id == id &&
      other.title == title &&
      other.closedAt == closedAt &&
      other.presentCount == presentCount &&
      other.vibeCount == vibeCount &&
      other.metCount == metCount &&
      other.newFriendCount == newFriendCount &&
      other.kept == kept &&
      other.keptVibeIds.length == keptVibeIds.length &&
      other.friends.length == friends.length;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    closedAt,
    presentCount,
    vibeCount,
    metCount,
    kept,
    keptVibeIds.length,
  );
}

/// **Le rangement des moments** : un fichier `moments.json` dans le dossier
/// de support de l'app, écrit en deux temps (`.tmp` puis renommage). Rien
/// sur le serveur : c'est MA galerie (Jay, 2026-09-21).
class MomentStore {
  MomentStore({Directory? root, this.onChanged})
    // Un nom de paramètre ne peut pas être privé : l'affectation explicite
    // est la seule forme possible, et l'analyse ne le sait pas.
    // ignore: prefer_initializing_formals
    : _root = root;

  Directory? _root;
  final void Function()? onChanged;
  Map<String, Moment>? _cache;

  Future<File> _file() async {
    var r = _root;
    if (r == null) {
      final base = await getApplicationSupportDirectory();
      r = _root = Directory('${base.path}${Platform.pathSeparator}gallery');
    }
    if (!await r.exists()) await r.create(recursive: true);
    return File('${r.path}${Platform.pathSeparator}moments.json');
  }

  Future<Map<String, Moment>> _load() async {
    final c = _cache;
    if (c != null) return c;
    final f = await _file();
    final out = <String, Moment>{};
    if (await f.exists()) {
      try {
        final raw = jsonDecode(await f.readAsString()) as List;
        for (final m in raw) {
          final moment = Moment.fromJson((m as Map).cast<String, dynamic>());
          out[moment.id] = moment;
        }
      } catch (_) {
        // Un fichier illisible : on repart de rien, le serveur redonnera
        // ce qu'il a encore.
      }
    }
    return _cache = out;
  }

  Future<void> _save(Map<String, Moment> all) async {
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode([for (final m in all.values) m.toJson()]),
    );
    await tmp.rename(f.path);
    onChanged?.call();
  }

  /// Tous les moments, le plus récent d'abord.
  Future<List<Moment>> all() async {
    final list = (await _load()).values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list;
  }

  Future<Moment?> get(String id) async => (await _load())[id];

  Future<void> upsert(Moment m) async {
    final all = await _load();
    if (all[m.id] == m) return;
    all[m.id] = m;
    await _save(all);
  }

  Future<void> remove(String id) async {
    final all = await _load();
    if (all.remove(id) != null) await _save(all);
  }
}

/// Change à chaque écriture : c'est ce que la galerie observe.
class MomentsVersion extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final momentsVersionProvider = NotifierProvider<MomentsVersion, int>(
  MomentsVersion.new,
);

final momentStoreProvider = Provider<MomentStore>(
  (ref) => MomentStore(
    onChanged: () => ref.read(momentsVersionProvider.notifier).bump(),
  ),
);

/// La liste des moments, relue à chaque écriture.
final momentsProvider = FutureProvider<List<Moment>>((ref) {
  ref.watch(momentsVersionProvider);
  return ref.watch(momentStoreProvider).all();
});
