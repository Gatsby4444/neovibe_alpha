// Remplit le FEED de test (Pulse, 2026-09-20) avec les médias libres de
// droits préparés par `tool/prepare_seed_feed.py` : publications, Flows,
// Vibes et stories, publiés PAR LES BOTS, sous leur identité, par les mêmes
// RPC que l'app (`publish_to_library`, `publish_story`) — donc à travers les
// mêmes règles. Un seed qui contournerait la sécurité ne prouverait rien.
//
// Chaque média est scellé comme dans l'app (`ChunkedSeal`, format NVC1),
// avec une clé par contenu ; les vidéos ont leur couverture ; les formats
// sont ceux de l'éditeur (4:5, 1:1, 9:16).
//
// Usage :
//   dart run tool/seed_feed.dart <mot-de-passe-des-bots> [--media docdev/seed-feed]
//
// Ensuite, `tool/seed_feed.sql` pose les croisements et les ajouts au feed.
// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:neovibe/core/config/env.dart';
import 'package:neovibe/core/crypto/chunked_seal.dart';

const _bots = <String, ({String email, List<String> role})>{
  'lea': (email: 'lea.bot@neovibe.dev', role: ['ami']),
  'malik': (email: 'malik.bot@neovibe.dev', role: ['ami']),
  'chloe': (email: 'chloe.bot@neovibe.dev', role: ['ami']),
  'yanis': (email: 'yanis.bot@neovibe.dev', role: ['croise']),
  'sofia': (email: 'sofia.bot@neovibe.dev', role: ['croise']),
};

late HttpClient _http;
late Directory _media;
final _random = Random();

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage : dart run tool/seed_feed.dart <mot-de-passe> [--media dossier]',
    );
    exit(64);
  }
  final password = args.first;
  final i = args.indexOf('--media');
  _media = Directory(i >= 0 ? args[i + 1] : 'docdev/seed-feed');
  _http = HttpClient();
  final ids = <String, String>{};
  try {
    for (final entry in _bots.entries) {
      final session = await _signIn(entry.value.email, password);
      if (session == null) {
        stderr.writeln('${entry.key} : connexion refusée');
        continue;
      }
      final bot = _Bot(entry.key, session.$2, session.$1);
      ids[entry.key] = bot.id;
      stdout.writeln('== ${entry.key} (${bot.id})');
      await bot.seed();
    }
    stdout.writeln(jsonEncode(ids));
  } finally {
    _http.close(force: true);
  }
}

class _Bot {
  _Bot(this.name, this.id, this.token);
  final String name;
  final String id;
  final String token;

  Future<void> seed() async {
    switch (name) {
      case 'lea':
        await _album(
          [
            'pub_00_4x5.jpg',
            'pub_01_4x5.jpg',
            'video_bbb_4x5.mp4',
            'pub_02_4x5.jpg',
          ],
          4,
          5,
          'Journée au lac avec la bande 🌊',
        );
        await _album(
          ['pub_03_4x5.jpg'],
          4,
          5,
          'Coucher de soleil depuis le toit.',
        );
        await _flow('video_sintel_9x16.mp4', 'Répète du groupe, on progresse');
        await _vibe('vibe_30_9x16.jpg', 'vibe_31_9x16.jpg');
        await _story('vibe_32_9x16.jpg', null);
      case 'malik':
        await _album(
          ['pub_24_1x1.jpg', 'pub_25_1x1.jpg'],
          1,
          1,
          'Le marché du dimanche',
        );
        await _flow('video_jelly_9x16.mp4', 'Aquarium, hypnotisant');
        await _vibe('video_bbb_9x16.mp4', 'vibe_33_9x16.jpg');
        await _story('video_jelly_9x16.mp4', 'vibe_34_9x16.jpg');
      case 'chloe':
        await _album(
          [
            'pub_04_4x5.jpg',
            'pub_05_4x5.jpg',
            'pub_06_4x5.jpg',
            'pub_07_4x5.jpg',
            'pub_08_4x5.jpg',
          ],
          4,
          5,
          'Balade en forêt, 12 km 🥾',
        );
        await _vibe('vibe_35_9x16.jpg', null);
        await _album(
          ['pub_26_1x1.jpg'],
          1,
          1,
          null,
          isPublic: false,
        ); // privée : ne doit PAS sortir
      case 'yanis':
        await _album(
          ['pub_09_4x5.jpg', 'pub_10_4x5.jpg', 'video_jelly_4x5.mp4'],
          4,
          5,
          'Soirée au Bar des Amis — merci à tous !',
        );
        await _album(
          ['pub_11_4x5.jpg', 'pub_12_4x5.jpg'],
          4,
          5,
          'Street art du quartier',
        );
        await _flow('video_bbb_9x16.mp4', 'Le lapin le plus célèbre du web 🐰');
        await _vibe('vibe_36_9x16.jpg', 'vibe_37_9x16.jpg');
        await _story('vibe_30_9x16.jpg', 'vibe_31_9x16.jpg');
        await _album(
          ['pub_13_4x5.jpg'],
          4,
          5,
          'Brouillon privé',
          isPublic: false,
        );
      case 'sofia':
        await _album(
          ['video_sintel_4x5.mp4', 'pub_14_4x5.jpg', 'video_bbb_4x5.mp4'],
          4,
          5,
          'Ciné plein air, deux extraits',
        );
        await _album(
          ['pub_27_1x1.jpg', 'pub_28_1x1.jpg', 'pub_29_1x1.jpg'],
          1,
          1,
          'Tour du monde des tasses ☕',
        );
        await _vibe('video_sintel_9x16.mp4', null);
        await _flow('video_jelly_9x16.mp4', null);
    }
  }

