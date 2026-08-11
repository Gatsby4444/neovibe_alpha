import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Cache local des médias du **socle de contenu** (stories et publications) —
/// séparé de celui des Cards.
///
/// Ce n'est pas une duplication par négligence. Le cache des Cards raisonne en
/// budgets de vues et en TTL de message ; ces contenus-là n'ont ni l'un ni
/// l'autre. Ce qui les distingue entre eux est une seule donnée : leur date
/// d'expiration, **nulle pour une publication** (permanente, décision de Jay
/// du 2026-08-11) et à 24 h pour une story.
///
/// Deux espaces :
/// - `own/`    : MES contenus, déposés à la publication. Jamais retéléchargés —
///   l'affichage de mes propres contenus ne doit pas dépendre du réseau.
/// - `others/` : ce que je consulte, gardé jusqu'à expiration (ou sous plafond
///   global si le contenu est permanent).
///
/// Les fichiers y sont **chiffrés** : le clair ne vit que dans le répertoire
/// temporaire, le temps de l'écran. Une seule règle vaut donc partout — tout
/// fichier de ce cache est un scellé, quelle que soit sa provenance.
class ContentMediaCache {
  ContentMediaCache();

  static const othersMaxBytes = 150 * 1024 * 1024; // 150 Mo

  Directory? _root;
  Map<String, dynamic>? _index;

  Future<Directory> _dir(String sub) async {
    _root ??= await getApplicationSupportDirectory();
    final dir = Directory(
      '${_root!.path}${Platform.pathSeparator}content_media'
      '${Platform.pathSeparator}$sub',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  File _faceFile(Directory dir, String contentId, bool front) => File(
    '${dir.path}${Platform.pathSeparator}${contentId}_'
    '${front ? 'front' : 'back'}.seal',
  );

  // ---------------------------------------------------------------------
  // Index des entrées `others/` : la date d'expiration, ou rien.
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
  // Mes contenus
  // ---------------------------------------------------------------------

  /// Dépose le scellé d'une de MES faces, à la publication.
  Future<void> storeOwn(
    String contentId,
    File sealed, {
    required bool front,
  }) async {
    try {
      await sealed.copy(_faceFile(await _dir('own'), contentId, front).path);
    } catch (_) {
      // Le cache est un confort : un échec ne doit jamais bloquer la
      // publication (le contenu existe déjà côté serveur à ce moment-là).
    }
  }

  Future<File?> tryOwn(String contentId, {required bool front}) async {
    final file = _faceFile(await _dir('own'), contentId, front);
    if (!await file.exists()) return null;
    try {
      await file.setLastModified(DateTime.now()); // usage LRU
    } catch (_) {}
    return file;
  }

  // ---------------------------------------------------------------------
  // Les contenus des autres
  // ---------------------------------------------------------------------

  /// Scellé d'une face d'autrui : depuis le cache s'il est là, sinon
  /// téléchargé puis indexé. [expiresAt] nul = contenu permanent (publication).
  Future<File> others(
    String contentId, {
    required bool front,
    required Future<String> Function() signedUrl,
    DateTime? expiresAt,
  }) async {
    final file = _faceFile(await _dir('others'), contentId, front);
    final index = await _loadIndex();
    if (await file.exists() && index.containsKey(contentId)) return file;
    await _download(await signedUrl(), file);
    index[contentId] = {
      if (expiresAt != null) 'expiresAt': expiresAt.toIso8601String(),
      'storedAt': DateTime.now().toIso8601String(),
    };
    await _saveIndex();
    await _enforceLimits();
    return file;
  }

  /// Purge immédiate de toutes les faces d'un contenu : expiration, retrait
  /// par l'auteur, ou **révocation** par la modération.
  Future<void> purge(String contentId) async {
    for (final sub in const ['own', 'others']) {
      final dir = await _dir(sub);
      await for (final entity in dir.list()) {
        if (entity is File &&
            entity.uri.pathSegments.last.startsWith('${contentId}_')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    final index = await _loadIndex();
    if (index.remove(contentId) != null) await _saveIndex();
  }

  /// Expiration puis plafond global. Un contenu expiré n'a aucune raison de
  /// rester : le serveur ne le sert plus.
  Future<void> _enforceLimits() async {
    final index = await _loadIndex();
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in index.entries) {
      final meta = entry.value as Map<String, dynamic>;
      final raw = meta['expiresAt'] as String?;
      if (raw == null) continue; // permanent
      final expiresAt = DateTime.tryParse(raw);
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
    // Les plus anciennement stockés partent d'abord.
    final byAge = index.entries.toList()
      ..sort((a, b) {
        final sa = (a.value as Map)['storedAt'] as String? ?? '';
        final sb = (b.value as Map)['storedAt'] as String? ?? '';
        return sa.compareTo(sb);
      });
    for (final entry in byAge) {
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

  /// Un téléchargement qui n'aboutit pas doit **échouer**, pas attendre.
  ///
  /// Sans délai maximal, une requête bloquée laissait l'écran sur son
  /// indicateur de chargement pour toujours : l'utilisateur ne peut ni
  /// comprendre ni réessayer. Mieux vaut une erreur visible qu'une attente
  /// silencieuse.
  static const _timeout = Duration(seconds: 25);

  Future<void> _download(String url, File target) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('Téléchargement échoué (${response.statusCode})');
      }
      final tmp = File('${target.path}.part');
      await response.pipe(tmp.openWrite()).timeout(_timeout);
      await tmp.rename(target.path);
    } finally {
      client.close(force: true);
    }
  }
}

final contentMediaCacheProvider = Provider((ref) => ContentMediaCache());
