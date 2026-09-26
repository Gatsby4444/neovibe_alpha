import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/events/map_markers.dart';

/// Les repères de la carte (2026-09-26) : le rond de profil, avec ou sans
/// photo, avec ou sans cône.
void main() {
  test('les initiales : deux mots au plus, en majuscules', () {
    expect(MapMarkers.initiales('jay bonnet'), 'JB');
    expect(MapMarkers.initiales('  Inès  '), 'I');
    expect(MapMarkers.initiales('a b c'), 'AB');
    expect(MapMarkers.initiales(''), '');
  });

  test(
    'un rond se dessine, avec photo et cône, à la densité demandée',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 40, 60),
        ui.Paint()..color = Colors.orange,
      );
      final photo = await recorder.endRecording().toImage(40, 60);
      final png = await MapMarkers.rond(
        dpr: 2,
        cote: 76,
        rayon: 17,
        anneau: Colors.blue,
        fond: Colors.black,
        photo: photo,
        cone: true,
      );
      final codec = await ui.instantiateImageCodec(png);
      final image = (await codec.getNextFrame()).image;
      expect(image.width, 152);
      expect(image.height, 152);
    },
  );

  test('sans photo : les initiales, sans erreur', () async {
    final png = await MapMarkers.rond(
      dpr: 1,
      cote: 40,
      rayon: 16,
      anneau: Colors.blue,
      fond: Colors.black,
      initiales: 'JB',
    );
    expect(png, isNotEmpty);
  });
}