  // ── Les publications ────────────────────────────────────────────────

  Future<void> _album(
    List<String> files,
    int w,
    int h,
    String? caption, {
    bool isPublic = true,
  }) async {
    final contentId = _uuid();
    final key = await ChunkedSeal.newKey();
    final rows = <Map<String, Object?>>[];
    for (var slot = 0; slot < files.length; slot++) {
      final f = files[slot];
      final isVideo = f.endsWith('.mp4');
      final path = '$id/${contentId}_$slot.${isVideo ? 'mp4' : 'jpg'}';
      if (!await _upload('library', path, File('${_media.path}/$f'), key))
        return;
      String? poster;
      if (isVideo) {
        poster = '$id/${contentId}_${slot}_poster.jpg';
        if (!await _upload(
          'library',
          poster,
          File('${_media.path}/${f.replaceAll('.mp4', '_poster.jpg')}'),
          key,
        ))
          return;
      }
      rows.add({
        'path': path,
        'is_video': isVideo,
        'duration_ms': isVideo ? 9000 : null,
        'poster_path': poster,
        'width': 1080,
        'height': (1080 * h / w).round(),
      });
    }
    final ok = await _rpc('publish_to_library', {
      'p_item_id': contentId,
      'p_kind': 'album',
      'p_card_type': 'standard',
      'p_media': rows,
      'p_caption': caption,
      'p_caption_font': null,
      'p_is_public': isPublic,
      'p_shareable': true,
      'p_saveable': true,
      'p_media_key': key,
      'p_aspect_w': w,
      'p_aspect_h': h,
      'p_anchor_lat': null,
      'p_anchor_lng': null,
    });
    if (ok)
      stdout.writeln(
        '  publication ${files.length} média(s) ${isPublic ? 'publique' : 'PRIVÉE'} · $contentId',
      );
  }

  Future<void> _flow(String file, String? caption) async {
    final contentId = _uuid();
    final key = await ChunkedSeal.newKey();
    final path = '$id/${contentId}_0.mp4';
    final poster = '$id/${contentId}_0_poster.jpg';
    if (!await _upload('library', path, File('${_media.path}/$file'), key))
      return;
    if (!await _upload(
      'library',
      poster,
      File('${_media.path}/${file.replaceAll('.mp4', '_poster.jpg')}'),
      key,
    ))
      return;
    final ok = await _rpc('publish_to_library', {
      'p_item_id': contentId,
      'p_kind': 'flow',
      'p_card_type': 'standard',
      'p_media': [
        {
          'path': path,
          'is_video': true,
          'duration_ms': 9000,
          'poster_path': poster,
          'width': 1080,
          'height': 1920,
        },
      ],
      'p_caption': caption,
      'p_caption_font': null,
      'p_is_public': true,
      'p_shareable': true,
      'p_saveable': true,
      'p_media_key': key,
      'p_aspect_w': 9,
      'p_aspect_h': 16,
      'p_anchor_lat': null,
      'p_anchor_lng': null,
    });
    if (ok) stdout.writeln('  flow · $contentId');
  }

