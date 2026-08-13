// Génère du CONTENU de test pour les bots : Vibes, stories et publications,
// en photo et en vidéo, dans tous les formats de partage.
//
// ⚠️ RÉÉCRIT le 2026-08-12. La version précédente téléversait des **PNG en
// clair** : elle datait d'avant le chiffrement du 2026-08-10 et ne produisait
// plus rien de lisible (ni magie `NVC1`, ni format hérité). Tout passe
// désormais par `ChunkedSeal`, comme l'app.
//
// Pourquoi un script et pas du SQL : les faces sont de vrais fichiers de
// bucket, scellés, et on ne scelle pas un binaire depuis Postgres. Tout passe
// par l'API REST **sous l'identité de chaque bot** — donc à travers les mêmes
// règles d'accès que l'app. Un seed qui contournerait la sécurité ne
// prouverait rien.
//
// Usage (le mot de passe n'est PAS dans le dépôt — consigne sécurité) :
//   dart run tool/seed_bot_media.dart <mot-de-passe> --to <id-ou-username>
//
// Options :
//   --to <uuid|username>  destinataire des Vibes envoyées en DM (obligatoire)
//   --videos <dossier>    dossier de .mp4 sources (défaut : docdev/seed-media)
//
// ⚠️ **Les vidéos seedées n'ont pas leur index MP4 en tête** : `fastStart` est
// une méthode NATIVE, inaccessible depuis un outil Dart pur. Elles se lisent et
// se streament normalement, avec un aller-retour réseau de plus. Seules les
// vidéos filmées dans l'app bénéficient du `faststart`.
//
// Le script est IDEMPOTENT côté fichiers (chemins déterministes, `x-upsert`)
// mais **pas** côté lignes : le relancer recrée des Vibes. C'est voulu — on
// veut pouvoir empiler du contenu de test.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:neovibe/core/config/env.dart';
import 'package:neovibe/core/crypto/chunked_seal.dart';

/// Bots seedés, et la teinte de leurs faces (pour les distinguer d'un coup
/// d'œil pendant le test).
const _bots = <String, List<int>>{
  'lea.bot@neovibe.dev': [0xE9, 0x3D, 0x82],
  'malik.bot@neovibe.dev': [0x29, 0x79, 0xFF],
  'chloe.bot@neovibe.dev': [0x2E, 0xC4, 0xB6],
  'yanis.bot@neovibe.dev': [0xFF, 0x8A, 0x1A],
  'sofia.bot@neovibe.dev': [0x8E, 0x5B, 0xE8],
};

/// Les bots **amis** de Jay : eux seuls envoient des Vibes en DM. Les deux
/// autres sont des croisés — leur contenu doit rester visible par les stories
/// et les publications, pas par la messagerie.
const _friends = {
  'lea.bot@neovibe.dev',
  'malik.bot@neovibe.dev',
  'chloe.bot@neovibe.dev',
};

const _width = 540;
const _height = 960;

late final HttpClient _http;
late final String _seedTag;

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first.startsWith('--')) {
    stderr.writeln(
      'Usage : dart run tool/seed_bot_media.dart <mot-de-passe> '
      '--to <uuid|username> [--videos <dossier>]',
    );
    exit(64);
  }
  final password = args.first;
  final to = _option(args, '--to');
  final videoDir = _option(args, '--videos') ?? 'docdev/seed-media';
  if (to == null) {
    stderr.writeln('--to est requis : le destinataire des Vibes en DM.');
    exit(64);
  }

  final videos = Directory(videoDir).existsSync()
      ? (Directory(videoDir).listSync().whereType<File>().where(
          (f) => f.path.toLowerCase().endsWith('.mp4'),
        )).toList()
      : <File>[];
  if (videos.isEmpty) {
    stderr.writeln(
      'Aucun .mp4 dans $videoDir — seules les faces photo seront générées.',
    );
  } else {
    stdout.writeln('${videos.length} vidéo(s) source dans $videoDir');
  }

  _http = HttpClient();
  _seedTag = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final temp = await Directory.systemTemp.createTemp('seed_bot');

  try {
    for (final entry in _bots.entries) {
      final email = entry.key;
      stdout.writeln('\n— $email');
      final session = await _signIn(email, password);
      if (session == null) {
        stderr.writeln('  échec de connexion, bot ignoré');
        continue;
      }
      final bot = _Bot(
        email: email,
        token: session.$1,
        id: session.$2,
        tint: entry.value,
        temp: temp,
        videos: videos,
      );

      final recipient = await bot.resolve(to);
      await bot.seed(recipient: _friends.contains(email) ? recipient : null);
    }
  } finally {
    temp.deleteSync(recursive: true);
    _http.close();
  }
  stdout.writeln('\nTerminé.');
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

