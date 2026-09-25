import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'system_bars.dart';

/// **Recadrer une image** : on déplace et on zoome, le cadre ne bouge pas.
///
/// Un seul écran pour tous les recadrages de l'app (2026-09-25) — la photo de
/// profil (carré, aperçu rond) et l'affiche d'une soirée (3:4). Deux copies,
/// c'est une correction sur deux ; seuls changent la forme du cadre et ce
/// qu'on fabrique du rectangle choisi ([produce]).
///
/// ### Pourquoi c'est écrit ici et pas pris dans un paquet
///
/// Voie produit de Jay, 2026-08-13 : *« ce qui se passe sur NeoVibe reste sur
/// NeoVibe »*. Un recadreur tiers **voit l'image**, souvent en la faisant
/// transiter par une activité native et un fichier temporaire qui ne nous
/// appartient pas. Ici, aucun octet ne quitte notre code, et le portage iOS
/// n'a rien à reconfigurer côté natif.
///
/// L'écran rend ce que [produce] fabrique, ou nul si l'on renonce.
class ImageCropperScreen<T> extends StatefulWidget {
  const ImageCropperScreen({
    super.key,
    required this.source,
    required this.aspect,
    required this.produce,
    this.oval = false,
    this.decodeWidth,
  });

  /// L'image choisie, telle que rendue par l'appareil ou la galerie.
  final File source;

  /// Largeur / hauteur du cadre (1 = carré, 3/4 = affiche).
  final double aspect;

  /// Aperçu **rond** : quand le résultat s'affichera rond partout (avatar).
  /// Montrer un carré puis afficher un cercle, c'est laisser cadrer sur
  /// autre chose que ce qu'on verra. L'image produite reste rectangulaire.
  final bool oval;

  /// Largeur de décodage ; nulle = pleine résolution (le zoom reste net).
  final int? decodeWidth;

  /// Fabrique le résultat à partir de l'image décodée et du rectangle
  /// choisi, **en pixels de cette image**.
  final Future<T> Function(ui.Image image, Rect src) produce;

  @override
  State<ImageCropperScreen<T>> createState() => _ImageCropperScreenState<T>();
}

class _ImageCropperScreenState<T> extends State<ImageCropperScreen<T>> {
  ui.Image? _image;
  String? _error;

  /// Facteur d'échelle appliqué à l'image source pour l'affichage.
  double _scale = 1;

  /// Coin haut-gauche de l'image affichée, relatif à celui du cadre.
  Offset _offset = Offset.zero;

  /// Taille du cadre à l'écran, connue seulement au premier `layout`.
  Size _frame = Size.zero;

  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  var _saving = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(
        await widget.source.readAsBytes(),
        targetWidth: widget.decodeWidth,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// L'échelle la plus petite qui **couvre** le cadre.
  double _coverScale(ui.Image image) {
    final sx = _frame.width / image.width;
    final sy = _frame.height / image.height;
    return sx > sy ? sx : sy;
  }

  /// Pose l'image de façon à couvrir le cadre, centrée. C'est l'état de
  /// départ, et celui vers lequel toute contrainte ramène.
  void _fit(Size frame) {
    final image = _image;
    if (image == null || frame.isEmpty) return;
    _frame = frame;
    _scale = _coverScale(image);
    _offset = Offset(
      (frame.width - image.width * _scale) / 2,
      (frame.height - image.height * _scale) / 2,
    );
  }

  /// Empêche le cadre de déborder de l'image : pas de bande vide.
  ///
  /// C'est une contrainte, pas une correction esthétique — une zone vide
  /// dans le cadre finirait dans l'image produite, que rien n'irait
  /// rattraper ensuite.
  void _clamp() {
    final image = _image;
    if (image == null || _frame.isEmpty) return;
    final minScale = _coverScale(image);
    _scale = _scale.clamp(minScale, minScale * 6);
    final width = image.width * _scale;
    final height = image.height * _scale;
    _offset = Offset(
      _offset.dx.clamp(_frame.width - width, 0.0),
      _offset.dy.clamp(_frame.height - height, 0.0),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      // Le point sous les doigts reste sous les doigts : on zoome AUTOUR de
      // lui, et non autour du coin de l'image.
      final scale = _startScale * details.scale;
      final anchor = (_startFocal - _startOffset) / _startScale;
      _scale = scale;
      _offset = details.localFocalPoint - anchor * scale;
      _clamp();
    });
  }

  /// Le rectangle choisi, en pixels de l'image — obtenu en **remontant** la
  /// transformation d'affichage : ce qu'on voit dans le cadre est exactement
  /// ce qui est produit.
  Rect _sourceRect() => Rect.fromLTWH(
    -_offset.dx / _scale,
    -_offset.dy / _scale,
    _frame.width / _scale,
    _frame.height / _scale,
  );

  Future<void> _validate() async {
    final image = _image;
    if (image == null || _frame.isEmpty) return;
    setState(() => _saving = true);
    try {
      final result = await widget.produce(image, _sourceRect());
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Le recadrage a échoué.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        systemOverlayStyle: kSystemBarsOnDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Recadrer', style: TextStyle(fontSize: 16)),
        actions: [
          if (_image != null && !_saving && _error == null)
            TextButton(onPressed: _validate, child: const Text('Valider')),
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  'Impossible d\'ouvrir cette image.\n$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            )
          : _image == null
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white24),
            )
          : Column(
              children: [
                Expanded(child: Center(child: _viewport())),
                const Padding(
                  padding: EdgeInsets.fromLTRB(32, 0, 32, 28),
                  child: Text(
                    'Déplace et pince pour zoomer.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _viewport() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Le plus grand cadre de la bonne forme, avec 20 px de marge.
        final maxW = constraints.maxWidth - 40;
        final maxH = constraints.maxHeight - 40;
        final frame = maxW / maxH > widget.aspect
            ? Size(maxH * widget.aspect, maxH)
            : Size(maxW, maxW / widget.aspect);
        // Première mesure : on pose l'image. Les suivantes (rotation, clavier)
        // ne doivent PAS réinitialiser le cadrage que l'utilisateur a réglé.
        if (_frame != frame) _fit(frame);
        final paint = CustomPaint(
          painter: _CropPainter(image: _image!, scale: _scale, offset: _offset),
          size: frame,
        );
        return SizedBox.fromSize(
          size: frame,
          child: GestureDetector(
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            child: widget.oval
                ? ClipOval(child: paint)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: paint,
                  ),
          ),
        );
      },
    );
  }
}

/// Dessine l'image à l'échelle et à la position courantes.
class _CropPainter extends CustomPainter {
  const _CropPainter({
    required this.image,
    required this.scale,
    required this.offset,
  });

  final ui.Image image;
  final double scale;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      // Écran de recadrage : sombre dans les deux thèmes, mais gris neutre.
      Paint()..color = NeoNeutrals.gray900,
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(
        offset.dx,
        offset.dy,
        image.width * scale,
        image.height * scale,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.scale != scale || old.offset != offset;
}