  Future<void> _vibe(String front, String? back) async {
    final contentId = _uuid();
    final key = await ChunkedSeal.newKey();
    final rows = <Map<String, Object?>>[];
    for (final (slot, f) in [(0, front), if (back != null) (1, back)]) {
      final isVideo = f.endsWith('.mp4');
      final path = '$id/${contentId}_$slot.${isVideo ? 'mp4' : 'jpg'}';
      if (!await _upload('library', path, File('${_media.path}/$f'), key))
        return;
      rows.add({
        'path': path,
        'is_video': isVideo,
        'duration_ms': null,
        'poster_path': null,
        'width': null,
        'height': null,
      });
    }
    final ok = await _rpc('publish_to_library', {
      'p_item_id': contentId,
      'p_kind': 'card',
      'p_card_type': 'standard',
      'p_media': rows,
      'p_caption': null,
      'p_caption_font': null,
      'p_is_public': true,
      'p_shareable': true,
      'p_saveable': true,
      'p_media_key': key,
      'p_aspect_w': null,
      'p_aspect_h': null,
      'p_anchor_lat': null,
      'p_anchor_lng': null,
    });
    if (ok)
      stdout.writeln(
        '  vibe ${back == null ? 'une face' : 'deux faces'} · $contentId',
      );
  }

  Future<void> _story(String front, String? back) async {
    final contentId = _uuid();
    final key = await ChunkedSeal.newKey();
    final frontVideo = front.endsWith('.mp4');
    final backVideo = back?.endsWith('.mp4') ?? false;
    final frontPath = '$id/${contentId}_front.${frontVideo ? 'mp4' : 'jpg'}';
    final backPath = back == null
        ? null
        : '$id/${contentId}_back.${backVideo ? 'mp4' : 'jpg'}';
    if (!await _upload(
      'stories',
      frontPath,
      File('${_media.path}/$front'),
      key,
    ))
      return;
    if (backPath != null &&
        !await _upload('stories', backPath, File('${_media.path}/$back'), key))
      return;
    final ok = await _rpc('publish_story', {
      'p_story_id': contentId,
      'p_card_type': 'standard',
      'p_front_path': frontPath,
      'p_back_path': backPath,
      'p_front_is_video': frontVideo,
      'p_back_is_video': backVideo,
      'p_shareable': true,
      'p_media_key': key,
      'p_saveable': true,
      'p_min_tier': 'friend',
    });
    if (ok) stdout.writeln('  story · $contentId');
  }

  // ── Le coffre et les RPC, sous l'identité du bot ────────────────────

  Future<bool> _upload(
    String bucket,
    String path,
    File clear,
    String key,
  ) async {
    final sealed = File(
      '${Directory.systemTemp.path}/seed_${path.hashCode}.seal',
    );
    try {
      await ChunkedSeal.sealFile(clear, sealed, key);
      final bytes = await sealed.readAsBytes();
      final request = await _http.postUrl(
        Uri.parse('${Env.supabaseUrl}/storage/v1/object/$bucket/$path'),
      );
      request.headers
        ..set('apikey', Env.supabasePublishableKey)
        ..set('authorization', 'Bearer $token')
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
      if (sealed.existsSync()) sealed.deleteSync();
    }
  }

  Future<bool> _rpc(String fn, Map<String, Object?> params) async {
    final request = await _http.postUrl(
      Uri.parse('${Env.supabaseUrl}/rest/v1/rpc/$fn'),
    );
    request.headers
      ..set('apikey', Env.supabasePublishableKey)
      ..set('authorization', 'Bearer $token')
      ..set('content-type', 'application/json');
    request.add(utf8.encode(jsonEncode(params)));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 300) {
      stderr.writeln('    $fn : ${response.statusCode} $body');
      return false;
    }
    return true;
  }
}

Future<(String, String)?> _signIn(String email, String password) async {
  final request = await _http.postUrl(
    Uri.parse('${Env.supabaseUrl}/auth/v1/token?grant_type=password'),
  );
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
