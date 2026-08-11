import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Cache local des faces de stories — **séparé de celui des Cards**.
///
/// Ce n'est pas de la duplication de code par négligence : une story et une
/// Card n'ont pas la même règle de rétention. Le cache des Cards raisonne en
/// budgets de vues et en TTL de message ; une story a **une seule règle**, sa
/// date d'expiration. Mélanger les deux index aurait remis dans un même
/// endroit deux cycles de vie différents — exactement ce que la refonte
/// supprime côté serveur.
///
/// Deux espaces, comme pour les Cards :
/// - `own/`    : MES stories, déposées à la publication. Elles ne sont **jamais
///   retéléchargées** — l'affichage de mes propres contenus ne doit pas
///   dépendre du réseau (consigne de Jay).
/// - `others/` : les stories que je consulte, gardées jusqu'à leur expiration
///   puis effacées. Elles évitent de retélécharger à chaque ouverture.
///
/// Les fichiers y sont **chiffrés** : le clair ne vit que dans le répertoire
/// temporaire, le temps de l'écran. Une seule règle vaut donc partout — tout
/// fichier de ce cache est un scellé, quelle que soit sa provenance.
class StoryMediaCache {
  StoryMediaCache();

  static const othersMaxBytes = 100 * 1024 * 1024; // 100 Mo

  Directory? _root;
  Map<String, dynamic>? _index;

  Future<Directory> _dir(String sub) async {
    _root ??= await getApplicationSupportDirectory();
    final dir = Directory(
      '${_root!.path}${Platform.pathSeparator}story_media'
      '${Platform.pathSeparator}$sub',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  File _faceFile(Directory dir, String storyId, bool front) => File(
    '${dir.path}${Platform.pathSeparator}${storyId}_'
    '${front ? 'front' : 'back'}.seal',
  );

  // ---------------------------------------------------------------------
  // Index des entrées `others/` : une seule donnée, la date d'expiration.
  // ---------------------------------------------------------------------

  Future<File> _indexFile() async =>
      File('${(await _dir('others')).path}${Platform.pathSeparator}index.json');

  Future<Map<String, dynamic>> _loadIndex() async {
    if (_index != null) return _index!;
    try {
      final file = await _indexFile();
      _index = await file.exists()
          ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      _index = <String, dynamic>{};
    }
    return _index!;
  }

  Future<void> _saveIndex() async {
    if (_index == null) return;
    try {
      await (await _indexFile()).writeAsString(jsonEncode(_index));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Mes stories
  // ---------------------------------------------------------------------

  /// Dépose le scellé d'une de MES faces, à la publication.
  Future<void> storeOwn(
    String storyId,
    File sealed, {
    required bool front,
  }) async {
    try {
      await sealed.copy(_faceFile(await _dir('own'), storyId, front).path);
    } catch (_) {
      // Le cache est un confort : un échec ne doit jamais bloquer la
      // publication (la story existe déjà côté serveur à ce moment-là).
    }
  }

  Future<File?> tryOwn(String storyId, {required bool front}) async {
    final file = _faceFile(await _dir('own'), storyId, front);
    return await file.exists() ? file : null;
  }

  // ---------------------------------------------------------------------
  // Les stories des autres
  // ---------------------------------------------------------------------

  /// Scellé d'une face d'autrui : depuis le cache s'il est là, sinon
  /// téléchargé puis indexé avec la date d'expiration de la story.
  Future<File> others(
    String storyId,
    DateTime expiresAt, {
    required bool front,
    required Future<String> Function() signedUrl,
  }) async {
    final file = _faceFile(await _dir('others'), storyId, front);
    final index = await _loadIndex();
    if (await file.exists() && index.containsKey(storyId)) return file;
    await _download(await signedUrl(), file);
    index[storyId] = {'expiresAt': expiresAt.toIso8601String()};
    await _saveIndex();
    await _enforceLimits();
    return file;
  }

  /// Purge immédiate de toutes les faces d'une story : expiration, retrait par
  /// l'auteur, ou **révocation** par la modération.
  Future<void> purge(String storyId) async {
    for (final sub in const ['own', 'others']) {
      final dir = await _dir(sub);
      await for (final entity in dir.list()) {
        if (entity is File &&
            entity.uri.pathSegments.last.startsWith('${storyId}_')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    final index = await _loadIndex();
    if (index.remove(storyId) != null) await _saveIndex();
  }

  /// Expiration + plafond global. Une story expirée n'a aucune raison de
  /// rester sur l'appareil : le serveur ne la sert plus.
  Future<void> _enforceLimits() async {
    final index = await _loadIndex();
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in index.entries) {
      final meta = entry.value as Map<String, dynamic>;
      final expiresAt = DateTime.tryParse(meta['expiresAt'] as String? ?? '');
      if (expiresAt == null || now.isAfter(expiresAt)) expired.add(entry.key);
    }
    for (final id in expired) {
      await purge(id);
    }

    final dir = await _dir('others');
    var total = 0;
    final sizes = <String, int>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name == 'index.json') continue;
      final size = (await entity.stat()).size;
      total += size;
      final id = name.split('_').first;
      sizes[id] = (sizes[id] ?? 0) + size;
    }
    if (total <= othersMaxBytes) return;
    // Les plus proches de l'expiration partent d'abord.
    final byDeadline = index.entries.toList()
      ..sort((a, b) {
        final ea = (a.value as Map)['expiresAt'] as String? ?? '';
        final eb = (b.value as Map)['expiresAt'] as String? ?? '';
        return ea.compareTo(eb);
      });
    for (final entry in byDeadline) {
      if (total <= othersMaxBytes) break;
      total -= sizes[entry.key] ?? 0;
      await purge(entry.key);
    }
  }

  /// Balayage de démarrage.
  Future<void> sweep() async {
    try {
      await _enforceLimits();
    } catch (_) {}
  }

  Future<int> _dirSize(String sub) async {
    var total = 0;
    await for (final entity in (await _dir(sub)).list()) {
      if (entity is File) total += (await entity.stat()).size;
    }
    return total;
  }

  /// Occupation actuelle (octets), pour l'écran de gestion du stockage.
  Future<({int ownBytes, int othersBytes})> usage() async =>
      (ownBytes: await _dirSize('own'), othersBytes: await _dirSize('others'));

  Future<void> clear() async {
    for (final sub in const ['own', 'others']) {
      final dir = await _dir(sub);
      await for (final entity in dir.list()) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    _index = <String, dynamic>{};
  }

  Future<void> _download(String url, File target) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('Téléchargement échoué (${response.statusCode})');
      }
      final tmp = File('${target.path}.part');
      await response.pipe(tmp.openWrite());
      await tmp.rename(target.path);
    } finally {
      client.close();
    }
  }
}

final storyMediaCacheProvider = Provider((ref) => StoryMediaCache());
