import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/card.dart';
import 'native_media.dart';

/// Politique de rétention d'une face mise en cache (contenu des AUTRES).
enum CardCachePolicy {
  /// Card reçue en chat : conservée tant qu'il reste des vues, au plus
  /// jusqu'au TTL 24 h du message ; purgée dès que les vues sont épuisées
  /// ou immédiatement pour une Hot (consigne Jay 2026-07-13).
  chat,

  /// Bibliothèque d'un autre utilisateur : cache de confort court.
  browse,
}

/// Cache local des médias de cards (consigne Jay 2026-07-13) :
/// - `own/`   : MES cards, copiées à la création et gardées tant que la card
///   existe, dans la limite d'un espace alloué paramétrable (les plus
///   anciennes repassent en cloud au-delà) ;
/// - `others/`: faces des cards des autres, préchargées pour un
///   retournement fluide, avec TTL et plafond global — et purge immédiate
///   pour les contenus à restriction (Hot, vues épuisées).
///
/// Tout vit dans le stockage PRIVÉ de l'app (illisible par les autres
/// applications sur un téléphone non rooté) — décision C4 (a).
class CardMediaCache {
  CardMediaCache();

  static const othersMaxBytes = 200 * 1024 * 1024; // 200 Mo (consigne)
  static const browseTtl = Duration(minutes: 48); // consigne Jay (C3)
  static const chatTtl = Duration(hours: 24); // TTL des messages

  Directory? _root;
  Map<String, dynamic>? _index;

