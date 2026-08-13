import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'video_open_trace.dart';

/// L'état d'un [SealedVideoController], tel que le natif le rapporte.
@immutable
class SealedVideoValue {
  const SealedVideoValue({
    this.isInitialized = false,
    this.size = Size.zero,
    this.rotationCorrection = 0,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isCompleted = false,
  });

  final bool isInitialized;
  final Size size;

  /// Degrés à appliquer à l'affichage pour que l'image soit droite. Vaut 0
  /// quand la texture redresse elle-même — ce que seul le natif sait.
  final int rotationCorrection;

  final Duration duration;
  final Duration position;
  final Duration buffered;
  final bool isPlaying;
  final bool isBuffering;

  /// La lecture a atteint la fin. Sert au budget de vues, qui ne doit se
  /// décompter qu'une fois.
  final bool isCompleted;

  double get aspectRatio => size.height == 0 ? 1 : size.width / size.height;

  SealedVideoValue copyWith({
    bool? isInitialized,
    Size? size,
    int? rotationCorrection,
    Duration? duration,
    Duration? position,
    Duration? buffered,
    bool? isPlaying,
    bool? isBuffering,
    bool? isCompleted,
  }) => SealedVideoValue(
    isInitialized: isInitialized ?? this.isInitialized,
    size: size ?? this.size,
    rotationCorrection: rotationCorrection ?? this.rotationCorrection,
    duration: duration ?? this.duration,
    position: position ?? this.position,
    buffered: buffered ?? this.buffered,
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    isCompleted: isCompleted ?? this.isCompleted,
  );
}

/// Pilote le lecteur vidéo **natif** des médias scellés.
///
/// ### Pourquoi il ne s'agit pas de `video_player`
///
/// `video_player` ne sait ouvrir qu'un fichier ou une URL. Pour lui donner une
/// vidéo scellée, la v0.9.54 montait un serveur HTTP local qui déchiffrait en
/// Dart — donc sur l'isolate qui dessine l'écran, à ~2,7 Mo/s. C'est la cause
/// mesurée du saccadement de la v0.9.55.
///
/// Ici, le lecteur natif lit le format scellé lui-même : l'isolate Dart ne
/// transporte plus un octet de vidéo, seulement des commandes et des positions.
/// Le serveur local, son jeton et l'exception réseau en clair ont disparu avec.
///
/// L'API imite volontairement celle de `VideoPlayerController` — les deux faces
/// vidéo l'utilisaient déjà, il n'y avait aucune raison de leur faire apprendre
/// un autre vocabulaire.
class SealedVideoController extends ValueNotifier<SealedVideoValue> {
  // Dart interdit `this._champ` sur un paramètre NOMMÉ (un nom de paramètre ne
  // peut pas être privé) : l'affectation explicite est la seule forme possible,
  // et l'analyse ne le sait pas.
  // ignore_for_file: prefer_initializing_formals
  SealedVideoController._(
    this._path,
    this._key,
    this._traceId, {
    String? url,
    String? cachePath,
    Future<File> Function()? legacyFallback,
  }) : _url = url,
       _cachePath = cachePath,
       _legacyFallback = legacyFallback,
       super(const SealedVideoValue());

  /// Un média scellé qu'on **ne télécharge pas** : le lecteur natif ne réclame
  /// que les blocs qu'il traverse, et garde ce qui a servi dans [cachePath].
  ///
  /// C'est ce qui rend la première image indépendante de la taille de la vidéo
  /// — l'objectif de Jay du 2026-08-12.
  ///
  /// [legacyFallback] couvre le seul cas que le natif ne sait pas lire : un
  /// média scellé **avant** le format par blocs. Il doit rendre un fichier
  /// **en clair** (téléchargé puis déchiffré côté Dart, comme avant). Sans ce
  /// repli, les contenus d'avant le 2026-08-12 deviendraient illisibles.
  SealedVideoController.streaming({
    required String url,
    required String key,
    required String cachePath,
    Future<File> Function()? legacyFallback,
    String? traceId,
  }) : this._(
         null,
         key,
         traceId,
         url: url,
         cachePath: cachePath,
         legacyFallback: legacyFallback,
       );

