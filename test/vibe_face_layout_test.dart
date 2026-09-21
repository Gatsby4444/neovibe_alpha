import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/core/widgets/vibe_face.dart';

/// Ce que ce test défend : **la hauteur d'une face ne dépend jamais de ce
/// qui est chargé.** Constaté chez Jay le 2026-09-15 : la face photo prenait
/// la hauteur de l'image une fois décodée, donc zéro avant — dans un fil,
/// retourner une Card écrasait la cellule le temps d'une image, la Card
/// suivante passait sous le doigt et la liste remontait d'une Card. Aucune
/// erreur levée : ça se mesure.
void main() {
  const width = 240.0;

  Future<Size> sizeOf(WidgetTester tester, Widget face) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(width: width, child: face),
        ),
      ),
    );
    // Une seule image pompée : on mesure la hauteur AVANT tout décodage.
    return tester.getSize(find.byWidget(face));
  }

  testWidgets('en attente et photo pas encore décodée : la même hauteur', (
    tester,
  ) async {
    const type = CardType.standard;
    final loading = await sizeOf(tester, const VibeFaceLoading(type: type));
    // Des octets qui ne sont pas une image : le décodage échouera plus tard ;
    // avant, la face doit déjà avoir sa hauteur.
    final photo = await sizeOf(
      tester,
      VibePhotoFace(bytes: Uint8List.fromList([1, 2, 3]), type: type),
    );
    expect(photo.height, loading.height);

    // Et c'est bien le portrait 9:16, cadre compris (marge 16, liseré 2.5
    // pour une standard — voir VibeFaceFrame).
    const chrome = 2 * 16 + 2 * 2.5;
    expect(
      loading.height,
      closeTo((width - chrome) / kVibeFaceRatio + chrome, 0.5),
    );
  });

  test('recadrer, c\'est montrer MOINS — pas des bandes noires', () {
    // À son format, rien n'est coupé ; à un autre, on coupe.
    expect(fitForRatio(kVibeFaceRatio), BoxFit.contain);
    expect(fitForRatio(4 / 5), BoxFit.cover);
  });
}
