import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Recadrage **carré** d'une photo de profil : on déplace et on zoome, le
/// cadre ne bouge pas.
///
/// ### Pourquoi c'est écrit ici et pas pris dans un paquet
///
/// Il existe des paquets de recadrage tout faits. Ils sont écartés, et la
/// raison vient de la voie produit donnée par Jay le 2026-08-13 : *« contrôle
/// total de l'écosystème de l'app — ce qui se passe sur NeoVibe reste sur
/// NeoVibe »*. Un recadreur tiers **voit la photo**, souvent en la faisant
/// transiter par une activité native et un fichier temporaire qui ne nous
/// appartient pas. Pour une photo de visage, c'est exactement le genre de
/// sortie qu'on ne veut pas ouvrir — et une dépendance qui verrait passer un
/// contenu en clair est disqualifiée par principe.
///
/// Le coût est modeste : un carré, un déplacement, un zoom. Le bénéfice est
/// qu'aucun octet ne quitte notre code, et que le portage iOS n'aura rien à
/// reconfigurer côté natif.
///
/// ### Pourquoi un recadrage tout court
///
/// Un avatar s'affiche **rond**, partout dans l'app. Sans recadrage, une photo
/// en 3:4 est rognée par le centre géométrique — qui n'est presque jamais le
/// visage. C'est la différence entre « ça marche » et « c'est soigné », et le
/// design premium demandé se joue exactement là.
class AvatarCropperScreen extends StatefulWidget {
  const AvatarCropperScreen({super.key, required this.source});

  /// La photo choisie, telle que rendue par l'appareil ou la galerie.
  final File source;

  @override
  State<AvatarCropperScreen> createState() => _AvatarCropperScreenState();
}

class _AvatarCropperScreenState extends State<AvatarCropperScreen> {
  /// Côté de l'image produite, en pixels. 512 : très au-delà de la plus grande
  /// taille d'affichage (56 px de rayon dans le bandeau des stories), et assez
  /// petit pour que le fichier reste léger sur un réseau mobile.
  static const _output = 512;

  ui.Image? _image;
  String? _error;

  /// Facteur d'échelle appliqué à l'image source pour l'affichage.
  double _scale = 1;

  /// Coin haut-gauche de l'image affichée, relatif à celui du cadre.
  Offset _offset = Offset.zero;

  /// Côté du cadre à l'écran, connu seulement au premier `layout`.
  double _frame = 0;

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

  /// Pose l'image de façon à **couvrir** le cadre, centrée. C'est l'état de
  /// départ, et celui vers lequel toute contrainte ramène.
  void _fit(double frame) {
    final image = _image;
    if (image == null || frame <= 0) return;
    _frame = frame;
    _scale = frame / _shortestSide(image);
    _offset = Offset(
      (frame - image.width * _scale) / 2,
      (frame - image.height * _scale) / 2,
    );
  }

  double _shortestSide(ui.Image image) => image.width < image.height
      ? image.width.toDouble()
      : image.height.toDouble();

  /// Empêche le cadre de déborder de l'image : pas de bande vide sur un avatar.
  ///
  /// C'est une contrainte, pas une correction esthétique — une zone vide dans
  /// le carré donnerait un avatar au bord transparent, que rien n'irait
  /// rattraper ensuite.
  void _clamp() {
    final image = _image;
    if (image == null || _frame <= 0) return;
    final minScale = _frame / _shortestSide(image);
    _scale = _scale.clamp(minScale, minScale * 6);
    final width = image.width * _scale;
    final height = image.height * _scale;
    _offset = Offset(
      _offset.dx.clamp(_frame - width, 0.0),
      _offset.dy.clamp(_frame - height, 0.0),
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

  /// Rend le carré visible, à [_output] pixels de côté.
  ///
  /// Le rectangle source est obtenu en **remontant** la transformation
  /// d'affichage : ce que l'utilisateur voit dans le cadre est exactement ce
  /// qui est écrit.
  Future<Uint8List?> _render() async {
    final image = _image;
    if (image == null || _frame <= 0) return null;

    final src = Rect.fromLTWH(
      -_offset.dx / _scale,
      -_offset.dy / _scale,
      _frame / _scale,
      _frame / _scale,
    );

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      src,
      Rect.fromLTWH(0, 0, _output.toDouble(), _output.toDouble()),
      ui.Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(_output, _output);
    picture.dispose();
    // PNG : `toByteData` ne sait pas encoder en JPEG. Un carré de 512 px reste
    // léger, et c'est du sans perte sur un visage déjà réduit.
    final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    return data?.buffer.asUint8List();
  }

  Future<void> _validate() async {
    setState(() => _saving = true);
    final bytes = await _render();
    if (!mounted) return;
    if (bytes == null) {
      setState(() {
        _saving = false;
        _error = 'Le recadrage a échoué.';
      });
      return;
    }
    Navigator.of(context).pop(bytes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Recadrer', style: TextStyle(fontSize: 16)),
        actions: [
          if (_image != null && !_saving)
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
        final side = constraints.maxWidth < constraints.maxHeight
            ? constraints.maxWidth
            : constraints.maxHeight;
        final frame = side - 40;
        // Première mesure : on pose l'image. Les suivantes (rotation, clavier)
        // ne doivent PAS réinitialiser le cadrage que l'utilisateur a réglé.
        if (_frame != frame) {
          _fit(frame);
        }
        return SizedBox(
          width: frame,
          height: frame,
          child: GestureDetector(
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            child: ClipOval(
              child: CustomPaint(
                painter: _CropPainter(
                  image: _image!,
                  scale: _scale,
                  offset: _offset,
                ),
                size: Size(frame, frame),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Dessine l'image à l'échelle et à la position courantes.
///
/// L'aperçu est **rond** parce que l'avatar l'est : montrer un carré puis
/// afficher un cercle, c'est laisser l'utilisateur cadrer sur autre chose que
/// ce qu'il verra. L'image produite, elle, reste carrée — c'est le conteneur
/// qui arrondit, partout dans l'app.
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