/// Tout ce qu'un bot fabrique, sous sa propre identité.
class _Bot {
  _Bot({
    required this.email,
    required this.token,
    required this.id,
    required this.tint,
    required this.temp,
    required this.videos,
  });

  final String email;
  final String token;
  final String id;
  final List<int> tint;
  final Directory temp;
  final List<File> videos;

  String get _name => email.split('.').first;
  var _counter = 0;

  /// Le destinataire donné en argument : un identifiant, ou un username à
  /// résoudre. Nul si introuvable — le bot se contentera alors de publier.
  Future<String?> resolve(String to) async {
    if (RegExp(r'^[0-9a-f-]{36}$').hasMatch(to)) return to;
    final rows = await _get('/rest/v1/profiles?username=eq.$to&select=id');
    if (rows is List && rows.isNotEmpty) {
      return (rows.first as Map<String, dynamic>)['id'] as String;
    }
    stderr.writeln('  destinataire « $to » introuvable pour ce bot');
    return null;
  }

  Future<void> seed({String? recipient}) async {
    // ─── Vibes envoyées en DM ────────────────────────────────────────────
    if (recipient != null) {
      // Standard photo, recto + verso, sauvegardable.
      await _vibe(
        recipient,
        type: 'standard',
        frontVideo: false,
        backVideo: false,
        saveable: true,
      );
      // Standard vidéo au recto, photo au verso — le cas mixte.
      if (videos.isNotEmpty) {
        await _vibe(
          recipient,
          type: 'standard',
          frontVideo: true,
          backVideo: false,
          scrubbable: true,
        );
        // Oneshot filmé : les DEUX faces en vidéo — la seule forme possible,
        // et le cas le plus lourd.
        await _vibe(
          recipient,
          type: 'oneshot',
          frontVideo: true,
          backVideo: true,
          scrubbable: false,
        );
      }
      // Oneshot photo, deux faces.
      await _vibe(
        recipient,
        type: 'oneshot',
        frontVideo: false,
        backVideo: false,
      );
      // BeReal : deux faces obligatoires — c'est la définition du format, et
      // la contrainte `cards_back_required` la fait respecter en base.
      await _vibe(
        recipient,
        type: 'bereal',
        frontVideo: false,
        backVideo: false,
      );
      // Standard à FACE UNIQUE (verso « passé ») : le seul type où le verso
      // est facultatif, avec la One of One.
      await _vibe(
        recipient,
        type: 'standard',
        frontVideo: false,
        backVideo: false,
        single: true,
      );
      // Vibe à budget limité : 2 vues, 6 s par face. Le format qui vérifie que
      // la limite tient vraiment.
      await _vibe(
        recipient,
        type: 'standard',
        frontVideo: false,
        backVideo: false,
        maxViews: 2,
        viewDurationSeconds: 6,
      );
    }

    // ─── Stories ─────────────────────────────────────────────────────────
    // Un anneau de QUATRE, et c'est un choix de mesure : le préchargement ne
    // s'amorce qu'en avançant *à l'intérieur* d'un anneau
    // (`story_viewer_screen._preloadNext`). Avec deux stories par auteur, il
    // n'avait qu'une occasion de servir par anneau — au relevé du 2026-08-13,
    // une ouverture sur sept en a bénéficié, et le seau « Amorcé » n'a jamais
    // pu se remplir. Quatre stories donnent trois avances, dont deux sur une
    // face vidéo.
    await _content(
      story: true,
      frontVideo: false,
      backVideo: false,
      type: 'standard',
    );
    if (videos.isNotEmpty) {
      // Le cas MIXTE, légal sur une standard : recto vidéo (rien à
      // télécharger) et verso photo (téléchargé en entier). C'est la
      // configuration qui a révélé la reconstruction du lecteur — elle reste
      // au catalogue, c'est elle qu'il faut pouvoir surveiller.
      await _content(
        story: true,
        frontVideo: true,
        backVideo: false,
        type: 'standard',
      );
      // Oneshot filmé : les DEUX faces en vidéo — la seule forme possible.
      await _content(
        story: true,
        frontVideo: true,
        backVideo: true,
        type: 'oneshot',
      );
    }
    await _content(
      story: true,
      frontVideo: false,
      backVideo: false,
      type: 'bereal',
    );

    // ─── Publications (permanentes) ──────────────────────────────────────
    await _content(
      story: false,
      frontVideo: false,
      backVideo: false,
      type: 'standard',
      caption: 'Photo de $_name — seed $_seedTag',
    );
    if (videos.isNotEmpty) {
      await _content(
        story: false,
        frontVideo: true,
        backVideo: true,
        type: 'standard',
        caption: 'Vidéo de $_name — seed $_seedTag',
      );
      await _content(
        story: false,
        frontVideo: true,
        backVideo: false,
        type: 'standard',
        caption: 'Recto filmé, verso photo — $_name, seed $_seedTag',
      );
    }
  }

