import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

/// **Les calques posés sur un média** — un texte ou un autocollant — et rien
/// que leurs paramètres. Le dessin vit dans `overlay_painter.dart`, le même
/// pour l'aperçu, l'export photo et le calque brûlé dans la vidéo.
///
/// Tout est **relatif au cadre** (le média affiché à son ratio) : le centre en
/// fractions de la largeur et de la hauteur, la taille en fraction de la
/// largeur. Le même calque se dessine donc identiquement dans un aperçu de
/// 400 px et dans un export de 1080 px.
sealed class OverlayObject {
  const OverlayObject({
    required this.id,
    this.cx = 0.5,
    this.cy = 0.5,
    this.scale = 1,
    this.rotation = 0,
  });

  final String id;

  /// Le centre, en fractions du cadre (0,5 ; 0,5 = au milieu). Peut dépasser
  /// légèrement 0..1 : on laisse un calque sortir un peu du cadre, comme sur
  /// Instagram — mais jamais entièrement (voir [clamped]).
  final double cx;
  final double cy;

  /// 1 = la taille de départ ; pincer la change.
  final double scale;

  /// En radians, sens horaire à l'écran.
  final double rotation;

  static const minScale = 0.3;
  static const maxScale = 4.0;

  OverlayObject moved({
    double? cx,
    double? cy,
    double? scale,
    double? rotation,
  });

  /// Le centre ramené de sorte que la boîte du calque — [halfW]×[halfH]
  /// autour du centre, tournée de [rotation] — reste **entièrement dans le
  /// cadre** de [frameW]×[frameH]. Jay (2026-09-15) : *« le texte ne peut pas
  /// passer au-delà des limites du cadre, il est juste bloqué dans le
  /// déplacement mais pas reformaté »*. Un calque plus large que le cadre est
  /// centré sur cet axe.
  OverlayObject clampedTo({
    required double frameW,
    required double frameH,
    required double halfW,
    required double halfH,
  }) {
    // La boîte tournée : son enveloppe aux axes de l'écran.
    final c = math.cos(rotation).abs();
    final s = math.sin(rotation).abs();
    final hw = halfW * c + halfH * s;
    final hh = halfW * s + halfH * c;
    final minX = hw / frameW;
    final minY = hh / frameH;
    return moved(
      cx: minX >= 0.5 ? 0.5 : cx.clamp(minX, 1 - minX),
      cy: minY >= 0.5 ? 0.5 : cy.clamp(minY, 1 - minY),
    );
  }

  Offset center(double frameW, double frameH) =>
      Offset(cx * frameW, cy * frameH);

  /// L'application d'un geste : déplacement en pixels d'écran sur un cadre de
  /// [frameW]×[frameH], facteur de zoom, rotation ajoutée — puis la boîte
  /// ([halfW]×[halfH], APRÈS zoom) ramenée dans le cadre.
  OverlayObject gestured({
    required double frameW,
    required double frameH,
    required double halfW,
    required double halfH,
    Offset delta = Offset.zero,
    double scaleFactor = 1,
    double rotationDelta = 0,
  }) => moved(
    cx: cx + delta.dx / frameW,
    cy: cy + delta.dy / frameH,
    scale: (scale * scaleFactor).clamp(minScale, maxScale),
    rotation: rotation + rotationDelta,
  ).clampedTo(frameW: frameW, frameH: frameH, halfW: halfW, halfH: halfH);

  /// Un point d'écran est-il sur ce calque, dont la boîte non tournée est
  /// [halfW]×[halfH] autour du centre ? On ramène le point dans le repère du
  /// calque (rotation inverse) avant de comparer.
  bool hits(
    Offset p,
    double frameW,
    double frameH,
    double halfW,
    double halfH,
  ) {
    final c = center(frameW, frameH);
    final d = p - c;
    final cos = math.cos(-rotation);
    final sin = math.sin(-rotation);
    final x = cos * d.dx - sin * d.dy;
    final y = sin * d.dx + cos * d.dy;
    // Une marge de 12 px : un texte fin reste attrapable.
    return x.abs() <= halfW + 12 && y.abs() <= halfH + 12;
  }
}

/// Les polices proposées — dans l'esprit des styles d'Instagram, avec nos
/// deux familles (Fredoka, Figtree) et les familles système pour le reste.
enum OverlayFont {
  moderne('Moderne', 'Figtree', 700, null),
  rond('Rond', 'Fredoka', 600, null),
  classique('Classique', 'serif', 400, null),
  signature('Signature', 'cursive', 400, null),
  machine('Machine', 'monospace', 400, null),
  neon('Néon', 'Figtree', 700, 'neon');

