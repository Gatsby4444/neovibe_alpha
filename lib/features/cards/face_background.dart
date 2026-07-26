import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Fond d'une face de card : couleur unie **ou** dégradé (consigne Jay
/// 2026-07-26, en remplacement du seul fond noir de la « face tableau »).
///
/// Il sert à deux endroits, et c'est volontairement la même notion :
/// - **face entièrement colorée** : un appui court sur le bouton couleur pose
///   une face de cette couleur, à dessiner et annoter à l'étape suivante ;
/// - **fond derrière une photo** qui ne remplit pas le format 9:16 (import
///   galerie en mode « adapter »), là où le noir était imposé.
@immutable
class FaceBackground {
  const FaceBackground({
    required this.name,
    required this.color,
    this.gradient,
  });

  /// Libellé court (accessibilité, journal).
  final String name;

  /// Couleur unie, ou couleur représentative du dégradé (pastille du bouton).
  final Color color;

  /// Non nul = dégradé.
  final LinearGradient? gradient;

  bool get isGradient => gradient != null;

  /// Décoration prête à peindre (pastille de la palette, aperçu, fond).
  BoxDecoration get decoration =>
      BoxDecoration(color: gradient == null ? color : null, gradient: gradient);

  static const black = FaceBackground(name: 'Noir', color: Color(0xFF000000));

  /// Palette proposée à l'appui long. Unis d'abord, dégradés ensuite — dans
  /// le registre Instagram, comme demandé.
  static const palette = <FaceBackground>[
    black,
    FaceBackground(name: 'Blanc', color: Color(0xFFFFFFFF)),
    FaceBackground(name: 'Gris', color: Color(0xFF6E6E78)),
    FaceBackground(name: 'Rouge', color: Color(0xFFC8102E)),
    FaceBackground(name: 'Orange', color: Color(0xFFFF7A1A)),
    FaceBackground(name: 'Jaune', color: Color(0xFFFFD60A)),
    FaceBackground(name: 'Vert', color: Color(0xFF7ED957)),
    FaceBackground(name: 'Turquoise', color: Color(0xFF40E0D0)),
    FaceBackground(name: 'Bleu', color: Color(0xFF2979FF)),
    FaceBackground(name: 'Violet', color: Color(0xFF7B2FF7)),
    FaceBackground(name: 'Rose', color: Color(0xFFE1306C)),
    FaceBackground(name: 'Or', color: Color(0xFFD4AF37)),
    FaceBackground(
      name: 'Coucher',
      color: Color(0xFFD62976),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFEDA75), Color(0xFFFA7E1E), Color(0xFFD62976)],
      ),
    ),
    FaceBackground(
      name: 'Néon',
      color: Color(0xFF962FBF),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF7B2FF7), Color(0xFFF107A3)],
      ),
    ),
    FaceBackground(
      name: 'Océan',
      color: Color(0xFF2979FF),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF4F5BD5), Color(0xFF2979FF), Color(0xFF40E0D0)],
      ),
    ),
    FaceBackground(
      name: 'Braise',
      color: Color(0xFFC8102E),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFC8102E), Color(0xFFFF7A1A), Color(0xFFFFD60A)],
      ),
    ),
    FaceBackground(
      name: 'Nuit',
      color: Color(0xFF15131C),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF0B0A10), Color(0xFF2A2140), Color(0xFF4F5BD5)],
      ),
    ),
  ];

  /// Fabrique le fichier d'une face entièrement remplie par ce fond, au format
  /// unifié des cards (900×1600).
  Future<File> render() async {
    const width = 900.0, height = 1600.0;
    const rect = ui.Rect.fromLTWH(0, 0, width, height);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint();
    if (gradient != null) {
      paint.shader = gradient!.createShader(rect);
    } else {
      paint.color = color;
    }
    canvas.drawRect(rect, paint);
    final image = await recorder.endRecording().toImage(
      width.toInt(),
      height.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(
      '${Directory.systemTemp.path}/board_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    return file;
  }
}

/// Palette de fonds, ouverte par un **appui long** sur le bouton couleur.
///
/// Animation : le panneau naît du bouton (coin bas-droit) en grandissant, et
/// chaque pastille entre en décalé — c'est le « dynamique » demandé, obtenu
/// sans dépendance : un `AnimationController` et des `Interval`.
Future<FaceBackground?> showFaceBackgroundPalette(
  BuildContext context, {
  required FaceBackground current,
}) {
  return showGeneralDialog<FaceBackground>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fermer la palette',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (context, animation, _) =>
        _PalettePanel(animation: animation, current: current),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: curved,
          // Le panneau grandit depuis le bouton, en bas à droite.
          alignment: Alignment.bottomRight,
          child: child,
        ),
      );
    },
  );
}

class _PalettePanel extends StatelessWidget {
  const _PalettePanel({required this.animation, required this.current});

  final Animation<double> animation;
  final FaceBackground current;

  @override
  Widget build(BuildContext context) {
    const items = FaceBackground.palette;
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 16, bottom: 120, left: 24),
        child: Material(
          color: const Color(0xFF15131C),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Fond de la face',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var i = 0; i < items.length; i++)
                      _Swatch(
                        background: items[i],
                        selected: items[i].name == current.name,
                        // Entrée en cascade : chaque pastille démarre un peu
                        // après la précédente, sur la 2e moitié de l'animation.
                        animation: CurvedAnimation(
                          parent: animation,
                          curve: Interval(
                            (i / items.length) * 0.5,
                            0.5 + (i / items.length) * 0.5,
                            curve: Curves.easeOutBack,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(items[i]),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.background,
    required this.selected,
    required this.animation,
    required this.onTap,
  });

  final FaceBackground background;
  final bool selected;
  final Animation<double> animation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: animation,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: background.decoration.copyWith(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : Colors.white24,
              width: selected ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }
}