  // ------------------------------------------------------------------
  // Une Vibe : upload des faces, insertion, clé, puis envoi
  // ------------------------------------------------------------------

  Future<void> _vibe(
    String recipient, {
    required String type,
    required bool frontVideo,
    required bool backVideo,
    bool single = false,
    bool saveable = false,
    bool scrubbable = false,
    int? maxViews,
    int? viewDurationSeconds,
  }) async {
    if (!single) _refuseImpossibleOneshot(type, frontVideo, backVideo);
    final stamp = '${_seedTag}_${_counter++}';
    final key = await ChunkedSeal.newKey();
    final frontPath = '$id/${stamp}_front.${frontVideo ? 'mp4' : 'jpg'}';
    final backPath = single
        ? null
        : '$id/${stamp}_back.${backVideo ? 'mp4' : 'jpg'}';

    if (!await _upload(
      'cards',
      frontPath,
      await _face(frontVideo, true),
      key,
    )) {
      return;
    }
    if (backPath != null &&
        !await _upload('cards', backPath, await _face(backVideo, false), key)) {
      return;
    }

    final card = await _post('/rest/v1/cards', {
      'owner_id': id,
      'card_type': type,
      'front_path': frontPath,
      'back_path': backPath,
      'view_duration_seconds': viewDurationSeconds,
      'max_views': maxViews,
      'saveable': saveable,
      'imported': false,
      'front_is_video': frontVideo,
      'back_is_video': backVideo,
      'scrubbable': scrubbable,
      'encrypted': true,
    }, representation: true);
    if (card == null) return;
    final cardId = (card as List).first['id'] as String;

    // La clé part APRÈS l'insertion : elle référence la Vibe.
    await _rpc('set_card_media_key', {'p_card_id': cardId, 'p_media_key': key});

    // Envoi : conversation directe, message, livraison — exactement ce que
    // fait `CardsRepository.send`.
    final convId = await _rpc('get_or_create_direct_conversation', {
      'peer': recipient,
    });
    if (convId is! String) {
      stderr.writeln('    conversation impossible avec $recipient');
      return;
    }
    final message = await _post('/rest/v1/messages', {
      'conversation_id': convId,
      'sender_id': id,
      'kind': 'card',
      'card_id': cardId,
    }, representation: true);
    if (message == null) return;
    await _post('/rest/v1/card_deliveries', {
      'card_id': cardId,
      'recipient_id': recipient,
      'message_id': (message as List).first['id'],
    });

    final faces = backPath == null ? '1 face' : '2 faces';
    final media = [
      if (frontVideo) 'vidéo recto',
      if (backVideo) 'vidéo verso',
    ].join(' + ');
    stdout.writeln(
      '  Vibe $type ($faces${media.isEmpty ? '' : ', $media'})'
      '${maxViews == null ? '' : ' · $maxViews vues'} → DM',
    );
  }

  // ------------------------------------------------------------------
  // Story ou publication : même média, deux régimes de diffusion
  // ------------------------------------------------------------------

