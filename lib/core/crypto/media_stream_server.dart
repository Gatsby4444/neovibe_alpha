import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chunked_seal.dart';

/// Sert les médias **déchiffrés à la volée** au lecteur vidéo, sur
/// `127.0.0.1`.
///
/// ### Pourquoi un serveur
///
/// `video_player` ne sait lire qu'un **fichier** ou une **URL**. Un fichier
/// imposerait d'écrire le clair sur le disque — exactement ce qu'on veut
/// supprimer. Une URL locale, elle, permet de déchiffrer bloc par bloc et de
/// ne rien laisser derrière : les octets en clair ne quittent jamais la
/// mémoire.
///
/// ### Ce qui le rend sûr
///
/// - Il n'écoute que sur la **boucle locale** : aucune autre machine ne peut
///   l'atteindre.
/// - Chaque média reçoit un **jeton aléatoire de 32 caractères**, valable le
///   temps de l'écran. Une autre application du téléphone ne peut pas deviner
///   d'URL utile.
/// - Le jeton est **retiré** dès l'écran fermé : l'URL devient morte.
/// - Il ne démarre que lorsqu'une vidéo est réellement lue.
///
/// Il gère les requêtes `Range`, sans quoi le lecteur ne pourrait ni se
/// déplacer dans la vidéo ni connaître sa durée.
class MediaStreamServer {
  MediaStreamServer._();

  static final instance = MediaStreamServer._();

  HttpServer? _server;
  final _entries = <String, ({File sealed, String key, bool isVideo})>{};
  final _random = Random.secure();

  Future<int> _ensureStarted() async {
    if (_server != null) return _server!.port;
    // Port 0 : le système en choisit un libre.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
    return server.port;
  }

  /// Publie un média scellé et rend l'URL locale à donner au lecteur.
  Future<Uri> publish(File sealed, String key, {bool isVideo = true}) async {
    final port = await _ensureStarted();
    final token = List.generate(
      32,
      (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)],
    ).join();
    _entries[token] = (sealed: sealed, key: key, isVideo: isVideo);
    return Uri.parse('http://127.0.0.1:$port/$token');
  }

  /// À appeler en quittant l'écran : l'URL cesse de répondre.
  void revoke(Uri url) => _entries.remove(url.pathSegments.lastOrNull);

  Future<void> _handle(HttpRequest request) async {
    final token = request.uri.pathSegments.lastOrNull;
    final entry = token == null ? null : _entries[token];
    if (entry == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    try {
      final total = await ChunkedSeal.plainLength(entry.sealed);
      final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader));

      final start = range?.start ?? 0;
      final end = (range?.end ?? total - 1).clamp(start, total - 1);
      final length = end - start + 1;

      final response = request.response
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(
          HttpHeaders.contentTypeHeader,
          entry.isVideo ? 'video/mp4' : 'image/jpeg',
        )
        ..headers.set(HttpHeaders.contentLengthHeader, '$length')
        // Le contenu ne doit pas être mis en cache par la pile réseau : il est
        // déjà en cache sous forme scellée, et une copie en clair ailleurs
        // annulerait le bénéfice.
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');

      if (range != null) {
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$total',
          );
      } else {
        response.statusCode = HttpStatus.ok;
      }

      await for (final part in ChunkedSeal.read(
        entry.sealed,
        entry.key,
        start: start,
        end: end + 1,
      )) {
        response.add(part);
      }
      await response.close();
    } catch (_) {
      // Le lecteur ferme la connexion dès qu'il a ce qu'il veut : une écriture
      // sur socket fermé est normale et ne doit pas remonter.
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  /// `bytes=START-END`, END facultatif. Les autres formes ne sont pas émises
  /// par les lecteurs multimédias.
  ({int start, int? end})? _parseRange(String? header) {
    if (header == null || !header.startsWith('bytes=')) return null;
    final parts = header.substring(6).split('-');
    if (parts.isEmpty) return null;
    final start = int.tryParse(parts[0]);
    if (start == null) return null;
    final end = parts.length > 1 ? int.tryParse(parts[1]) : null;
    return (start: start, end: end);
  }
}

final mediaStreamServerProvider = Provider((ref) => MediaStreamServer.instance);