  const OverlayFont(this.label, this.family, this.weight, this.effect);

  final String label;
  final String family;

  /// 100 … 900.
  final int weight;

  /// `neon` = un halo de la couleur du texte ; nul sinon.
  final String? effect;
}

/// Le fond derrière un texte : rien, un cartouche plein, ou translucide.
enum TextBackdrop { none, solid, translucent }

enum TextAlignment { left, center, right }

/// La palette de couleurs de texte — la même rangée pour tous.
abstract final class OverlayColors {
  static const swatches = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFFF5F5F5),
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF00C7BE),
    Color(0xFF007AFF),
    Color(0xFF5856D6),
    Color(0xFFAF52DE),
    Color(0xFFFF2D55),
    Color(0xFFA2845E),
    Color(0xFF8E8E93),
  ];
}

class TextOverlay extends OverlayObject {
  const TextOverlay({
    required super.id,
    required this.text,
    this.font = OverlayFont.moderne,
    this.color = const Color(0xFFFFFFFF),
    this.backdrop = TextBackdrop.none,
    this.alignment = TextAlignment.center,
    super.cx,
    super.cy,
    super.scale,
    super.rotation,
  });

  final String text;
  final OverlayFont font;
  final Color color;
  final TextBackdrop backdrop;
  final TextAlignment alignment;

  /// La taille de police de départ, en fraction de la largeur du cadre :
  /// 8 % de 1080 px = 86 px, une ligne bien lisible sur un téléphone.
  static const baseSizeRatio = 0.08;

  /// La largeur maximale d'un paragraphe, en fraction du cadre.
  static const maxWidthRatio = 0.9;

  TextOverlay copyWith({
    String? text,
    OverlayFont? font,
    Color? color,
    TextBackdrop? backdrop,
    TextAlignment? alignment,
    double? cx,
    double? cy,
    double? scale,
    double? rotation,
  }) => TextOverlay(
    id: id,
    text: text ?? this.text,
    font: font ?? this.font,
    color: color ?? this.color,
    backdrop: backdrop ?? this.backdrop,
    alignment: alignment ?? this.alignment,
    cx: cx ?? this.cx,
    cy: cy ?? this.cy,
    scale: scale ?? this.scale,
    rotation: rotation ?? this.rotation,
  );

  @override
  TextOverlay moved({
    double? cx,
    double? cy,
    double? scale,
    double? rotation,
  }) => copyWith(cx: cx, cy: cy, scale: scale, rotation: rotation);

  @override
  bool operator ==(Object other) =>
      other is TextOverlay &&
      other.id == id &&
      other.text == text &&
      other.font == font &&
      other.color == color &&
      other.backdrop == backdrop &&
      other.alignment == alignment &&
      other.cx == cx &&
      other.cy == cy &&
      other.scale == scale &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(
    id,
    text,
    font,
    color,
    backdrop,
    alignment,
    cx,
    cy,
    scale,
    rotation,
  );
}

/// Un autocollant : un émoji (dessiné comme un texte, en grand), ou une
/// image de la galerie (posée par-dessus).
class StickerOverlay extends OverlayObject {
  const StickerOverlay({
    required super.id,
    this.emoji,
    this.imagePath,
    super.cx,
    super.cy,
    super.scale,
    super.rotation,
  }) : assert((emoji == null) != (imagePath == null), 'un émoji OU une image');

  final String? emoji;

  /// Le fichier de l'image (temporaire, copié depuis la galerie).
  final String? imagePath;

  bool get isEmoji => emoji != null;

  /// Taille de départ, en fraction de la largeur du cadre.
  static const emojiSizeRatio = 0.22;
  static const imageWidthRatio = 0.45;

  StickerOverlay copyWith({
    double? cx,
    double? cy,
    double? scale,
    double? rotation,
  }) => StickerOverlay(
    id: id,
    emoji: emoji,
    imagePath: imagePath,
    cx: cx ?? this.cx,
    cy: cy ?? this.cy,
    scale: scale ?? this.scale,
    rotation: rotation ?? this.rotation,
  );

  @override
  StickerOverlay moved({
    double? cx,
    double? cy,
    double? scale,
    double? rotation,
  }) => copyWith(cx: cx, cy: cy, scale: scale, rotation: rotation);

  @override
  bool operator ==(Object other) =>
      other is StickerOverlay &&
      other.id == id &&
      other.emoji == emoji &&
      other.imagePath == imagePath &&
      other.cx == cx &&
      other.cy == cy &&
      other.scale == scale &&
      other.rotation == rotation;

  @override
  int get hashCode =>
      Object.hash(id, emoji, imagePath, cx, cy, scale, rotation);
}