  Future<void> _content({
    required bool story,
    required bool frontVideo,
    required bool backVideo,
    required String type,
    String? caption,
  }) async {
    _refuseImpossibleOneshot(type, frontVideo, backVideo);
    final contentId = _uuid();
    final bucket = story ? 'stories' : 'library';
    final key = await ChunkedSeal.newKey();
    final frontPath = '$id/${contentId}_front.${frontVideo ? 'mp4' : 'jpg'}';
    final backPath = '$id/${contentId}_back.${backVideo ? 'mp4' : 'jpg'}';

    if (!await _upload(bucket, frontPath, await _face(frontVideo, true), key)) {
      return;
    }
    if (!await _upload(bucket, backPath, await _face(backVideo, false), key)) {
      return;
    }

    final result = story
        ? await _rpc('publish_story', {
            'p_story_id': contentId,
            'p_card_type': type,
            'p_front_path': frontPath,
            'p_back_path': backPath,
            'p_front_is_video': frontVideo,
            'p_back_is_video': backVideo,
            'p_shareable': true,
            'p_media_key': key,
            'p_saveable': true,
          })
        : await _rpc('publish_to_library', {
            'p_item_id': contentId,
            'p_card_type': type,
            'p_front_path': frontPath,
            'p_back_path': backPath,
            'p_front_is_video': frontVideo,
            'p_back_is_video': backVideo,
            'p_caption': caption,
            'p_is_public': true,
            'p_shareable': true,
            'p_media_key': key,
            'p_saveable': true,
          });
    if (result == null) return;
    stdout.writeln(
      '  ${story ? 'Story' : 'Publication'} $type'
      '${frontVideo || backVideo ? ' (vidéo)' : ' (photo)'}',
    );
  }

  /// Interdit de fabriquer un Oneshot **mixte**, que l'app ne peut pas produire.
  ///
  /// ### La règle, et où elle est écrite
  ///
  /// Un Oneshot déclenche les **deux caméras d'un seul coup**
  /// (`card_capture_screen.dart:596`). Si l'appareil n'en est pas capable, il
  /// **reste photo sur les deux faces** — filmer une face puis l'autre
  /// laisserait un écart où l'on peut tricher, et ce ne serait plus un
  /// Oneshot. Un Oneshot est donc **deux vidéos ou deux photos**, jamais un
  /// mélange.
  ///
  /// ### Pourquoi un garde-fou dans le seed
  ///
  /// Le seed écrivait en base par les RPC de publication, sans passer par
  /// l'écran de capture : rien ne rappelait la contrainte. Il a produit
  /// **6 stories Oneshot recto vidéo / verso photo** — repérées par Jay le
  /// 2026-08-13 comme « théoriquement impossibles en conditions réelles ».
  ///
  /// Et ce n'était pas une curiosité de catalogue : un recto vidéo (qui ne
  /// télécharge rien) avec un verso photo (téléchargé en entier) est
  /// exactement la configuration qui faisait redémarrer le lecteur au milieu
  /// de la lecture (voir [VibeFaceLoading]). **Un jeu de test irréaliste avait
  /// produit un vrai bug — et l'avait rendu illisible.**
  ///
  /// Lever ici plutôt que corriger les appels : un appel corrigé se re-casse à
  /// la prochaine édition, une cause supprimée ne coûte plus rien
  /// (`CLAUDE.md`, règle 1).
  void _refuseImpossibleOneshot(String type, bool frontVideo, bool backVideo) {
    if (type == 'oneshot' && frontVideo != backVideo) {
      throw ArgumentError(
        'Oneshot mixte impossible : les deux faces sont capturées d\'un seul '
        'déclenchement, donc toutes deux vidéo ou toutes deux photo.',
      );
    }
  }

  // ------------------------------------------------------------------
  // Média : une face photo ou vidéo, prête à sceller
  // ------------------------------------------------------------------

  Future<Uint8List> _face(bool video, bool front) async {
    if (!video) return _png(tint, _counter, front);
    // Les sources tournent, pour que deux Vibes du même bot ne montrent pas la
    // même vidéo.
    return videos[(_counter + (front ? 0 : 1)) % videos.length].readAsBytes();
  }

