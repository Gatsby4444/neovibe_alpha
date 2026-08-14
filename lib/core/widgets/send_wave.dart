import 'package:flutter/material.dart';

/// La **vague rosée** qui balaie l'écran quand une Vibe part.
///
/// Demandée par Jay le 2026-08-14, d'après l'animation `color-splash` du
/// fichier Rive « Apple Intelligence » qu'il m'a montrée.
///
/// ## Ce n'est pas une interprétation : ce sont ses chiffres
///
/// Relevés un par un dans l'éditeur avant d'écrire une ligne — objet
/// `colorsplash`, animation `color-splash` (0,5 s) :
///
/// | Élément | Valeur dans Rive | Ici |
/// |---|---|---|
/// | Forme | ellipse 328 × 328, origine centrée | ovale, rayon proportionnel à l'écran |
/// | Dégradé | linéaire `#28ffffff` → `#fff55ac9` | identique |
/// | Flou (`Feather`) | force 20 | `MaskFilter.blur` proportionnel |
/// | Échelle | 0 → 300 % sur 18 images (300 ms) | 420 ms, puis dérive à 340 % |
/// | Opacité | 100 % jusqu'à l'image 7, puis 0 à l'image 26 | 360 ms → 1200 ms |
/// | Durée totale | 30 images à 60 i/s | **1200 ms** |
///
/// Les trois dernières lignes ont divergé le 2026-08-14 : Jay trouvait la
/// vague trop brève. Les proportions de Rive sont conservées, le temps non.
///
/// ## Pourquoi en Flutter et pas en Rive
///
/// Décision assumée, et réversible. Trois raisons :
///
/// 1. **C'est du vecteur pur** — une ellipse, deux arrêts de dégradé, un flou,
///    une échelle. Aucune image, aucun `Mesh`, aucun os. Il ne restait aucun
///    jugement de designer à préserver : j'ai lu une spécification, pas une
///    intention.
/// 2. **L'effet doit survivre à une navigation.** L'envoi dépile jusqu'à la
///    racine ; un `RiveWidget` monté dans l'écran d'envoi mourrait avec lui.
///    Cet overlay-ci vit dans l'`Overlay` racine et se moque de ce que fait le
///    `Navigator`.
/// 3. **Zéro asset, zéro aller-retour d'export.** Le fichier « Apple
///    Intelligence » porte six assets externes (`includeInExport: false`,
///    relevé dans l'éditeur) : le réutiliser tel quel aurait embarqué un
///    mockup de téléphone dont on n'a que faire, et des images qui ne se
///    chargeraient même pas.
///
/// Si Jay préfère la vraie ressource Rive, tout est prêt côté chiffres : il
/// suffit de rouvrir le fichier du bouton pour que j'y reconstruise la forme.
class SendWave {
  SendWave._();

  static OverlayEntry? _current;

  /// Rose du dégradé Rive (`#fff55ac9`).
  static const pink = Color(0xFFF55AC9);

  /// Joue la vague par-dessus tout, y compris pendant que l'écran d'envoi se
  /// dépile.
  ///
  /// `rootOverlay: true` est le point important : l'`Overlay` d'une route
  /// disparaît avec elle, celui de la racine non.
  static void play(BuildContext context) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _current?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _SendWaveView(
        onDone: () {
          if (_current == entry) _current = null;
          entry.remove();
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }
}

class _SendWaveView extends StatefulWidget {
  const _SendWaveView({required this.onDone});

  final VoidCallback onDone;

  @override
  State<_SendWaveView> createState() => _SendWaveViewState();
}

class _SendWaveViewState extends State<_SendWaveView>
    with SingleTickerProviderStateMixin {
  // Rive donnait 30 images à 60 i/s, soit 500 ms. Jay, 2026-08-14 : « la vague
  // est trop brève ». Portée à 1200 ms.
  //
  // Ce n'est PAS un simple ralenti : étirer les 500 ms d'origine aurait aussi
  // ralenti la détente initiale, et une vague qui s'ouvre mollement ne se lit
  // plus comme un envoi. Les deux temps sont donc découplés ci-dessous —
  // l'expansion reste vive, c'est la disparition qui prend le temps.
  late final _controller =
      AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1200),
        )
        ..addStatusListener((s) {
          // Retrait différé d'une image : ce rappel arrive pendant la phase de
          // ticks, avant le build. Retirer l'`OverlayEntry` à cet instant
          // revient à modifier l'arbre en cours de frame.
          if (s == AnimationStatus.completed) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => widget.onDone(),
            );
          }
        })
        ..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Échelle : 0 → 300 % sur les 35 % premiers (420 ms), en sortie douce comme
  /// les interpolateurs cubiques du fichier d'origine — puis une dérive lente
  /// jusqu'à 340 % sur le reste.
  ///
  /// La dérive est le détail qui compte : sans elle, la vague se fige à pleine
  /// taille et ne fait plus que s'effacer, ce qui se lit comme une image
  /// oubliée à l'écran plutôt que comme un mouvement qui se termine.
  double _scale(double t) {
    const grow = 0.35;
    if (t <= grow) {
      return 3.0 * Curves.easeOutCubic.transform(t / grow);
    }
    final p = ((t - grow) / (1 - grow)).clamp(0.0, 1.0);
    return 3.0 + 0.4 * Curves.easeOutSine.transform(p);
  }

  /// Opacité : pleine sur les 30 premiers % (360 ms), puis fondu jusqu'à zéro
  /// sur les 840 ms restantes. C'est ici que se joue la durée ressentie.
  double _opacity(double t) {
    const hold = 0.30;
    if (t <= hold) return 1;
    final p = ((t - hold) / (1 - hold)).clamp(0.0, 1.0);
    return 1 - Curves.easeInCubic.transform(p);
  }

  @override
  Widget build(BuildContext context) {
    // Purement décoratif : il ne doit intercepter aucun geste, sinon le premier
    // demi-seconde après un envoi serait un écran mort.
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return CustomPaint(
            size: Size.infinite,
            painter: _WavePainter(scale: _scale(t), opacity: _opacity(t)),
          );
        },
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({required this.scale, required this.opacity});

  final double scale;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (scale <= 0 || opacity <= 0) return;

    // L'ellipse d'origine fait 328 px sur un artboard de ~360 de large, donc un
    // peu plus de 90 % de la largeur. On garde ce rapport plutôt qu'un nombre
    // de pixels, sinon l'effet serait deux fois plus petit sur une tablette.
    final base = size.shortestSide * 0.91;
    final radius = base * scale / 2;
    final center = Offset(size.width / 2, size.height * 0.62);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final paint = Paint()
      ..shader = const LinearGradient(
        // Les deux arrêts du dégradé de Jay, dans le même sens (le rose arrive
        // par la gauche, comme le `startX` négatif de la fin d'animation).
        begin: Alignment.centerRight,
        end: Alignment.centerLeft,
        colors: [Color(0x28FFFFFF), SendWave.pink],
      ).createShader(rect)
      // Le `Feather` de force 20 sur une ellipse de 328 : ~6 % du diamètre.
      // Proportionnel, pour la même raison que le rayon.
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.12);

    canvas.saveLayer(
      Offset.zero & size,
      Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
    );
    canvas.drawOval(rect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.scale != scale || old.opacity != opacity;
}
