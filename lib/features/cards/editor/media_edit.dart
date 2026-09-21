import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'color_grade.dart';
import 'overlay_model.dart';

/// Ce que l'éditeur d'une Vibe manipule, média par média — **pur** : pas de
/// widget, pas de réseau, pas de natif. L'éditeur affiche ce modèle, l'export
/// le lit.
///
/// Trois raisons d'en faire un objet à part (règle « on sépare tout ce qui
/// peut l'être ») : les règles (60 s par vidéo, le format 9:16) se testent
/// sans écran ; l'export photo et l'export vidéo lisent exactement la même
/// description ; et le brouillon n'a qu'à sérialiser ceci.
///
/// Historique : ce moteur a été écrit pour l'éditeur d'album (2026-09-15),
/// puis l'éditeur de Vibes s'est posé dessus (2026-09-18). Les albums et les
/// Flows sont sortis du MVP le 2026-09-21 (Jay : *« un éditeur pour un
/// format : les Vibes »*) ; le moteur reste, sous son vrai nom.

/// Le plafond de Jay : « vidéo de max 1 min par contenu ».
const kMaxFaceVideoMs = 60000;

/// **Le cadre d'une Vibe : 9:16, plein écran.** Un seul format, jamais
/// choisi — c'est ce qui distingue une Vibe d'une « publication » à
/// formats (retirées du MVP le 2026-09-21). L'export ([MediaExport]) et la
/// géométrie du cadrage ([CropGeometry]) ne connaissent que ce ratio.
enum MediaAspect {
  reel(9, 16, '9:16');

  const MediaAspect(this.w, this.h, this.label);

  final int w;
  final int h;
  final String label;

  double get ratio => w / h;
}

/// Le cadrage d'un média dans le cadre du ratio commun : un **zoom**, un
/// **point de visée**, des **quarts de tour** et un **redressement** fin.
///
/// Zoom et visée sont relatifs au **rectangle inscrit** dans l'image tournée
/// (voir `CropGeometry.inscribed`) : le même cadrage vaut pour l'aperçu
/// (petit) et l'export (grand), et un coin vide est impossible par
/// construction. La géométrie elle-même vit dans `crop_geometry.dart` ; ici,
/// seulement les paramètres et leurs bornes.
class CropSpec {
  const CropSpec({
    this.zoom = 1,
    this.cx = 0.5,
    this.cy = 0.5,
    this.angle = 0,
    this.turns = 0,
  }) : assert(zoom > 0),
       assert(angle >= -maxAngle && angle <= maxAngle),
       assert(turns >= 0 && turns < 4);

  static const none = CropSpec();

  /// À 1, le cadre est le plus grand rectangle du ratio qui tient dans le
  /// rectangle inscrit (« remplir », comme `BoxFit.cover`). **En dessous de
  /// 1** (jusqu'à [fitZoom]), le cadre dépasse l'image : elle est vue
  /// entière, avec des bandes noires (« adapter », comme `BoxFit.contain`) —
  /// le bouton Adapter / Remplir d'Instagram.
  final double zoom;

  /// Le centre du cadre, en fraction du rectangle inscrit (0,5 = au milieu).
  final double cx;
  final double cy;

  /// Le redressement, en degrés, −45 … +45 (l'outil « Redresser »).
  final double angle;

  /// Les quarts de tour, 0 … 3 (le bouton « Tourner »).
  final int turns;

  static const maxZoom = 3.0;
  static const maxAngle = 45.0;

  /// La rotation totale de l'image, en radians (sens horaire à l'écran).
  double get radians => (turns * 90 + angle) * math.pi / 180;

  bool get isUpright => angle == 0 && turns == 0;

  CropSpec copyWith({
    double? zoom,
    double? cx,
    double? cy,
    double? angle,
    int? turns,
  }) => CropSpec(
    zoom: zoom ?? this.zoom,
    cx: cx ?? this.cx,
    cy: cy ?? this.cy,
    angle: angle ?? this.angle,
    turns: turns ?? this.turns,
  );

  /// Un quart de tour de plus. Le redressement fin et la visée repartent de
  /// zéro : un cadrage pensé dans un sens n'a pas de sens dans l'autre.
  CropSpec turned() => CropSpec(turns: (turns + 1) % 4);

  /// Le plus grand rectangle du ratio [aspect] dans [wr]×[hr] (« remplir »).
  static (double, double) coverBox(double wr, double hr, double aspect) {
    if (wr / hr > aspect) return (hr * aspect, hr);
    return (wr, wr / aspect);
  }

  /// Le zoom auquel l'image entière tient dans le cadre (« adapter ») :
  /// toujours ≤ 1, = 1 quand l'image a exactement le ratio.
  static double fitZoom(double wr, double hr, double aspect) {
    final (w0, h0) = coverBox(wr, hr, aspect);
    return math.min(w0 / wr, h0 / hr).clamp(0.05, 1.0);
  }

  /// Le rectangle du cadre **dans un rectangle inscrit de [wr]×[hr]**
  /// (origine en haut à gauche de ce rectangle), pour un ratio [aspect].
  /// Quand le cadre tient dans l'image, il y reste entièrement (le centre
  /// est borné) ; quand il la dépasse (zoom < 1), il est centré sur elle.
  Rect rectWithin(double wr, double hr, double aspect) {
    final (w0, h0) = coverBox(wr, hr, aspect);
    final w = w0 / zoom;
    final h = h0 / zoom;
    final x = w >= wr ? (wr - w) / 2 : (cx * wr - w / 2).clamp(0.0, wr - w);
    final y = h >= hr ? (hr - h) / 2 : (cy * hr - h / 2).clamp(0.0, hr - h);
    return Rect.fromLTWH(x, y, w, h);
  }

