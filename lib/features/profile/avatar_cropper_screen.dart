import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/widgets/image_cropper_screen.dart';

/// Recadrage **carré** d'une photo de profil, aperçu rond — l'écran commun
/// ([ImageCropperScreen]) réglé pour l'avatar. Rend un PNG de 512 px.
///
/// ### Pourquoi un recadrage tout court
///
/// Un avatar s'affiche **rond**, partout dans l'app. Sans recadrage, une photo
/// en 3:4 est rognée par le centre géométrique — qui n'est presque jamais le
/// visage. C'est la différence entre « ça marche » et « c'est soigné », et le
/// design premium demandé se joue exactement là.
class AvatarCropperScreen extends StatelessWidget {
  const AvatarCropperScreen({super.key, required this.source});

  /// La photo choisie, telle que rendue par l'appareil ou la galerie.
  final File source;

  /// Côté de l'image produite, en pixels. 512 : très au-delà de la plus grande
  /// taille d'affichage (56 px de rayon dans le bandeau des stories), et assez
  /// petit pour que le fichier reste léger sur un réseau mobile.
  static const _output = 512;

  @override
  Widget build(BuildContext context) => ImageCropperScreen<Uint8List>(
    source: source,
    aspect: 1,
    oval: true,
    produce: _render,
  );

  static Future<Uint8List> _render(ui.Image image, Rect src) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
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
    if (data == null) throw StateError('Recadrage illisible');
    return data.buffer.asUint8List();
  }
}
