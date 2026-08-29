import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/geo/coarse_location.dart';
import 'package:neovibe/features/proximity/ping_screen.dart';

/// **Ce que ces tests protègent : un bandeau ne prescrit pas une cause qu'il
/// n'a pas vérifiée.**
///
/// ## 🔴 Le défaut qu'ils rendent impossible — relevé par Jay le 2026-08-29
///
/// Son écran affichait *« Ni les satellites, ni le Wi-Fi, ni le réseau n'ont
/// répondu — approche-toi d'une fenêtre, ou active le Wi-Fi »*. **Son Wi-Fi
/// était allumé**, ses données mobiles aussi, son Bluetooth aussi. Le
/// diagnostic disait `finesse : approximate` : Android ne lui accordait plus
/// que la position approximative.
///
/// Le seul bouton offert était « Réessayer » — qui rejoue exactement la même
/// chose. **L'action qui aurait marché existait déjà** et était cachée par le
/// `return` du cas bloqué.
///
/// ⚠️ **Deux états qu'on croyait exclusifs sont simultanés.** La doc de
/// `LocationBlocker.noFix` affirmait « tout est autorisé » : c'est faux dès que
/// seule la permission approximative est accordée. Un commentaire qui énonce
/// une prémisse finit par décider du comportement.
void main() {
  group('le bandeau de position', () {
    test('sans position ET en approximatif : il nomme la BONNE cause', () {
      final m = messagePosition(
        LocationBlocker.noFix,
        LocationPrecision.approximate,
      );

      expect(
        m.quoiFaire,
        ActionPosition.autoriserPrecise,
        reason:
            '« Réessayer » rejoue la même chose et ne peut rien réparer : '
            "l'action offerte doit être celle qui a une chance de marcher.",
      );
      expect(
        m.detail.toLowerCase(),
        isNot(contains('active le wi-fi')),
        reason:
            "Jay avait le Wi-Fi allumé. Prescrire une action, c'est prescrire "
            "une cause — et celle-ci envoie chercher le problème là où il "
            "n'est pas.",
      );
      expect(
        m.detail.toUpperCase(),
        contains('APPROXIMATIVE'),
        reason: 'le fait relevé doit être dit, pas seulement contourné',
      );
    });

    test('sans position mais en précis : le message d\'environnement reste', () {
      final m = messagePosition(
        LocationBlocker.noFix,
        LocationPrecision.precise,
      );

      expect(m.quoiFaire, ActionPosition.reessayer);
      expect(
        m.detail,
        contains('Wi-Fi'),
        reason:
            'là, la permission est bonne : la cause est bien environnementale '
            'et le conseil est justifié',
      );
    });

    test('les deux messages de « sans position » sont DIFFÉRENTS', () {
      // ⚠️ Sinon la finesse serait lue, passée, et sans effet — un paramètre
      // qui ne change rien est pire qu'un paramètre absent : il donne
      // l'apparence d'une décision.
      expect(
        messagePosition(
          LocationBlocker.noFix,
          LocationPrecision.approximate,
        ).detail,
        isNot(
          equals(
            messagePosition(
              LocationBlocker.noFix,
              LocationPrecision.precise,
            ).detail,
          ),
        ),
      );
    });

    test('les trois autres blocages ne dépendent PAS de la finesse', () {
      // Ils décrivent une permission ou un réglage système : la finesse
      // accordée n'y change rien, et prétendre le contraire ferait dire deux
      // choses à un même fait.
      for (final b in [
        LocationBlocker.serviceOff,
        LocationBlocker.denied,
        LocationBlocker.deniedForever,
      ]) {
        expect(
          messagePosition(b, LocationPrecision.precise).detail,
          messagePosition(b, LocationPrecision.approximate).detail,
          reason: '$b ne doit pas changer de discours selon la finesse',
        );
      }
    });

    test('chaque blocage propose une action, et aucune n\'est vide', () {
      for (final b in LocationBlocker.values) {
        for (final p in LocationPrecision.values) {
          final m = messagePosition(b, p);
          expect(m.titre, isNotEmpty);
          expect(m.detail, isNotEmpty);
          expect(m.action, isNotEmpty, reason: 'un mur sans issue est un bug');
        }
      }
    });
  });
}
