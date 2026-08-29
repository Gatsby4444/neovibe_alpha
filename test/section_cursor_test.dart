import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/home/section_cursor.dart';

/// Le défaut du 2026-08-29 : la barre de navigation et l'écran désignaient deux
/// onglets différents, sans qu'aucune erreur ne soit levée. On ne peut donc pas
/// le voir en lisant l'un ou l'autre — **il faut comparer les deux**.
void main() {
  group('SectionCursor', () {
    test('au depart, la barre et l ecran designent le meme onglet', () {
      final c = SectionCursor(4);
      expect(c.vise, 4);
      expect(c.affiche, 4);
      expect(c.enTransit, isFalse);
    });

    test(
      'poser recale les DEUX — le cas exact du bug de l onglet de demarrage',
      () {
        // L'ancien code posait la valeur visée (la barre) et laissait l'affichage
        // sur le Cercle, parce qu'aucune animation ne tournait pour le rattraper.
        final c = SectionCursor(2); // Cercle
        c.poser(4); // Profil, réglé dans les Réglages
        expect(c.vise, 4);
        expect(
          c.affiche,
          4,
          reason: 'l ecran doit suivre la barre sans animation',
        );
        expect(c.enTransit, isFalse);
      },
    );

    test('viser met en transit : la barre part, l ecran attend', () {
      final c = SectionCursor(2);
      expect(c.viser(3), isTrue);
      expect(c.vise, 3);
      expect(c.affiche, 2);
      expect(c.enTransit, isTrue);
    });

    test('viser la section courante ne declenche rien', () {
      final c = SectionCursor(2);
      expect(c.viser(2), isFalse);
      expect(c.enTransit, isFalse);
    });

    test('le relais rattrape, et une seule fois', () {
      final c = SectionCursor(2);
      c.viser(4);
      expect(c.relayer(), isTrue);
      expect(c.affiche, 4);
      expect(c.enTransit, isFalse);
      expect(c.relayer(), isFalse, reason: 'rien a rattraper, pas de rebuild');
    });

    test('poser en pleine bascule ne laisse pas de transit en cours', () {
      final c = SectionCursor(2);
      c.viser(3); // bascule entamée
      c.poser(1); // on repose ailleurs sans attendre
      expect(c.vise, 1);
      expect(c.affiche, 1);
      expect(c.enTransit, isFalse);
    });
  });
}
