import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../../../core/models/library_item.dart';
import 'color_grade.dart';

/// Ce que l'éditeur d'album manipule — **pur** : pas de widget, pas de
/// réseau, pas de natif. L'éditeur affiche ce modèle, l'export le lit.
///
/// Trois raisons d'en faire un objet à part (règle « on sépare tout ce qui
/// peut l'être ») : les règles de Jay (11 médias, 60 s par vidéo, un ratio
/// commun) se testent sans écran ; l'export photo et l'export vidéo lisent
/// exactement la même description ; et un futur « brouillon sauvegardé » n'a
/// qu'à sérialiser ceci.

/// Le plafond de Jay : « jusqu'à 11 contenus ».
const kAlbumMaxMedia = 11;

/// Le plafond de Jay : « vidéo de max 1 min par contenu ».
const kAlbumMaxVideoMs = 60000;

/// Le recadrage d'un média dans le cadre du ratio commun : un zoom et un
/// point de visée, tous deux **relatifs à la source** — le même recadrage vaut
/// donc pour l'aperçu (petit) et pour l'export (grand).
class CropSpec {
  const CropSpec({this.zoom = 1, this.cx = 0.5, this.cy = 0.5})
    : assert(zoom >= 1);

  static const none = CropSpec();

  /// ≥ 1. À 1, le cadre est le plus grand rectangle du ratio qui tient dans
  /// la source (« couvrir », comme `BoxFit.cover`).
  final double zoom;

  /// Le centre du cadre, en fraction de la source (0,5 = au milieu).
  final double cx;
  final double cy;

  static const maxZoom = 3.0;

  CropSpec copyWith({double? zoom, double? cx, double? cy}) =>
      CropSpec(zoom: zoom ?? this.zoom, cx: cx ?? this.cx, cy: cy ?? this.cy);

  /// Le rectangle **source** (en pixels de la source) que le cadre montre,
  /// pour une source de [srcW]×[srcH] et un ratio [aspect]. Toujours
  /// entièrement dans la source : le centre est borné, jamais le cadre ne
  /// déborde sur du vide.
  Rect sourceRect(int srcW, int srcH, double aspect) {
    // Le plus grand rectangle du ratio qui tient dans la source.
    double w, h;
    if (srcW / srcH > aspect) {
      h = srcH.toDouble();
      w = h * aspect;
    } else {
      w = srcW.toDouble();
      h = w / aspect;
    }
    w /= zoom;
    h /= zoom;
    final x = (cx * srcW - w / 2).clamp(0.0, srcW - w);
    final y = (cy * srcH - h / 2).clamp(0.0, srcH - h);
    return Rect.fromLTWH(x, y, w, h);
  }

  /// Le même rectangle, en fractions de la source (0..1) : ce que le shader
  /// vidéo reçoit comme coordonnées de texture.
  Rect normalizedRect(int srcW, int srcH, double aspect) {
    final r = sourceRect(srcW, srcH, aspect);
    return Rect.fromLTWH(
      r.left / srcW,
      r.top / srcH,
      r.width / srcW,
      r.height / srcH,
    );
  }

  /// Un déplacement du doigt de ([dx], [dy]) pixels d'écran, sur un cadre
  /// affiché en [frameW]×[frameH] pixels : le nouveau centre. Le cadre montre
  /// `sourceRect` étiré sur `frameW` — un pixel d'écran vaut donc
  /// `rect.width / frameW` pixels de source.
  CropSpec panned(
    double dx,
    double dy, {
    required int srcW,
    required int srcH,
    required double aspect,
    required double frameW,
    required double frameH,
  }) {
    final r = sourceRect(srcW, srcH, aspect);
    final ncx = cx - dx * (r.width / frameW) / srcW;
    final ncy = cy - dy * (r.height / frameH) / srcH;
    return _clamped(ncx, ncy, srcW, srcH, aspect);
  }

  CropSpec zoomed(
    double factor, {
    required int srcW,
    required int srcH,
    required double aspect,
  }) {
    final z = (zoom * factor).clamp(1.0, maxZoom);
    return CropSpec(
      zoom: z,
      cx: cx,
      cy: cy,
    )._clamped(cx, cy, srcW, srcH, aspect);
  }

