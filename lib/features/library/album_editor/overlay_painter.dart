import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'overlay_model.dart';

/// **Le dessin des calques, une seule fois** : l'aperçu, l'export photo et le
/// calque brûlé dans la vidéo passent tous par [paintAll]. Ce qui change
/// entre eux, c'est la taille du cadre — jamais la façon de dessiner.
///
/// Les images d'autocollants sont fournies par [images] (chemin → image
/// décodée) : le peintre ne lit aucun fichier.
class OverlayPainter {
  const OverlayPainter({required this.images});

  final ui.Image? Function(String path) images;

  /// Dessine tous les [overlays] sur [canvas], dans un cadre de [size].
  void paintAll(Canvas canvas, Size size, List<OverlayObject> overlays) {
    for (final o in overlays) {
      paintOne(canvas, size, o);
    }
  }

  void paintOne(Canvas canvas, Size size, OverlayObject o) {
    final c = o.center(size.width, size.height);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(o.rotation);
    switch (o) {
      case TextOverlay():
        _paintText(canvas, size, o);
      case StickerOverlay():
        _paintSticker(canvas, size, o);
    }
    canvas.restore();
  }

  /// La demi-boîte (non tournée) d'un calque dans un cadre de [size], pour
  /// l'attraper au doigt.
  Size halfBox(Size size, OverlayObject o) => switch (o) {
    TextOverlay() => () {
      final tp = _textPainter(size, o);
      return Size(tp.width / 2, tp.height / 2);
    }(),
    StickerOverlay() => _stickerSize(size, o) / 2,
  };

  // ── Texte ───────────────────────────────────────────────────────────

  /// Le style d'un texte à une taille donnée — **le même** pour le peintre
  /// (aperçu, export) et pour le champ de saisie posé sur l'image.
  static TextStyle textStyle(TextOverlay o, double fontSize) => TextStyle(
    fontFamily: o.font.family,
    fontFamilyFallback: const ['Figtree', 'Roboto', 'sans-serif'],
    fontWeight: FontWeight.values[(o.font.weight ~/ 100 - 1).clamp(0, 8)],
    fontSize: fontSize,
    height: 1.15,
    color: o.color,
    shadows: o.font.effect == 'neon'
        ? [
            Shadow(color: o.color, blurRadius: fontSize * 0.35),
            Shadow(color: o.color, blurRadius: fontSize * 0.7),
          ]
        : null,
  );

  TextPainter _textPainter(Size size, TextOverlay o) {
    final fontSize = TextOverlay.baseSizeRatio * size.width * o.scale;
    final style = textStyle(o, fontSize);
    return TextPainter(
      text: TextSpan(text: o.text, style: style),
      textAlign: switch (o.alignment) {
        TextAlignment.left => TextAlign.left,
        TextAlignment.center => TextAlign.center,
        TextAlignment.right => TextAlign.right,
      },
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: TextOverlay.maxWidthRatio * size.width);
  }

  void _paintText(Canvas canvas, Size size, TextOverlay o) {
    final tp = _textPainter(size, o);
    final origin = Offset(-tp.width / 2, -tp.height / 2);
    if (o.backdrop != TextBackdrop.none) {
      // Un cartouche PAR LIGNE, comme Instagram : la couleur du fond est
      // l'inverse du texte (blanc sur noir, noir sur blanc), pleine ou à 45 %.
      final dark = o.color.computeLuminance() > 0.5;
      final fill = (dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF))
          .withValues(alpha: o.backdrop == TextBackdrop.solid ? 1 : 0.45);
      final pad = tp.preferredLineHeight * 0.18;
      final paint = Paint()..color = fill;
      for (final line in tp.computeLineMetrics()) {
        if (line.width <= 0) continue;
        final top = line.baseline - line.ascent;
        final rect = Rect.fromLTWH(
          origin.dx + line.left - pad,
          origin.dy + top - pad * 0.4,
          line.width + pad * 2,
          line.height + pad * 0.8,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(pad * 1.2)),
          paint,
        );
      }
    }
    tp.paint(canvas, origin);
  }

  // ── Autocollants ────────────────────────────────────────────────────

  Size _stickerSize(Size size, StickerOverlay o) {
    if (o.isEmoji) {
      final s = StickerOverlay.emojiSizeRatio * size.width * o.scale;
      return Size(s, s);
    }
    final img = images(o.imagePath!);
    final w = StickerOverlay.imageWidthRatio * size.width * o.scale;
    if (img == null) return Size(w, w);
    return Size(w, w * img.height / img.width);
  }

  void _paintSticker(Canvas canvas, Size size, StickerOverlay o) {
    final box = _stickerSize(size, o);
    if (o.isEmoji) {
      final tp = TextPainter(
        text: TextSpan(
          text: o.emoji,
          style: TextStyle(fontSize: box.width * 0.82, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      return;
    }
    final img = images(o.imagePath!);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: box.width,
      height: box.height,
    );
    if (img == null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        Paint()..color = const Color(0x33FFFFFF),
      );
      return;
    }
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  /// Le premier calque (du dessus vers le dessous) sous le point [p].
  OverlayObject? hitTest(Size size, List<OverlayObject> overlays, Offset p) {
    for (final o in overlays.reversed) {
      final half = halfBox(size, o);
      if (o.hits(p, size.width, size.height, half.width, half.height)) {
        return o;
      }
    }
    return null;
  }

  /// Le cadre qui entoure un calque sélectionné (pour le dessiner à l'écran).
  Path selectionPath(Size size, OverlayObject o) {
    final half = halfBox(size, o);
    final c = o.center(size.width, size.height);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: half.width * 2 + 12,
      height: half.height * 2 + 12,
    );
    final m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..rotateZ(o.rotation);
    return Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)))
      ..transform(m.storage);
  }
}

/// Le calque de sélection et le geste en cours : dessiné par l'écran,
/// jamais exporté.
class OverlayChromePainter extends CustomPainter {
  const OverlayChromePainter({
    required this.painter,
    required this.selected,
    this.color = const Color(0xFFFFFFFF),
  });

  final OverlayPainter painter;
  final OverlayObject? selected;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = selected;
    if (s == null) return;
    canvas.drawPath(
      painter.selectionPath(size, s),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(OverlayChromePainter old) => old.selected != selected;
}

/// Tous les calques d'un média, dessinés dans le cadre (aperçu).
class OverlaysPainter extends CustomPainter {
  const OverlaysPainter({required this.painter, required this.overlays});

  final OverlayPainter painter;
  final List<OverlayObject> overlays;

  @override
  void paint(Canvas canvas, Size size) =>
      painter.paintAll(canvas, size, overlays);

  @override
  bool shouldRepaint(OverlaysPainter old) {
    if (old.overlays.length != overlays.length) return true;
    for (var i = 0; i < overlays.length; i++) {
      if (old.overlays[i] != overlays[i]) return true;
    }
    return false;
  }
}

/// Un angle ramené dans ]−π, π].
double normalizeAngle(double a) {
  var r = a % (2 * math.pi);
  if (r > math.pi) r -= 2 * math.pi;
  return r;
}