  /// Scelle puis téléverse. Le scellement passe par le **même** code que l'app
  /// (`ChunkedSeal`) : un seed au mauvais format ne testerait rien.
  Future<bool> _upload(
    String bucket,
    String path,
    Uint8List clear,
    String key,
  ) async {
    final source = File('${temp.path}/clear_${path.hashCode}');
    final sealed = File('${temp.path}/sealed_${path.hashCode}');
    try {
      await source.writeAsBytes(clear, flush: true);
      await ChunkedSeal.sealFile(source, sealed, key);
      final bytes = await sealed.readAsBytes();

      final uri = Uri.parse(
        '${Env.supabaseUrl}/storage/v1/object/$bucket/$path',
      );
      final request = await _http.postUrl(uri);
      request.headers
        ..set('apikey', Env.supabasePublishableKey)
        ..set('authorization', 'Bearer $token')
        // Les octets sont scellés : ce ne sont plus ni une image ni une vidéo.
        ..set('content-type', 'application/octet-stream')
        ..set('x-upsert', 'true')
        ..contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 300) {
        stderr.writeln('    upload $path : ${response.statusCode} $body');
        return false;
      }
      return true;
    } finally {
      for (final f in [source, sealed]) {
        try {
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }

  // ------------------------------------------------------------------
  // REST
  // ------------------------------------------------------------------

  Future<Object?> _get(String path) async {
    final request = await _http.getUrl(Uri.parse('${Env.supabaseUrl}$path'));
    request.headers
      ..set('apikey', Env.supabasePublishableKey)
      ..set('authorization', 'Bearer $token');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 300) {
      stderr.writeln('    GET $path : ${response.statusCode} $body');
      return null;
    }
    return body.isEmpty ? null : jsonDecode(body);
  }

  Future<Object?> _post(
    String path,
    Map<String, Object?> body, {
    bool representation = false,
  }) async {
    final request = await _http.postUrl(Uri.parse('${Env.supabaseUrl}$path'));
    request.headers
      ..set('apikey', Env.supabasePublishableKey)
      ..set('authorization', 'Bearer $token')
      ..set('content-type', 'application/json');
    if (representation) request.headers.set('prefer', 'return=representation');
    // `write` encoderait en latin-1 : la moindre légende accentuée ferait
    // échouer la requête. On envoie les octets UTF-8 nous-mêmes.
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 300) {
      stderr.writeln('    POST $path : ${response.statusCode} $text');
      return null;
    }
    return text.isEmpty ? <Object?>[] : jsonDecode(text);
  }

  Future<Object?> _rpc(String name, Map<String, Object?> params) =>
      _post('/rest/v1/rpc/$name', params);
}

/// Connexion par mot de passe → (jeton d'accès, identifiant utilisateur).
Future<(String, String)?> _signIn(String email, String password) async {
  final uri = Uri.parse('${Env.supabaseUrl}/auth/v1/token?grant_type=password');
  final request = await _http.postUrl(uri);
  request.headers
    ..set('apikey', Env.supabasePublishableKey)
    ..set('content-type', 'application/json');
  request.add(utf8.encode(jsonEncode({'email': email, 'password': password})));
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

final _random = Random.secure();

/// UUID v4 — les identifiants de contenu sont fabriqués par le client, comme
/// dans l'app (`Ids.newId`).
String _uuid() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  String hex(int from, int to) => b
      .sublist(from, to)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

// ---------------------------------------------------------------------------
// Encodeur PNG minimal (couleur vraie 8 bits, sans palette ni transparence)
// ---------------------------------------------------------------------------

/// Face au format card (9:16) : dégradé vertical de la teinte du bot, plus
/// une bande claire qui distingue le recto du verso.
Uint8List _png(List<int> tint, int index, bool isFront) {
  final raw = BytesBuilder();
  for (var y = 0; y < _height; y++) {
    raw.addByte(0); // octet de filtre (0 = aucun)
    final t = y / _height;
    // Le verso est nettement plus sombre : en retournant la Vibe pendant le
    // test, on voit immédiatement que la face a changé.
    final base = isFront ? 1.0 : 0.45;
    final shift = 1.0 - (index % 4) * 0.18;
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
