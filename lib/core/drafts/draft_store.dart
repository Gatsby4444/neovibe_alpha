import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// **Un brouillon** : ce que l'utilisateur était en train de publier, tel
/// quel, à l'étape et à la retouche près où il l'a laissé (Jay, 2026-09-20 :
/// *« comme sur les mails »*). Il survit à la fermeture de l'app, à un
/// plantage, à un téléphone qui s'éteint — et vit **trois jours** après sa
/// dernière modification.
///
/// Le brouillon **possède ses fichiers** : les médias importés, les images
/// d'autocollants, les faces capturées vivent dans son dossier
/// (`<support>/drafts/<id>/`), pas sous `work/` (balayé au démarrage). Un
/// brouillon qui pointerait vers des fichiers qui ne lui appartiennent pas
/// se retrouverait vide au prochain lancement.
class Draft {
  const Draft({
    required this.id,
    required this.kind,
    required this.step,
    required this.updatedAt,
    required this.payload,
    this.cover,
    this.summary = '',
  });

  factory Draft.fromJson(Map<String, dynamic> m) => Draft(
    id: m['id'] as String,
    kind: DraftKind.values.byName(m['kind'] as String),
    step: m['step'] as String,
    updatedAt: DateTime.parse(m['updatedAt'] as String),
    payload: (m['payload'] as Map).cast<String, dynamic>(),
    cover: m['cover'] as String?,
    summary: m['summary'] as String? ?? '',
  );

  final String id;
  final DraftKind kind;

  /// Où l'utilisateur en était : `capture`, `edit`, `share`.
  final String step;
  final DateTime updatedAt;

  /// Ce que `VibeDraftState` sait relire.
  final Map<String, dynamic> payload;

  /// Une image pour la liste (chemin absolu dans le dossier du brouillon).
  final String? cover;

  /// Une ligne pour la liste : « 3 photos, 1 vidéo ».
  final String summary;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'step': step,
    'updatedAt': updatedAt.toIso8601String(),
    'payload': payload,
    'cover': cover,
    'summary': summary,
  };

  /// Quand il sera purgé.
  DateTime get expiresAt => updatedAt.add(DraftStore.ttl);
}

/// Une seule famille depuis le 2026-09-21 (albums et Flows sortis du MVP).
/// Un brouillon d'une autre famille laissé sur le disque ne se relit pas
/// ([DraftStore.load] rend null) : [DraftStore.sweep] l'efface au démarrage.
enum DraftKind { vibe }

/// Le rangement des brouillons : un dossier par brouillon, `draft.json`
/// écrit en deux temps (`.tmp` puis renommage — un fichier à moitié écrit
/// au moment où le processus meurt serait un brouillon perdu).
class DraftStore {
  /// [root] : le dossier des brouillons — donné par les tests, trouvé par
  /// `path_provider` sinon.
  DraftStore({Directory? root, this.onChanged})
    // Un nom de paramètre ne peut pas être privé : l'affectation explicite
    // est la seule forme possible, et l'analyse ne le sait pas.
    // ignore: prefer_initializing_formals
    : _root = root;

  /// Un brouillon vit trois jours après sa dernière modification.
  static const ttl = Duration(days: 3);

  Directory? _root;

  /// Appelé après chaque écriture : l'invalidation appartient à l'écriture.
  final void Function()? onChanged;

  Future<Directory> root() async {
    var r = _root;
    if (r == null) {
      final base = await getApplicationSupportDirectory();
      r = _root = Directory('${base.path}${Platform.pathSeparator}drafts');
    }
    if (!await r.exists()) await r.create(recursive: true);
    return r;
  }

  /// Le dossier d'un brouillon, créé s'il manque : c'est là que ses fichiers
  /// vont vivre.
  Future<Directory> dir(String id) async {
    final d = Directory('${(await root()).path}${Platform.pathSeparator}$id');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _file(String id) async =>
      File('${(await dir(id)).path}${Platform.pathSeparator}draft.json');

  Future<void> save(Draft draft) async {
    final f = await _file(draft.id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(draft.toJson()));
    await tmp.rename(f.path);
    onChanged?.call();
  }

  Future<Draft?> load(String id) async {
    try {
      final f = await _file(id);
      if (!await f.exists()) return null;
      return Draft.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Tous les brouillons, le plus récent d'abord.
  Future<List<Draft>> list() async {
    final out = <Draft>[];
    await for (final e in (await root()).list()) {
      if (e is! Directory) continue;
      final d = await load(e.uri.pathSegments.where((s) => s.isNotEmpty).last);
      if (d != null) out.add(d);
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// Retire le brouillon de la liste **sans toucher à ses fichiers** : un
  /// envoi en cours peut encore les lire. Le dossier orphelin part au
  /// prochain [sweep].
  Future<void> forget(String id) async {
    try {
      final f = await _file(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    onChanged?.call();
  }

  /// Efface le brouillon **et ses fichiers**.
  Future<void> delete(String id) async {
    final d = Directory('${(await root()).path}${Platform.pathSeparator}$id');
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
    onChanged?.call();
  }

  /// Au démarrage : ce qui a plus de [ttl] part, et les dossiers sans
  /// `draft.json` (un brouillon jamais écrit) aussi.
  Future<int> sweep({DateTime? now}) async {
    final limite = (now ?? DateTime.now()).subtract(ttl);
    var purges = 0;
    await for (final e in (await root()).list()) {
      if (e is! Directory) continue;
      final id = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final d = await load(id);
      if (d == null || d.updatedAt.isBefore(limite)) {
        try {
          await e.delete(recursive: true);
          purges++;
        } catch (_) {}
      }
    }
    if (purges > 0) onChanged?.call();
    return purges;
  }
}

/// Change à chaque écriture : c'est ce que la liste observe.
class DraftsVersion extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final draftsVersionProvider = NotifierProvider<DraftsVersion, int>(
  DraftsVersion.new,
);

final draftStoreProvider = Provider<DraftStore>(
  (ref) => DraftStore(
    onChanged: () => ref.read(draftsVersionProvider.notifier).bump(),
  ),
);

/// Les brouillons, le plus récent d'abord.
final draftsProvider = FutureProvider<List<Draft>>((ref) {
  ref.watch(draftsVersionProvider);
  return ref.watch(draftStoreProvider).list();
});
