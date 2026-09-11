import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/features/cards/capture_type_state.dart';

/// Ce que le sélecteur affiche ↔ ce que la caméra sert.
///
/// 🔴 **Le premier test est le seul qui compte vraiment.** Il rejoue le défaut
/// signalé par Jay le 2026-09-11 : le premier passage en Oneshot n'atteignait
/// jamais la caméra, parce que « ce que la caméra sert » naissait déjà égal au
/// type que le doigt venait de choisir (`late CardType _cameraType = _type;`,
/// évalué au premier ACCÈS et non à la construction). Il fallait sortir du
/// Oneshot et y revenir pour que le double live s'ouvre.
///
/// Il redevient ROUGE si quelqu'un redonne une valeur de départ à `servi`.
void main() {
  group('CaptureTypeState', () {
    test('le PREMIER changement de type atteint toujours la caméra', () {
      final t = CaptureTypeState.ouvertSur(CardType.standard);

      // À l'ouverture, la caméra n'a reçu AUCUNE consigne. Ce n'est pas
      // « elle sert du standard » — c'est « on ne lui a rien dit ».
      expect(
        t.servi,
        isNull,
        reason: 'une valeur de départ ici ferait taire le premier changement',
      );

      t.poser(CardType.oneshot);
      final change = t.aAppliquer();

      expect(change, isNotNull, reason: 'le défaut du 2026-09-11 (#125)');
      expect(change!.nouveau, CardType.oneshot);
      expect(
        change.precedent,
        isNull,
        reason: 'la caméra ne sortait d\'aucun mode',
      );
    });

    test('reposer le même type ne reconfigure rien', () {
      final t = CaptureTypeState.ouvertSur(CardType.standard);
      t.poser(CardType.oneshot);
      expect(t.aAppliquer(), isNotNull);
      // Le PageView réémet volontiers le type déjà posé : sans ce filtre, on
      // rouvrirait un double flux de 1,5 s pour rien.
      t.poser(CardType.oneshot);
      expect(t.aAppliquer(), isNull);
    });

    test('aller-retour : le précédent est rendu, dans le bon sens', () {
      final t = CaptureTypeState.ouvertSur(CardType.standard);
      t.poser(CardType.oneshot);
      t.aAppliquer();

      t.poser(CardType.standard);
      final sortie = t.aAppliquer();
      expect(sortie!.nouveau, CardType.standard);
      expect(
        sortie.precedent,
        CardType.oneshot,
        reason: 'c\'est lui qui déclenche la fermeture du double flux',
      );

      t.poser(CardType.oneshot);
      expect(t.aAppliquer()!.nouveau, CardType.oneshot);
    });

    test('un écran ouvert en BeReal part bien de BeReal', () {
      final t = CaptureTypeState.ouvertSur(CardType.bereal);
      expect(t.affiche, CardType.bereal);
      expect(t.servi, isNull);

      t.poser(CardType.oneshot);
      expect(t.aAppliquer()!.precedent, isNull);
    });

    test(
      'realigner : le sélecteur a bougé pendant l\'ouverture du double flux',
      () {
        final t = CaptureTypeState.ouvertSur(CardType.standard);
        t.poser(CardType.oneshot);
        t.aAppliquer(); // ouverture lancée, ~1,5 s devant nous

        // Jay repart sur Standard AVANT la fin de l'ouverture.
        t.poser(CardType.standard);
        expect(
          t.realigner(),
          isTrue,
          reason: 'il faut refermer le double flux qu\'on vient d\'ouvrir',
        );
        expect(t.servi, CardType.standard);
      },
    );

    test('realigner : sélecteur immobile, rien à défaire', () {
      final t = CaptureTypeState.ouvertSur(CardType.standard);
      t.poser(CardType.oneshot);
      t.aAppliquer();
      expect(t.realigner(), isFalse);
      expect(t.servi, CardType.oneshot);
    });
  });
}
