import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/crypto/chunked_seal.dart';
import 'package:neovibe/core/crypto/media_stream_server.dart';

/// Le serveur local est la pièce que le lecteur vidéo interroge réellement.
/// Le format par blocs était déjà couvert (`chunked_seal_test.dart`) — mais
/// **le format juste ne suffit pas** : ce qui casse une lecture vidéo, ce sont
/// les en-têtes `Range` et `Content-Range`, que le lecteur utilise pour
/// connaître la durée et se déplacer.
///
/// Écrit le 2026-08-12 en cherchant pourquoi une vidéo « charge indéfiniment ».
/// Il fallait savoir si le serveur était en cause **avant** de toucher à la
/// couche Android, pour ne pas réparer la mauvaise moitié du problème.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stream');
  });
  tearDown(() async => dir.delete(recursive: true));

  /// Scelle [size] octets pseudo-aléatoires et rend (scellé, clair, clé).
  Future<({File sealed, Uint8List clear, String key})> seal(int size) async {
    final rnd = Random(7);
    final clear = Uint8List.fromList(
      List.generate(size, (_) => rnd.nextInt(256)),
    );
    final src = File('${dir.path}/src_$size')..writeAsBytesSync(clear);
    final sealed = File('${dir.path}/sealed_$size');
    final key = await ChunkedSeal.newKey();
    await ChunkedSeal.sealFile(src, sealed, key);
    return (sealed: sealed, clear: clear, key: key);
  }

  Future<HttpClientResponse> get(Uri url, {String? range}) async {
    final client = HttpClient();
    final req = await client.getUrl(url);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    return req.close();
  }

  test('sert le média entier, octet pour octet', () async {
    final m = await seal(ChunkedSeal.chunkSize * 2 + 4321);
    final url = await MediaStreamServer.instance.publish(m.sealed, m.key);

    final res = await get(url);
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));

    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers.value(HttpHeaders.contentTypeHeader), 'video/mp4');
    expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(res.contentLength, m.clear.length);
    expect(Uint8List.fromList(body), equals(m.clear));

    MediaStreamServer.instance.revoke(url);
  });

  test('sert un intervalle à cheval sur deux blocs', () async {
    final m = await seal(ChunkedSeal.chunkSize * 2);
    final url = await MediaStreamServer.instance.publish(m.sealed, m.key);

    // Volontairement à cheval : commence dans le bloc 0, finit dans le bloc 1.
    final start = ChunkedSeal.chunkSize - 100;
    final end = ChunkedSeal.chunkSize + 99;
    final res = await get(url, range: 'bytes=$start-$end');
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));

    expect(res.statusCode, HttpStatus.partialContent);
    expect(
      res.headers.value(HttpHeaders.contentRangeHeader),
      'bytes $start-$end/${m.clear.length}',
      reason: 'sans Content-Range juste, le lecteur ne sait pas se déplacer',
    );
    expect(Uint8List.fromList(body), equals(m.clear.sublist(start, end + 1)));

    MediaStreamServer.instance.revoke(url);
  });

  test(
    '`bytes=0-` (la toute première requête d\'un lecteur) rend tout',
    () async {
      final m = await seal(50000);
      final url = await MediaStreamServer.instance.publish(m.sealed, m.key);

      final res = await get(url, range: 'bytes=0-');
      final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));

      expect(res.statusCode, HttpStatus.partialContent);
      expect(
        res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-${m.clear.length - 1}/${m.clear.length}',
      );
      expect(Uint8List.fromList(body), equals(m.clear));

      MediaStreamServer.instance.revoke(url);
    },
  );

  test('un jeton révoqué ne répond plus', () async {
    final m = await seal(1000);
    final url = await MediaStreamServer.instance.publish(m.sealed, m.key);
    MediaStreamServer.instance.revoke(url);

    final res = await get(url);
    expect(res.statusCode, HttpStatus.notFound);
  });

  test('un jeton inventé ne donne rien', () async {
    final m = await seal(1000);
    final url = await MediaStreamServer.instance.publish(m.sealed, m.key);

    final res = await get(url.replace(path: '/jetoninvente'));
    expect(res.statusCode, HttpStatus.notFound);

    MediaStreamServer.instance.revoke(url);
  });
}
