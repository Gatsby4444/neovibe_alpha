import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/widgets/image_cropper_screen.dart';

/// Le recadrage commun (2026-09-25) : ce qu'on voit dans le cadre est
/// exactement le rectangle rendu à [ImageCropperScreen.produce].
void main() {
  late File source;

  setUpAll(() async {
    // Une image 400 × 200, plus large que l'affiche.
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 400, 200),
      ui.Paint()..color = Colors.orange,
    );
    final image = await recorder.endRecording().toImage(400, 200);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = await Directory.systemTemp.createTemp('cropper');
    source = File('${dir.path}/source.png');
    await source.writeAsBytes(png!.buffer.asUint8List());
  });

  Future<Rect?> crop(WidgetTester tester, {Offset drag = Offset.zero}) async {
    Rect? got;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ImageCropperScreen<int>(
            source: source,
            aspect: 3 / 4,
            produce: (image, src) async {
              got = src;
              return 1;
            },
          ),
        ),
      );
      // Le décodage est asynchrone, hors horloge de test.
      for (var i = 0; i < 20 && find.text('Valider').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    if (drag != Offset.zero) {
      await tester.drag(
        find.byWidgetPredicate(
          (w) => w is GestureDetector && w.onScaleUpdate != null,
        ),
        drag,
      );
      await tester.pump();
    }
    await tester.tap(find.text('Valider'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    return got;
  }

  testWidgets('au départ : le 3:4 central, qui couvre la hauteur', (
    tester,
  ) async {
    final r = (await crop(tester))!;
    expect(r.width / r.height, closeTo(0.75, 1e-6));
    expect(r.height, closeTo(200, 1e-6));
    expect(r.left, closeTo((400 - 150) / 2, 1e-6));
    expect(r.top, closeTo(0, 1e-6));
  });

  testWidgets("glisser vers la droite montre la gauche de l'image", (
    tester,
  ) async {
    final r = (await crop(tester, drag: const Offset(2000, 0)))!;
    expect(r.width / r.height, closeTo(0.75, 1e-6));
    // Butée : jamais de bande vide, le cadre s'arrête au bord gauche.
    expect(r.left, closeTo(0, 1e-6));
  });
}