  /// Un média scellé **entièrement présent** sur l'appareil.
  ///
  /// [traceId] rattache cette lecture à la mesure d'ouverture commencée par
  /// l'écran (voir [VideoOpenTrace]). Nul = ce chemin n'est pas instrumenté,
  /// ce qui ne change rien à la lecture.
  SealedVideoController.sealed({
    required File file,
    required String key,
    String? traceId,
  }) : this._(file.path, key, traceId);

  /// Un fichier déjà en clair : un Enregistrement, ou un média scellé avant le
  /// format par blocs. Même chemin, même contrôleur — les faces vidéo n'ont
  /// ainsi qu'un seul lecteur à connaître.
  SealedVideoController.clear(File file, {String? traceId})
    : this._(file.path, null, traceId);

  static const _channel = MethodChannel('neovibe/player');

  /// Au-delà, on déclare l'échec plutôt que de tourner indéfiniment. Un
  /// chargement sans fin est pire qu'une erreur : l'utilisateur ne peut pas
  /// faire la différence avec une vidéo lente (panne du 2026-08-12).
  static const _openTimeout = Duration(seconds: 20);

  String? _path;
  final String? _key;
  final String? _traceId;
  final String? _url;
  final String? _cachePath;
  final Future<File> Function()? _legacyFallback;

  int? _id;
  StreamSubscription<dynamic>? _events;
  Completer<void>? _ready;
  var _disposed = false;

  /// L'identifiant de texture à donner à un widget `Texture`.
  int? get textureId => _id;

  /// Ouvre le média et attend que le natif annonce sa taille et sa durée.
  ///
  /// Lève si le média est illisible — l'appelant DOIT capter cet échec et le
  /// montrer.
  Future<void> initialize() async {
    if (_ready != null) return _ready!.future;
    final ready = _ready = Completer<void>();

    try {
      final id = await _open();
      if (id == null) throw StateError('le lecteur natif n\'a rendu aucun id');
      if (_disposed) {
        // L'écran s'est fermé pendant l'ouverture : on ne garde pas un lecteur
        // orphelin côté natif.
        await _channel.invokeMethod<void>('dispose', {'id': id});
        return;
      }
      _id = id;
      _events = EventChannel(
        'neovibe/player/events/$id',
      ).receiveBroadcastStream().listen(_onEvent, onError: _onError);
    } catch (e) {
      if (!ready.isCompleted) ready.completeError(e);
      return ready.future;
    }

    return ready.future.timeout(
      _openTimeout,
      onTimeout: () => throw TimeoutException(
        'le lecteur natif n\'a pas répondu',
        _openTimeout,
      ),
    );
  }

  /// Ouvre le lecteur natif, en retombant sur le téléchargement complet si le
  /// média est au format hérité.
  Future<int?> _open() async {
    if (_url == null) {
      return _create({'path': _path, 'key': _key});
    }
    try {
      return await _create({'url': _url, 'cachePath': _cachePath, 'key': _key});
    } on PlatformException catch (e) {
      final fallback = _legacyFallback;
      if (e.code != 'NOT_SEALED' || fallback == null) rethrow;
      // Média scellé avant le format par blocs : le natif ne sait pas le lire
      // et n'a pas à l'apprendre (voir `docs/format-media-scelle.md` §4). On le
      // télécharge en entier, comme avant — ces contenus s'éteignent d'eux-mêmes.
      final file = await fallback();
      _path = file.path;
      // Le fichier rendu est en clair et complet, et le natif le classerait
      // « complet » à juste titre — mais l'utilisateur vient d'attendre son
      // téléchargement ENTIER. Le classer ainsi ferait entrer la plus lente des
      // ouvertures dans le seau réservé aux plus rapides.
      return _create({
        'path': file.path,
      }, availability: MediaAvailability.froid);
    }
  }