  /// Le centre ramené dans la zone où le cadre reste entièrement dans la
  /// source — ainsi `cx`/`cy` décrivent toujours ce qu'on voit, et un zoom
  /// arrière ne « saute » pas.
  CropSpec _clamped(double ncx, double ncy, int srcW, int srcH, double aspect) {
    final r = CropSpec(
      zoom: zoom,
      cx: 0.5,
      cy: 0.5,
    ).sourceRect(srcW, srcH, aspect);
    final halfW = r.width / 2 / srcW;
    final halfH = r.height / 2 / srcH;
    return CropSpec(
      zoom: zoom,
      cx: ncx.clamp(halfW, 1 - halfW),
      cy: ncy.clamp(halfH, 1 - halfH),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CropSpec &&
      other.zoom == zoom &&
      other.cx == cx &&
      other.cy == cy;

  @override
  int get hashCode => Object.hash(zoom, cx, cy);
}

/// Le rognage d'une vidéo : de [startMs] à [endMs] dans la source, et
/// l'instant [coverMs] dont on tire l'image de couverture.
class VideoTrim {
  const VideoTrim({required this.startMs, required this.endMs, int? coverMs})
    : coverMs = coverMs ?? startMs,
      assert(endMs > startMs);

  final int startMs;
  final int endMs;
  final int coverMs;

  int get durationMs => endMs - startMs;

  VideoTrim copyWith({int? startMs, int? endMs, int? coverMs}) => VideoTrim(
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    coverMs: coverMs ?? this.coverMs,
  );

  /// Le rognage ramené dans les règles : dans la source, au plus [maxMs],
  /// au moins 1 s, la couverture dedans.
  VideoTrim normalized(int sourceMs, {int maxMs = kAlbumMaxVideoMs}) {
    var s = startMs.clamp(0, math.max(0, sourceMs - 1000)).toInt();
    var e = endMs.clamp(s + 1000, sourceMs).toInt();
    if (e - s > maxMs) e = s + maxMs;
    if (e > sourceMs) {
      e = sourceMs;
      s = math.max(0, e - maxMs);
    }
    return VideoTrim(
      startMs: s,
      endMs: e,
      coverMs: coverMs.clamp(s, e - 1).toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VideoTrim &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.coverMs == coverMs;

  @override
  int get hashCode => Object.hash(startMs, endMs, coverMs);
}

/// Un média du brouillon : sa source telle que choisie, et tout ce que
/// l'utilisateur lui a fait.
class AlbumDraftMedia {
  const AlbumDraftMedia({
    required this.id,
    required this.source,
    required this.isVideo,
    required this.srcWidth,
    required this.srcHeight,
    this.rotation = 0,
    this.durationMs,
    this.crop = CropSpec.none,
    this.filter = AlbumFilter.normal,
    this.adjust = ColorGrade.none,
    this.trim,
  }) : assert(!isVideo || durationMs != null);

  /// Identité locale, stable pendant l'édition (l'ordre change, pas l'id).
  final String id;

  /// Le fichier tel que rendu par la galerie ou l'appareil photo — **en
  /// clair, et temporaire**. Jamais envoyé tel quel : l'export produit un
  /// nouveau fichier.
  final File source;
  final bool isVideo;

  /// Dimensions **après** rotation (une photo de téléphone est souvent
  /// stockée couchée avec une balise d'orientation).
  final int srcWidth;
  final int srcHeight;

  /// La rotation que le fichier déclare (0, 90, 180, 270), au cas où un
  /// décodeur rendrait l'image telle que stockée, sans l'appliquer.
  final int rotation;

  /// Vidéo : durée de la source.
  final int? durationMs;

  final CropSpec crop;
  final AlbumFilter filter;

  /// Les retouches posées PAR-DESSUS le filtre.
  final ColorGrade adjust;

  /// Vidéo : le rognage ; nul = toute la source (si elle tient en 60 s).
  final VideoTrim? trim;

  /// Le réglage final : le filtre, puis les retouches.
  ColorGrade get grade => adjust.over(filter.grade);

  /// Le rognage effectif d'une vidéo, dans les règles.
  VideoTrim get effectiveTrim =>
      (trim ?? VideoTrim(startMs: 0, endMs: math.max(1000, durationMs ?? 1000)))
          .normalized(durationMs ?? 1000);

  AlbumDraftMedia copyWith({
    CropSpec? crop,
    AlbumFilter? filter,
    ColorGrade? adjust,
    VideoTrim? trim,
  }) => AlbumDraftMedia(
    id: id,
    source: source,
    isVideo: isVideo,
    srcWidth: srcWidth,
    srcHeight: srcHeight,
    rotation: rotation,
    durationMs: durationMs,
    crop: crop ?? this.crop,
    filter: filter ?? this.filter,
    adjust: adjust ?? this.adjust,
    trim: trim ?? this.trim,
  );

  @override
  bool operator ==(Object other) =>
      other is AlbumDraftMedia &&
      other.id == id &&
      other.source.path == source.path &&
      other.isVideo == isVideo &&
      other.srcWidth == srcWidth &&
      other.srcHeight == srcHeight &&
      other.durationMs == durationMs &&
      other.crop == crop &&
      other.filter == filter &&
      other.adjust == adjust &&
      other.trim == trim;

  @override
  int get hashCode => Object.hash(
    id,
    source.path,
    isVideo,
    srcWidth,
    srcHeight,
    durationMs,
    crop,
    filter,
    adjust,
    trim,
  );
}

/// Le brouillon entier.
class AlbumDraft {
  const AlbumDraft({
    this.media = const [],
    this.aspect = AlbumAspect.portrait,
    this.caption = '',
    this.isPublic = false,
    this.shareable = false,
    this.saveable = false,
  });

  final List<AlbumDraftMedia> media;
  final AlbumAspect aspect;
  final String caption;
  final bool isPublic;
  final bool shareable;
  final bool saveable;

  int get freeSlots => kAlbumMaxMedia - media.length;
  bool get isFull => freeSlots <= 0;
  bool get isEmpty => media.isEmpty;

  AlbumDraft copyWith({
    List<AlbumDraftMedia>? media,
    AlbumAspect? aspect,
    String? caption,
    bool? isPublic,
    bool? shareable,
    bool? saveable,
  }) => AlbumDraft(
    media: media ?? this.media,
    aspect: aspect ?? this.aspect,
    caption: caption ?? this.caption,
    isPublic: isPublic ?? this.isPublic,
    shareable: shareable ?? this.shareable,
    saveable: saveable ?? this.saveable,
  );

  /// Ajoute autant de [items] que la place le permet ; le reste est ignoré
  /// (l'appelant compte la différence pour le dire).
  AlbumDraft add(Iterable<AlbumDraftMedia> items) =>
      copyWith(media: [...media, ...items.take(math.max(0, freeSlots))]);

  AlbumDraft remove(String id) =>
      copyWith(media: media.where((m) => m.id != id).toList());

  /// Déplace le média de [from] à [to] (indices dans la liste).
  AlbumDraft reorder(int from, int to) {
    if (from == to || from < 0 || from >= media.length) return this;
    final list = [...media];
    final m = list.removeAt(from);
    list.insert(to.clamp(0, list.length), m);
    return copyWith(media: list);
  }

  AlbumDraft update(String id, AlbumDraftMedia Function(AlbumDraftMedia) f) =>
      copyWith(media: [for (final m in media) m.id == id ? f(m) : m]);

  /// Changer le ratio remet les recadrages à zéro : un cadre 4:5 posé sur une
  /// source n'a pas de sens en 1:1, et un recadrage « au plus large » est le
  /// seul choix qui ne surprend pas.
  AlbumDraft withAspect(AlbumAspect a) => a == aspect
      ? this
      : copyWith(
          aspect: a,
          media: [for (final m in media) m.copyWith(crop: CropSpec.none)],
        );

  /// La **découpe** d'une vidéo trop longue (Jay : *« si une vidéo est trop
  /// longue on peut proposer à l'utilisateur de la découper et répartir
  /// automatiquement sur plusieurs contenus du carrousel parmi les 11 »*).
  ///
  /// Rend les morceaux `[début, fin]` de [maxMs] au plus, dans l'ordre, sans
  /// dépasser [freeSlots] morceaux. Un bout de queue de moins d'une seconde
  /// n'est pas un média : il est laissé de côté.
  static List<VideoTrim> splitPlan(
    int durationMs, {
    required int freeSlots,
    int maxMs = kAlbumMaxVideoMs,
  }) {
    if (freeSlots <= 0 || durationMs <= 0) return const [];
    final parts = <VideoTrim>[];
    var start = 0;
    while (start < durationMs && parts.length < freeSlots) {
      final end = math.min(start + maxMs, durationMs);
      if (end - start < 1000) break;
      parts.add(VideoTrim(startMs: start, endMs: end));
      start = end;
    }
    return parts;
  }
}