  Future<Directory> _dir(String sub) async {
    _root ??= await getApplicationSupportDirectory();
    final dir = Directory(
      '${_root!.path}${Platform.pathSeparator}card_media'
      '${Platform.pathSeparator}$sub',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  File _faceFile(Directory dir, String cardId, bool front, bool isVideo) {
    final ext = isVideo ? 'mp4' : 'jpg';
    final side = front ? 'front' : 'back';
    return File('${dir.path}${Platform.pathSeparator}${cardId}_$side.$ext');
  }

  // ---------------------------------------------------------------------
  // Index des entrées `others/` (politique + horodatage, pour l'éviction).
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
    await (await _indexFile()).writeAsString(jsonEncode(_index));
  }

  // ---------------------------------------------------------------------
  // Mes cards (`own/`)
  // ---------------------------------------------------------------------

  /// Copie locale d'une face de MA card, posée à la création (aucun
  /// re-téléchargement serveur ensuite).
  Future<void> storeOwnFace(
    String cardId,
    File source, {
    required bool front,
    required bool isVideo,
    required int quotaMb,
  }) async {
    try {
      final dir = await _dir('own');
      await source.copy(_faceFile(dir, cardId, front, isVideo).path);
      await _enforceOwnQuota(quotaMb);
    } catch (_) {
      // Le cache est un confort : un échec ne doit jamais bloquer la création.
    }
  }

  /// Face locale de MA card si présente, sinon null (repli cloud).
  Future<File?> tryOwnFace(
    String cardId, {
    required bool front,
    required bool isVideo,
  }) async {
    final file = _faceFile(await _dir('own'), cardId, front, isVideo);
    if (!await file.exists()) return null;
    // Marque l'usage pour l'éviction LRU (les plus anciennes = les moins
    // récemment OUVERTES, pas créées).
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {}
    return file;
  }

  /// Face de MA card : locale si présente, sinon téléchargée PUIS gardée en
  /// local (repli cloud après réinstallation/changement d'appareil).
  Future<File> ownFace(
    CardModel card, {
    required bool front,
    required Future<String> Function() signedUrl,
    required int quotaMb,
  }) async {
    final isVideo = front ? card.frontIsVideo : card.backIsVideo;
    final local = await tryOwnFace(card.id, front: front, isVideo: isVideo);
    if (local != null) return local;
    final file = _faceFile(await _dir('own'), card.id, front, isVideo);
    await _download(await signedUrl(), file);
    await _enforceOwnQuota(quotaMb);
    return file;
  }

  // ---------------------------------------------------------------------
  // Médias simples de MA bibliothèque (photos/vidéos importées)
  // ---------------------------------------------------------------------
  //
  // Ils vivent dans le même dossier `own/` que mes faces de cards — donc sous
  // le même quota — mais sont nommés d'après leur chemin dans le bucket, la
  // seule clé stable dont dispose la grille.

  /// Si l'espace alloué est dépassé, les cards les moins récemment ouvertes
  /// repassent en cloud (leurs fichiers locaux sont supprimés).
  Future<void> _enforceOwnQuota(int quotaMb) async {
    final dir = await _dir('own');
    final files = await dir
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    var total = 0;
    final stats = <(File, DateTime, int)>[];
    for (final f in files) {
      final s = await f.stat();
      total += s.size;
      stats.add((f, s.modified, s.size));
    }
    final budget = quotaMb * 1024 * 1024;
    if (total <= budget) return;
    stats.sort((a, b) => a.$2.compareTo(b.$2)); // plus ancien d'abord
    for (final (file, _, size) in stats) {
      if (total <= budget) break;
      try {
        await file.delete();
        total -= size;
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------
  // Vignettes des faces vidéo
  // ---------------------------------------------------------------------

  /// Extractions en cours, par fichier vidéo : une grille peut demander la même
  /// vignette plusieurs fois (reconstruction, deck + grille) — on décode une
  /// seule fois et tout le monde attend le même résultat.
  final _thumbJobs = <String, Future<File?>>{};

  /// Image de couverture d'une vidéo LOCALE, extraite au premier affichage puis
  /// gardée à côté du fichier (`<vidéo>.thumb.jpg`).
  ///
  /// À la demande, et non à la capture : ça couvre aussi les vidéos **déjà**
  /// en bibliothèque, et ça n'ajoute rien au chemin critique de la prise.
  Future<File?> videoThumb(File video) {
    return _thumbJobs.putIfAbsent(video.path, () async {
      try {
        final thumb = File('${video.path}.thumb.jpg');
        if (await thumb.exists()) return thumb;
        if (!await video.exists()) return null;
        final ok = await NativeMedia.videoThumbnail(
          source: video.path,
          dest: thumb.path,
        );
        return ok && await thumb.exists() ? thumb : null;
      } catch (_) {
        return null; // confort : jamais bloquant
      } finally {
        // Libéré dans tous les cas : un échec ponctuel (fichier en cours
        // d'écriture) doit pouvoir être retenté au prochain affichage.
        _thumbJobs.remove(video.path);
      }
    });
  }

  // ---------------------------------------------------------------------
  // Cards des autres (`others/`)
  // ---------------------------------------------------------------------

  /// Face d'une card d'un AUTRE utilisateur : depuis le cache si valide,
  /// sinon téléchargée et indexée avec sa politique de rétention.
  Future<File> othersFace(
    CardModel card, {
    required bool front,
    required CardCachePolicy policy,
    required Future<String> Function() signedUrl,
  }) async {
    final isVideo = front ? card.frontIsVideo : card.backIsVideo;
    final dir = await _dir('others');
    final file = _faceFile(dir, card.id, front, isVideo);
    final index = await _loadIndex();
    if (await file.exists() && index.containsKey(card.id)) return file;
    await _download(await signedUrl(), file);
    index[card.id] = {
      'policy': policy.name,
      'storedAt': DateTime.now().toIso8601String(),
      'cardCreatedAt': card.createdAt.toIso8601String(),
    };
    await _saveIndex();
    await _enforceOthersLimits();
    return file;
  }

  /// Purge IMMÉDIATE de toutes les faces d'une card (Hot fermée, vues
  /// épuisées, card détruite) — rien ne doit rester sur l'appareil.
  Future<void> purgeCard(String cardId) async {
    final dir = await _dir('others');
    await for (final entity in dir.list()) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('${cardId}_')) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    final index = await _loadIndex();
    if (index.remove(cardId) != null) await _saveIndex();
  }

  /// Balayage : TTL par politique + plafond global 200 Mo (plus ancien
  /// purgé d'abord). Appelé au démarrage et après chaque ajout.
  Future<void> _enforceOthersLimits() async {
    final index = await _loadIndex();
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in index.entries) {
      final meta = entry.value as Map<String, dynamic>;
      final storedAt =
          DateTime.tryParse(meta['storedAt'] as String? ?? '') ?? now;
      final policy = meta['policy'] as String? ?? 'browse';
      final DateTime deadline;
      if (policy == CardCachePolicy.chat.name) {
        // Le message meurt 24 h après la CRÉATION de la card (envoyée dans
        // la foulée) — le cache ne lui survit pas.
        final created =
            DateTime.tryParse(meta['cardCreatedAt'] as String? ?? '') ??
            storedAt;
        deadline = created.add(chatTtl);
      } else {
        deadline = storedAt.add(browseTtl);
      }
      if (now.isAfter(deadline)) expired.add(entry.key);
    }
    for (final cardId in expired) {
      await purgeCard(cardId);
    }

    // Plafond global : purge des entrées les plus anciennes.
    final dir = await _dir('others');
    var total = 0;
    final sizes = <String, int>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name == 'index.json') continue;
      final size = (await entity.stat()).size;
      total += size;
      final cardId = name.split('_').first;
      sizes[cardId] = (sizes[cardId] ?? 0) + size;
    }
    if (total <= othersMaxBytes) return;
    final byAge = index.entries.toList()
      ..sort((a, b) {
        final sa = (a.value as Map)['storedAt'] as String? ?? '';
        final sb = (b.value as Map)['storedAt'] as String? ?? '';
        return sa.compareTo(sb);
      });
    for (final entry in byAge) {
      if (total <= othersMaxBytes) break;
      total -= sizes[entry.key] ?? 0;
      await purgeCard(entry.key);
    }
  }

  // ---------------------------------------------------------------------
  // Entretien & écran de gestion du stockage
  // ---------------------------------------------------------------------

  /// Balayage de démarrage (TTL + plafonds).
  Future<void> sweep(int ownQuotaMb) async {
    try {
      await _enforceOthersLimits();
      await _enforceOwnQuota(ownQuotaMb);
    } catch (_) {}
  }

  Future<int> _dirSize(String sub) async {
    var total = 0;
    await for (final entity in (await _dir(sub)).list()) {
      if (entity is File) total += (await entity.stat()).size;
    }
    return total;
  }

  /// Occupation actuelle (octets) pour l'écran de gestion.
  Future<({int ownBytes, int othersBytes, String path})> usage() async {
    _root ??= await getApplicationSupportDirectory();
    return (
      ownBytes: await _dirSize('own'),
      othersBytes: await _dirSize('others'),
      path: '${_root!.path}${Platform.pathSeparator}card_media',
    );
  }

  Future<void> clearOwn() async {
    final dir = await _dir('own');
    await for (final entity in dir.list()) {
      try {
        await entity.delete();
      } catch (_) {}
    }
  }

  Future<void> clearOthers() async {
    final dir = await _dir('others');
    await for (final entity in dir.list()) {
      try {
        await entity.delete();
      } catch (_) {}
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

final cardMediaCacheProvider = Provider((ref) => CardMediaCache());
