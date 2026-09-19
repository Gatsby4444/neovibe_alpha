import 'package:flutter/services.dart';

/// Accès au canal `neovibe/media` — utilitaires média hors caméra.
///
/// L'extraction d'une image de couverture d'une vidéo locale (une vidéo ne se
/// décode pas comme une image côté Dart, cf. « Invalid image data »), la mise
/// en tête de l'index MP4, et depuis le 2026-09-15 ce dont l'éditeur d'album a
/// besoin : la sonde d'un fichier de la galerie, l'encodage JPEG, le
/// transcodage d'une vidéo. Voir `NativeMedia.kt`.
abstract final class NativeMedia {
  static const _channel = MethodChannel('neovibe/media');

  /// Écrit dans [dest] une image JPEG de [source] — la première image-clé, ou
  /// l'image la plus proche de [atMs] si donné. Renvoie `false` sur échec
  /// (fichier illisible, codec absent) — l'appelant retombe alors sur le repli
  /// visuel, ce n'est jamais bloquant.
  static Future<bool> videoThumbnail({
    required String source,
    required String dest,
    int width = 480,
    int atMs = 0,
  }) async {
    try {
      await _channel.invokeMethod<String>('videoThumbnail', {
        'source': source,
        'dest': dest,
        'width': width,
        'atMs': atMs,
      });
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Ce qu'un fichier de la galerie est, sans le décoder : photo ou vidéo,
  /// dimensions **après rotation**, durée. Lève si le fichier n'est ni l'un
  /// ni l'autre.
  static Future<MediaProbe> probe(String path) async {
    final map = await _channel.invokeMapMethod<String, Object?>('probe', {
      'path': path,
    });
    if (map == null) throw StateError('sonde sans réponse');
    return MediaProbe(
      isVideo: map['isVideo'] as bool,
      width: map['width'] as int,
      height: map['height'] as int,
      durationMs: map['durationMs'] as int?,
      rotation: map['rotation'] as int? ?? 0,
    );
  }

  /// Écrit un JPEG à partir de pixels RGBA (ligne par ligne, 4 octets par
  /// pixel) — la sortie d'un rendu `dart:ui`, qui ne sait produire que du PNG.
  static Future<void> encodeJpeg({
    required Uint8List rgba,
    required int width,
    required int height,
    required String dest,
    int quality = 88,
  }) async {
    await _channel.invokeMethod<String>('encodeJpeg', {
      'rgba': rgba,
      'width': width,
      'height': height,
      'dest': dest,
      'quality': quality,
    });
  }

  static final _progress = <String, void Function(double)>{};
  static var _listening = false;

  /// Recompresse une vidéo pour un album : rognée de [startMs] à [endMs],
  /// recadrée / tournée / redressée par les [corners] (les quatre coins du
  /// cadre dans l'image affichée, `CropGeometry.corners`, 8 nombres), passée
  /// par les [uniforms] de couleur (`ColorGrade.toUniforms`, 24 nombres),
  /// avec le calque [overlayPath] (PNG à la taille de sortie) brûlé dessus,
  /// ramenée à [outWidth]×[outHeight]. [rotation] est celle que la sonde a
  /// lue (0, 90, 180, 270) : c'est le transcodeur qui la défait. Voir
  /// `MediaTranscoder.kt`. Lève sur échec.
  static Future<TranscodeResult> transcode({
    required String source,
    required String dest,
    required int startMs,
    required int endMs,
    required List<double> corners,
    required int outWidth,
    required int outHeight,
    required List<double> uniforms,
    required int rotation,
    String? overlayPath,
    void Function(double progress)? onProgress,
  }) async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'transcodeProgress') {
          final args = call.arguments as Map;
          _progress[args['jobId'] as String]?.call(
            (args['progress'] as num).toDouble(),
          );
        }
      });
    }
    final jobId = '${DateTime.now().microsecondsSinceEpoch}';
    if (onProgress != null) _progress[jobId] = onProgress;
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('transcode', {
        'jobId': jobId,
        'source': source,
        'dest': dest,
        'startMs': startMs,
        'endMs': endMs,
        'corners': corners,
        'outWidth': outWidth,
        'outHeight': outHeight,
        'uniforms': uniforms,
        'rotation': rotation,
        'overlayPath': overlayPath,
      });
      return TranscodeResult(
        durationMs: map!['durationMs'] as int,
        hasAudio: map['hasAudio'] as bool,
        note: map['note'] as String? ?? '',
      );
    } finally {
      _progress.remove(jobId);
    }
  }

  /// Le **clair** du média scellé [sealed] (format `NVC1`), en mémoire —
  /// une photo. Déchiffré par le natif sur un fil de travail (AES matériel) ;
  /// rien n'est écrit sur le disque. Nul si le natif est absent (tests) :
  /// l'appelant retombe sur le déchiffrement Dart.
  static Future<Uint8List?> readAll({
    required String sealed,
    required String key,
  }) async {
    try {
      return await _channel.invokeMethod<Uint8List>('readAll', {
        'sealed': sealed,
        'key': key,
      });
    } on MissingPluginException {
      return null;
    }
  }

  /// Écrit dans [dest] le **clair** du média scellé [sealed] (format `NVC1`),
  /// déchiffré par le natif sur un fil de travail — ce que « Enregistrer »
  /// copie dans les Enregistrements.
  ///
  /// Rend `false` si le natif est absent (tests, autre plateforme) : l'appelant
  /// retombe alors sur le déchiffrement Dart. Lève sur un échec réel (clé
  /// fausse, fichier tronqué) — le natif a déjà effacé [dest].
  static Future<bool> unseal({
    required String sealed,
    required String key,
    required String dest,
  }) async {
    try {
      await _channel.invokeMethod<String>('unseal', {
        'sealed': sealed,
        'key': key,
        'dest': dest,
      });
      return true;
    } on MissingPluginException {
      return false;
    }
  }

  /// Déplace l'index d'un MP4 (`moov`) **en tête de fichier**, pour qu'un
  /// lecteur distant puisse décoder dès les premiers octets reçus au lieu
  /// d'aller d'abord chercher la fin.
  ///
  /// Renvoie le verdict natif (`MOVED`, `ALREADY_FAST`, `UNSUPPORTED`,
  /// `FAILED`) à seule fin de journalisation : **aucun n'est bloquant**. Une
  /// vidéo dont l'index n'a pas pu bouger reste parfaitement lisible, elle
  /// démarre seulement moins vite. Voir `Mp4FastStart.kt`.
  static Future<String> fastStart(String path) async {
    try {
      return await _channel.invokeMethod<String>('fastStart', {'path': path}) ??
          'FAILED';
    } on PlatformException {
      return 'FAILED';
    } on MissingPluginException {
      return 'FAILED';
    }
  }
}

/// Le résultat de [NativeMedia.probe].
class MediaProbe {
  const MediaProbe({
    required this.isVideo,
    required this.width,
    required this.height,
    this.durationMs,
    this.rotation = 0,
  });
  final bool isVideo;

  /// Après rotation : ce que l'utilisateur voit.
  final int width;
  final int height;
  final int? durationMs;
  final int rotation;
}

/// Le résultat de [NativeMedia.transcode].
class TranscodeResult {
  const TranscodeResult({
    required this.durationMs,
    required this.hasAudio,
    this.note = '',
  });
  final int durationMs;

  /// Faux si la source n'avait pas de son, ou un son qui n'était pas de
  /// l'AAC (non recopié) : à dire à l'utilisateur.
  final bool hasAudio;

  /// Le compte rendu du natif : décodeur employé, luminance relue, erreurs
  /// GL, repli logiciel — pour le journal (2026-09-19 : des vidéos sortaient
  /// noires sans un mot).
  final String note;
}