  /// Ouvre le lecteur natif et **classe** la mesure d'ouverture.
  ///
  /// L'identifiant et la disponibilité reviennent ensemble parce qu'ils
  /// naissent au même instant : celui de la sonde qui ouvre le média. Le Dart
  /// ne peut pas déduire la seconde — il a essayé jusqu'au 2026-08-13, et se
  /// trompait sur toutes les vidéos partiellement vues.
  ///
  /// [availability] force le classement là où le natif dirait vrai sans dire
  /// juste (le repli hérité, qui télécharge tout avant d'ouvrir un fichier
  /// local).
  Future<int?> _create(
    Map<String, dynamic> args, {
    MediaAvailability? availability,
  }) async {
    // ⚠️ Angle mort comblé le 2026-08-13 : entre la fin de l'ouverture côté
    // Dart et cet appel, il y a Riverpod qui résout, le widget qui se
    // reconstruit et le contrôleur qui se crée. Ce temps tombait dans le jalon
    // « lecteur prêt » sans que rien ne l'y distingue du travail du natif — au
    // relevé du 2026-08-13, il restait 86 ms inexpliquées à froid, et
    // peut-être bien davantage sur la mesure partielle.
    final pending = VideoOpenTrace.of(_traceId);
    if (pending != null) {
      final afterKey = pending.at(VideoOpenStep.cle)?.inMilliseconds ?? 0;
      pending.note('· attente avant natif', pending.elapsedMs - afterKey);
    }
    final reply = await _channel.invokeMapMethod<String, dynamic>(
      'create',
      args,
    );
    if (reply == null) return null;
    final trace = VideoOpenTrace.of(_traceId);
    if (trace != null) {
      trace.availability =
          availability ??
          MediaAvailabilityLabel.parse(reply['availability'] as String?);
      // Ce que l'ouverture du média a coûté au natif, à l'intérieur du jalon
      // « lecteur prêt ».
      trace.note('· ouverture média', (reply['openMs'] as num?)?.toInt() ?? 0);
    }
    return (reply['id'] as num).toInt();
  }

  void _onEvent(dynamic event) {
    if (_disposed || event is! Map) return;
    final map = event.cast<Object?, Object?>();
    switch (map['event']) {
      case 'initialized':
        value = value.copyWith(
          isInitialized: true,
          size: Size(
            (map['width']! as num).toDouble(),
            (map['height']! as num).toDouble(),
          ),
          rotationCorrection: (map['rotation'] as num?)?.toInt() ?? 0,
          duration: Duration(milliseconds: (map['duration']! as num).toInt()),
        );
        VideoOpenTrace.of(_traceId)
          ?..note('· construction lecteur', (map['buildMs']! as num).toInt())
          ..note('· décodage entête', (map['decodeMs']! as num).toInt())
          ..mark(VideoOpenStep.lecteur);
        if (_ready?.isCompleted == false) _ready!.complete();
      case 'firstFrame':
        VideoOpenTrace.of(_traceId)?.mark(VideoOpenStep.premiereImage);
      case 'position':
        value = value.copyWith(
          position: Duration(milliseconds: (map['position']! as num).toInt()),
          buffered: Duration(milliseconds: (map['buffered']! as num).toInt()),
        );
      case 'playing':
        final playing = map['value']! as bool;
        value = value.copyWith(
          isPlaying: playing,
          // Repartir efface la fin précédente : sans ça, une vidéo relancée
          // resterait « terminée » et ne rappellerait jamais son observateur.
          isCompleted: playing ? false : value.isCompleted,
        );
      case 'buffering':
        value = value.copyWith(isBuffering: map['value']! as bool);
      case 'completed':
        value = value.copyWith(isCompleted: true);
      case 'error':
        _onError(
          PlatformException(
            code: 'PLAYBACK_ERROR',
            message: map['message'] as String?,
          ),
        );
    }
  }

  void _onError(Object error, [StackTrace? stack]) {
    // Avant l'ouverture, l'échec part par la future ; après, il n'y a plus
    // personne pour l'attendre — mais la face vidéo a déjà de quoi s'afficher.
    if (_ready?.isCompleted == false) _ready!.completeError(error);
  }

  Future<void> play() => _command('play');

  Future<void> pause() => _command('pause');

  Future<void> seekTo(Duration position) =>
      _command('seekTo', {'position': position.inMilliseconds});

  Future<void> setLooping(bool value) =>
      _command('setLooping', {'value': value});

  Future<void> setVolume(double value) =>
      _command('setVolume', {'value': value.clamp(0.0, 1.0)});

  Future<void> _command(String method, [Map<String, Object?>? args]) async {
    final id = _id;
    if (id == null || _disposed) return;
    await _channel.invokeMethod<void>(method, {'id': id, ...?args});
  }

  @override
  void dispose() {
    _disposed = true;
    _events?.cancel();
    _events = null;
    final id = _id;
    _id = null;
    // Sans attendre : `dispose` est synchrone, et un lecteur natif se ferme de
    // toute façon sans que l'interface ait à le savoir.
    if (id != null) _channel.invokeMethod<void>('dispose', {'id': id});
    super.dispose();
  }
}
