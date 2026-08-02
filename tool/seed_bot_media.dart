// Génère et téléverse les faces des Cards des BOTS DE TEST.
//
// Pourquoi un script et pas du SQL : les faces d'une Card sont de vrais
// fichiers du bucket `cards`, et on ne téléverse pas un binaire depuis
// Postgres. Le reste du seed (comptes, amitiés, cards, stories, messages) se
// fait en SQL — voir le rapport de session du 2026-08-01.
//
// Les PNG sont générés ici, sans dépendance : un encodeur minimal (IHDR /
// IDAT zlib / IEND) suffit pour des aplats en dégradé, et évite d'ajouter une
// bibliothèque d'images au projet pour un outil de test.
//
// Usage (le mot de passe n'est PAS dans le dépôt — consigne sécurité) :
//   dart run tool/seed_bot_media.dart <mot-de-passe-des-bots>
//
// Le script est IDEMPOTENT : les chemins sont déterministes et le téléversement
// écrase (`x-upsert`). On peut le relancer sans rien casser.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:neovibe/core/config/env.dart';

/// Bots seedés, et la teinte de leurs faces (pour les distinguer d'un coup
/// d'œil pendant le test).
const _bots = <String, List<int>>{
  'lea.bot@neovibe.dev': [0xE9, 0x3D, 0x82],
  'malik.bot@neovibe.dev': [0x29, 0x79, 0xFF],
  'chloe.bot@neovibe.dev': [0x2E, 0xC4, 0xB6],
  'yanis.bot@neovibe.dev': [0xFF, 0x8A, 0x1A],
  'sofia.bot@neovibe.dev': [0x8E, 0x5B, 0xE8],
};

/// Nombre de paires recto/verso générées par bot.
const _cardsPerBot = 3;

const _width = 540;
const _height = 960;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage : dart run tool/seed_bot_media.dart <mot-de-passe-des-bots>',
    );
    exit(64);
  }
  final password = args.first;
  final client = HttpClient();

  for (final entry in _bots.entries) {
    final email = entry.key;
    final tint = entry.value;
    stdout.writeln('— $email');

    final session = await _signIn(client, email, password);
    if (session == null) {
      stderr.writeln('  échec de connexion, bot ignoré');
      continue;
    }
    final (token, userId) = session;

    for (var i = 1; i <= _cardsPerBot; i++) {
      for (final face in ['front', 'back']) {
        final png = _png(tint, i, face == 'front');
        final path = '$userId/seed-$i-$face.png';
        final ok = await _upload(client, token, path, png);
        stdout.writeln('  ${ok ? 'ok' : 'ÉCHEC'}  $path');
      }
    }
  }
  client.close();
  stdout.writeln('\nTerminé.');
}

/// Connexion par mot de passe → (jeton d'accès, identifiant utilisateur).
Future<(String, String)?> _signIn(
  HttpClient client,
  String email,
  String password,
) async {
  final uri = Uri.parse('${Env.supabaseUrl}/auth/v1/token?grant_type=password');
  final request = await client.postUrl(uri);
  request.headers
    ..set('apikey', Env.supabasePublishableKey)
    ..set('content-type', 'application/json');
  request.write(jsonEncode({'email': email, 'password': password}));
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    stderr.writeln('  ${response.statusCode} $body');
    return null;
  }
  final json = jsonDecode(body) as Map<String, dynamic>;
  return (
    json['access_token'] as String,
    (json['user'] as Map<String, dynamic>)['id'] as String,
  );
}

/// Téléverse dans le bucket `cards`. `x-upsert` : relancer le script écrase
/// au lieu d'échouer sur un doublon.
Future<bool> _upload(
  HttpClient client,
  String token,
  String path,
  Uint8List bytes,
) async {
  final uri = Uri.parse('${Env.supabaseUrl}/storage/v1/object/cards/$path');
  final request = await client.postUrl(uri);
  request.headers
    ..set('apikey', Env.supabasePublishableKey)
    ..set('authorization', 'Bearer $token')
    ..set('content-type', 'image/png')
    ..set('x-upsert', 'true')
    ..contentLength = bytes.length;
  request.add(bytes);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode >= 300) stderr.writeln('    $body');
  return response.statusCode < 300;
}

// ---------------------------------------------------------------------------
// Encodeur PNG minimal (couleur vraie 8 bits, sans palette ni transparence)
// ---------------------------------------------------------------------------

/// Face au format card (9:16) : dégradé vertical de la teinte du bot, plus
/// une bande claire qui distingue le recto du verso.
Uint8List _png(List<int> tint, int index, bool isFront) {
  // Chaque ligne PNG commence par son octet de filtre (0 = aucun).
  final raw = BytesBuilder();
  for (var y = 0; y < _height; y++) {
    raw.addByte(0);
    final t = y / _height;
    // Le verso est nettement plus sombre : en retournant la card pendant le
    // test, on voit immédiatement que la face a changé.
    final base = isFront ? 1.0 : 0.45;
    // L'index décale la teinte, pour que deux cards du même bot ne soient pas
    // identiques dans la visionneuse.
    final shift = 1.0 - (index - 1) * 0.18;
    final band = (y > _height * 0.44 && y < _height * 0.56) ? 1.45 : 1.0;
    for (var x = 0; x < _width; x++) {
      final k = (0.35 + 0.65 * t) * base * shift * band;
      raw.addByte(_clamp(tint[0] * k));
      raw.addByte(_clamp(tint[1] * k));
      raw.addByte(_clamp(tint[2] * k));
    }
  }

  final out = BytesBuilder();
  out.add([137, 80, 78, 71, 13, 10, 26, 10]); // signature PNG

  final ihdr = BytesBuilder()
    ..add(_u32(_width))
    ..add(_u32(_height))
    ..add([8, 2, 0, 0, 0]); // 8 bits, couleur vraie RGB, pas d'entrelacement
  out.add(_chunk('IHDR', ihdr.takeBytes()));
  out.add(_chunk('IDAT', ZLibCodec().encode(raw.takeBytes()) as Uint8List));
  out.add(_chunk('IEND', Uint8List(0)));
  return out.takeBytes();
}

int _clamp(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.big);

/// Un chunk PNG : longueur, type, données, CRC32 du (type + données).
Uint8List _chunk(String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  final body = Uint8List(typeBytes.length + data.length)
    ..setRange(0, typeBytes.length, typeBytes)
    ..setRange(typeBytes.length, typeBytes.length + data.length, data);
  return Uint8List.fromList([
    ..._u32(data.length),
    ...body,
    ..._u32(_crc32(body)),
  ]);
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(Uint8List bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
