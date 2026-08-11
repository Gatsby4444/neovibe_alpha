import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/card.dart';
import '../supabase_providers.dart';

/// Une sauvegarde : une copie **locale et en clair** d'un contenu.
///
/// Elle ne dépend plus de rien côté serveur. C'est le sens de la décision de
/// Jay (2026-08-11) : « pas d'espace serveur dédié ». Avant, `saved_cards`
/// était en `ON DELETE CASCADE` — si l'auteur supprimait sa Vibe, tous ceux
/// qui l'avaient enregistrée la perdaient, alors qu'« Enregistrer » promet de
/// garder.
class SavedItem {
  const SavedItem({
    required this.contentId,
    required this.cardType,
    required this.frontPath,
    required this.savedAt,
    required this.frontIsVideo,
    this.backPath,
    this.backIsVideo = false,
    this.authorName,
    this.mine = false,
  });

  /// Content ID — ou identifiant de Card pour une Vibe reçue en chat.
  /// C'est par lui que la révocation retrouve une copie locale.
  final String contentId;
  final CardType cardType;

  /// Chemins **sur l'appareil**, pas dans un bucket.
  final String frontPath;
  final String? backPath;
  final bool frontIsVideo;
  final bool backIsVideo;
  final DateTime savedAt;
  final String? authorName;

  /// Mon propre contenu, par opposition à celui de quelqu'un d'autre.
  final bool mine;

  bool get hasBack => backPath != null;

  Map<String, dynamic> toJson() => {
    'cardType': cardType.dbValue,
    'frontPath': frontPath,
    'backPath': backPath,
    'frontIsVideo': frontIsVideo,
    'backIsVideo': backIsVideo,
    'savedAt': savedAt.toIso8601String(),
    'authorName': authorName,
    'mine': mine,
  };

  factory SavedItem.fromJson(String id, Map<String, dynamic> j) => SavedItem(
    contentId: id,
    cardType: CardType.fromDb(j['cardType'] as String? ?? 'standard'),
    frontPath: j['frontPath'] as String,
    backPath: j['backPath'] as String?,
    frontIsVideo: j['frontIsVideo'] as bool? ?? false,
    backIsVideo: j['backIsVideo'] as bool? ?? false,
    savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime.now(),
    authorName: j['authorName'] as String?,
    mine: j['mine'] as bool? ?? false,
  );
}

/// Les Enregistrements, **sur l'appareil**.
///
/// ⚠️ Contrairement à tous les autres caches de l'app, les fichiers y sont
/// **en clair**. C'est délibéré et c'est ce qui rend la sauvegarde
/// indépendante du serveur : plus aucune clé à demander pour les afficher.
///
/// Le revers, accepté par Jay en connaissance de cause : la révocation devient
/// **coopérative**. Le serveur demande, l'app obéit — un client modifié peut
/// l'ignorer. On ne promet donc jamais « révocation garantie » sur une
/// sauvegarde, seulement sur un contenu servi par le serveur.
class SavedStore {
  SavedStore(this.ref);
  final Ref ref;

  Directory? _root;
  Map<String, dynamic>? _index;

  Future<Directory> _dir() async {
    _root ??= await getApplicationSupportDirectory();
    final dir = Directory('${_root!.path}${Platform.pathSeparator}saved');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _indexFile() async =>
      File('${(await _dir()).path}${Platform.pathSeparator}index.json');

  Future<Map<String, dynamic>> _load() async {
    if (_index != null) return _index!;
    try {
      final f = await _indexFile();
      _index = await f.exists()
          ? jsonDecode(await f.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      _index = <String, dynamic>{};
    }
    return _index!;
  }

  Future<void> _save() async {
    if (_index == null) return;
    try {
      await (await _indexFile()).writeAsString(jsonEncode(_index));
    } catch (_) {}
  }

  Future<List<SavedItem>> all() async {
    final index = await _load();
    final list = index.entries
        .map(
          (e) => SavedItem.fromJson(
            e.key,
            (e.value as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
    list.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return list;
  }

  Future<bool> isSaved(String contentId) async =>
      (await _load()).containsKey(contentId);

  /// Copie les faces **déjà déchiffrées** dans l'espace des Enregistrements.
  ///
  /// L'appelant a forcément le clair sous la main : il est en train de
  /// l'afficher. Aucun téléchargement, aucune clé à redemander — c'est ce qui
  /// rend l'opération instantanée et hors ligne.
  Future<void> add({
    required String contentId,
    required CardType cardType,
    required File front,
    File? back,
    bool frontIsVideo = false,
    bool backIsVideo = false,
    String? authorName,
    bool mine = false,
  }) async {
    final dir = await _dir();
    String ext(bool v) => v ? 'mp4' : 'jpg';
    final frontPath =
        '${dir.path}${Platform.pathSeparator}${contentId}_front.${ext(frontIsVideo)}';
    await front.copy(frontPath);
    String? backPath;
    if (back != null) {
      backPath =
          '${dir.path}${Platform.pathSeparator}${contentId}_back.${ext(backIsVideo)}';
      await back.copy(backPath);
    }

    final index = await _load();
    index[contentId] = SavedItem(
      contentId: contentId,
      cardType: cardType,
      frontPath: frontPath,
      backPath: backPath,
      frontIsVideo: frontIsVideo,
      backIsVideo: backIsVideo,
      savedAt: DateTime.now(),
      authorName: authorName,
      mine: mine,
    ).toJson();
    await _save();
  }

  Future<void> remove(String contentId) async {
    final index = await _load();
    final meta = index.remove(contentId);
    if (meta == null) return;
    for (final key in const ['frontPath', 'backPath']) {
      final path = (meta as Map)[key] as String?;
      if (path == null) continue;
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await _save();
  }

  /// Demande au serveur lesquels de mes contenus sauvegardés ont été
  /// **révoqués**, et supprime ceux-là.
  ///
  /// ⚠️ La RPC ne renvoie QUE les contenus révoqués — jamais ceux qui ont
  /// simplement disparu. C'est toute la différence avec l'ancien
  /// `ON DELETE CASCADE` : l'auteur qui supprime son contenu ne reprend pas ce
  /// que d'autres ont gardé. Seule la modération le peut.
  Future<int> purgeRevoked() async {
    try {
      final index = await _load();
      if (index.isEmpty) return 0;
      final rows = await ref
          .read(supabaseProvider)
          .rpc('revoked_contents', params: {'p_ids': index.keys.toList()});
      var n = 0;
      for (final id in (rows as List)) {
        await remove(id as String);
        n++;
      }
      return n;
    } catch (_) {
      // Hors ligne : on réessaiera au prochain démarrage. Une sauvegarde reste
      // lisible entre-temps — c'est le prix assumé du « local d'abord ».
      return 0;
    }
  }

  Future<int> usedBytes() async {
    var total = 0;
    await for (final e in (await _dir()).list()) {
      if (e is File) total += (await e.stat()).size;
    }
    return total;
  }

  Future<void> clear() async {
    await for (final e in (await _dir()).list()) {
      try {
        await e.delete();
      } catch (_) {}
    }
    _index = <String, dynamic>{};
  }
}

final savedStoreProvider = Provider(SavedStore.new);

/// Les Enregistrements, pour l'écran qui les liste.
final savedItemsProvider = FutureProvider<List<SavedItem>>(
  (ref) => ref.watch(savedStoreProvider).all(),
);

/// Ce contenu est-il déjà dans mes Enregistrements ?
final isSavedProvider = FutureProvider.family<bool, String>(
  (ref, id) => ref.watch(savedStoreProvider).isSaved(id),
);
