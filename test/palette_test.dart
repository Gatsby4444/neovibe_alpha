import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/palette.dart';
import 'package:neovibe/core/prefs.dart';
import 'package:neovibe/core/theme.dart';

/// Une palette illisible ne lève **aucune erreur**.
///
/// L'app s'affiche, les tests passent, et le défaut ne se voit que sur l'écran
/// où la couleur sert — donc pas au premier test, et pas dans l'identité que
/// Jay a sous les yeux ce jour-là. C'est exactement le bug du bouton contour du
/// 2026-08-14 : texte blanc en dur, invisible dans le seul thème clair.
///
/// Ces tests ne jugent donc pas le goût, ils **mesurent**.
double _luminance(Color c) {
  double canal(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * canal(c.r) + 0.7152 * canal(c.g) + 0.0722 * canal(c.b);
}

/// Le rapport de contraste WCAG entre deux couleurs opaques. 1 = identiques,
/// 21 = noir sur blanc.
double contraste(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final clair = math.max(la, lb);
  final sombre = math.min(la, lb);
  return (clair + 0.05) / (sombre + 0.05);
}

void main() {
  group('Chaque palette est lisible', () {
    for (final (nom, p) in NeoPalettes.toutes) {
      test('$nom — le texte principal sur le fond et sur la surface', () {
        // 4,5:1 = seuil WCAG AA du texte courant.
        expect(
          contraste(p.ink, p.ground),
          greaterThanOrEqualTo(4.5),
          reason: 'texte principal sur le fond',
        );
        expect(
          contraste(p.ink, p.surface),
          greaterThanOrEqualTo(4.5),
          reason: 'texte principal sur une carte',
        );
        expect(
          contraste(p.ink, p.field),
          greaterThanOrEqualTo(4.5),
          reason: 'texte saisi dans un champ',
        );
      });

      test('$nom — le texte secondaire reste lisible', () {
        // 4,5:1 aussi : `inkMuted` porte des horodatages et des mentions, pas
        // de la décoration. Le seuil « grand texte » (3:1) ne s'applique pas.
        expect(contraste(p.inkMuted, p.ground), greaterThanOrEqualTo(4.5));
        expect(contraste(p.inkMuted, p.surface), greaterThanOrEqualTo(4.5));
      });

      test('$nom — le texte posé SUR la couleur d action', () {
        expect(
          contraste(p.onAction, p.action),
          greaterThanOrEqualTo(4.5),
          reason: 'libellé d un bouton plein',
        );
      });

      test('$nom — les bordures d elements interactifs se voient', () {
        // 3:1 = seuil WCAG 1.4.11 des composants non textuels. C'est la règle
        // « un champ a toujours un bord visible », énoncée positivement.
        expect(
          contraste(p.outline, p.ground),
          greaterThanOrEqualTo(3.0),
          reason: 'bord d un champ sur le fond',
        );
        expect(
          contraste(p.outline, p.field),
          greaterThanOrEqualTo(3.0),
          reason: 'bord d un champ sur son propre remplissage',
        );
      });

      test('$nom — la profondeur : la surface se distingue du fond', () {
        // ⚠️ Ce test-là n'a PAS d'équivalent WCAG : il ne protège pas la
        // lisibilité mais la PROFONDEUR, qui est une demande de Jay du
        // 2026-08-29. Une carte qui a exactement la couleur du fond n'est plus
        // une carte, c'est un texte qui flotte — et rien ne le signale.
        //
        // Le seuil est bas exprès : au-delà, l'écart se lirait comme une
        // bordure, pas comme une élévation. Valeur raisonnée, pas mesurée.
        expect(
          contraste(p.surface, p.ground),
          greaterThan(1.03),
          reason: 'une carte doit se détacher du fond',
        );
      });
    }
  });

  group('Chaque identité produit un thème complet', () {
    for (final id in NeoIdentity.values) {
      for (final b in Brightness.values) {
        test('${id.name} en ${b.name} porte sa palette', () {
          final theme = NeoTheme.of(id, b);
          final porte = theme.extension<NeoPaletteTheme>();

          // ⚠️ Sans l'extension, `context.palette` retombe **en silence** sur
          // la palette sombre : tout s'affiche, et une identité claire rendrait
          // des couleurs sombres sans qu'aucune erreur ne le dise.
          expect(porte, isNotNull, reason: 'extension de palette absente');
          expect(porte!.identity, id);
          expect(porte.palette, id.palette(b));

          // La police doit vraiment arriver jusqu'au thème : une police
          // manquante ne lève rien, Flutter retombe sur celle du système —
          // c'est l'état exact de l'app avant le 2026-08-29.
          expect(theme.textTheme.displaySmall?.fontFamily, 'Fredoka');
          expect(theme.textTheme.bodyMedium?.fontFamily, 'Figtree');
        });
      }
    }

    test('une identité fixe rend la même palette de jour comme de nuit', () {
      for (final id in NeoIdentity.values.where((i) => !i.suitLeSysteme)) {
        expect(
          id.palette(Brightness.light),
          same(id.palette(Brightness.dark)),
          reason: '${id.name} ne doit pas suivre le système',
        );
      }
    });

    test('une identité qui suit le système a bien DEUX palettes', () {
      for (final id in NeoIdentity.values.where((i) => i.suitLeSysteme)) {
        expect(
          id.palette(Brightness.light).isDark,
          isFalse,
          reason: '${id.name} de jour doit être claire',
        );
        expect(
          id.palette(Brightness.dark).isDark,
          isTrue,
          reason: '${id.name} de nuit doit être sombre',
        );
      }
    });
  });

  group('Reprise des anciens réglages', () {
    // Ces quatre cas décident de ce que voit un appareil DÉJÀ installé. Se
    // tromper ici ne casse rien : ça rend simplement son thème à quelqu'un qui
    // n'a rien demandé, ou ça masque le changement de direction artistique.
    test('un choix explicite de clair ou de sombre se conserve', () {
      expect(ThemeIdentityPref.resoudre(stored: 'light'), NeoIdentity.clair);
      expect(ThemeIdentityPref.resoudre(stored: 'dark'), NeoIdentity.sombre);
    });

    test('l ancien defaut « neovibe » bascule sur la nouvelle identite', () {
      expect(
        ThemeIdentityPref.resoudre(stored: 'neovibe'),
        NeoIdentity.aurore,
        reason: 'sinon le changement de direction ne se verrait nulle part',
      );
    });

    test('l ancien booleen est repris', () {
      expect(ThemeIdentityPref.resoudre(legacyLight: true), NeoIdentity.clair);
      expect(
        ThemeIdentityPref.resoudre(legacyLight: false),
        NeoIdentity.sombre,
      );
    });

    test('une installation neuve part sur Aurore', () {
      expect(ThemeIdentityPref.resoudre(), NeoIdentity.aurore);
    });
  });
}