  /// Le centre ramené dans la zone où le cadre reste entièrement dans le
  /// rectangle inscrit — ainsi `cx`/`cy` décrivent toujours ce qu'on voit, et
  /// un zoom arrière ne « saute » pas. Un axe où le cadre dépasse l'image
  /// revient au milieu.
  CropSpec clampedWithin(double wr, double hr, double aspect) {
    final r = copyWith(cx: 0.5, cy: 0.5).rectWithin(wr, hr, aspect);
    final halfW = r.width / 2 / wr;
    final halfH = r.height / 2 / hr;
    return copyWith(
      cx: halfW >= 0.5 ? 0.5 : cx.clamp(halfW, 1 - halfW),
      cy: halfH >= 0.5 ? 0.5 : cy.clamp(halfH, 1 - halfH),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CropSpec &&
      other.zoom == zoom &&
      other.cx == cx &&
      other.cy == cy &&
      other.angle == angle &&
      other.turns == turns;

  @override
  int get hashCode => Object.hash(zoom, cx, cy, angle, turns);
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
  VideoTrim normalized(int sourceMs, {int maxMs = kMaxFaceVideoMs}) {
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

/// Une face telle que choisie, et tout ce que l'utilisateur lui a fait —
/// cadrage, filtre, corrections, calques, découpe.
class MediaEdit {
  const MediaEdit({
    required this.id,
    required this.source,
    required this.isVideo,
    required this.srcWidth,
    required this.srcHeight,
    this.rotation = 0,
    this.durationMs,
    this.crop = CropSpec.none,
    this.filter = MediaFilter.normal,
    this.filterStrength = 1,
    this.adjust = ColorGrade.none,
    this.overlays = const [],
    this.trim,
  }) : assert(!isVideo || durationMs != null),
       assert(filterStrength >= 0 && filterStrength <= 1);

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
  final MediaFilter filter;

  /// L'intensité du filtre, 0 … 1 (Instagram : « appuyez à nouveau pour
  /// ajuster »). À 1 le filtre est entier, à 0 il ne fait rien.
  final double filterStrength;

  /// Les retouches posées PAR-DESSUS le filtre.
  final ColorGrade adjust;

  /// Les calques posés sur l'image — textes et autocollants — dans l'ordre
  /// de dessin (le dernier est au-dessus).
  final List<OverlayObject> overlays;

  /// Vidéo : le rognage ; nul = toute la source (si elle tient en 60 s).
  final VideoTrim? trim;

  /// Le réglage final : le filtre à son intensité, puis les retouches.
  ColorGrade get grade => adjust.over(filter.grade.scaled(filterStrength));

  /// Le rognage effectif d'une vidéo, dans les règles.
  VideoTrim get effectiveTrim =>
      (trim ?? VideoTrim(startMs: 0, endMs: math.max(1000, durationMs ?? 1000)))
          .normalized(durationMs ?? 1000);

  /// Le même média, lu depuis un autre fichier : quand un brouillon
  /// **adopte** la source (la déplace dans son dossier, 2026-09-20).
  MediaEdit withSource(File source) => MediaEdit(
    id: id,
    source: source,
    isVideo: isVideo,
    srcWidth: srcWidth,
    srcHeight: srcHeight,
    rotation: rotation,
    durationMs: durationMs,
    crop: crop,
    filter: filter,
    filterStrength: filterStrength,
    adjust: adjust,
    overlays: overlays,
    trim: trim,
  );

  MediaEdit copyWith({
    CropSpec? crop,
    MediaFilter? filter,
    double? filterStrength,
    ColorGrade? adjust,
    List<OverlayObject>? overlays,
    VideoTrim? trim,
  }) => MediaEdit(
    id: id,
    source: source,
    isVideo: isVideo,
    srcWidth: srcWidth,
    srcHeight: srcHeight,
    rotation: rotation,
    durationMs: durationMs,
    crop: crop ?? this.crop,
    filter: filter ?? this.filter,
    filterStrength: filterStrength ?? this.filterStrength,
    adjust: adjust ?? this.adjust,
    overlays: overlays ?? this.overlays,
    trim: trim ?? this.trim,
  );

  /// Remplace le calque de même identifiant ; l'ajoute s'il est nouveau.
  MediaEdit withOverlay(OverlayObject o) {
    final i = overlays.indexWhere((x) => x.id == o.id);
    final list = [...overlays];
    if (i < 0) {
      list.add(o);
    } else {
      list[i] = o;
    }
    return copyWith(overlays: list);
  }

  MediaEdit withoutOverlay(String id) =>
      copyWith(overlays: overlays.where((o) => o.id != id).toList());

  @override
  bool operator ==(Object other) =>
      other is MediaEdit &&
      other.id == id &&
      other.source.path == source.path &&
      other.isVideo == isVideo &&
      other.srcWidth == srcWidth &&
      other.srcHeight == srcHeight &&
      other.durationMs == durationMs &&
      other.crop == crop &&
      other.filter == filter &&
      other.filterStrength == filterStrength &&
      other.adjust == adjust &&
      _sameOverlays(other.overlays, overlays) &&
      other.trim == trim;

  static bool _sameOverlays(List<OverlayObject> a, List<OverlayObject> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

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
    filterStrength,
    adjust,
    Object.hashAll(overlays),
    trim,
  );
}
