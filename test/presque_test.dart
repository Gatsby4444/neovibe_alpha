import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/presque_ledger.dart';

/// **Ce que ces tests protègent : le « presque » dit « vous vous êtes ratés »,
/// pas « je viens de te reconnaître ».**
///
/// ## 🔴 Le défaut qu'ils rendent impossible — signalé par Jay le 2026-08-29
///
/// > *« le presque se déclenche alors que je reste à proximité, il n'y a pas de
/// > croisement et pourtant le presque semble se déclencher à certains moments
/// > sans raisons apparentes »*
///
/// La notification partait au moment où l'on **reconnaissait** un ami, avec pour
/// seule condition un délai de garde de deux heures. Rester assis à côté de
/// quelqu'un toute la journée en produisait donc un, dès que la radio hoquetait.
///
/// ## ⚠️ Pourquoi ce défaut ne pouvait tomber sur aucun test existant
///
/// Il ne lève rien, n'affiche rien de faux, et ne casse aucune fonction : la
/// seule trace est une notification de trop, chez quelqu'un d'autre, 45 minutes
/// plus tard. **Il ne se voit qu'en éprouvant la règle elle-même** — d'où cette
/// classe, sortie du `switch` où elle vivait.
void main() {
  group('le presque', () {
    test("une présence qui a compté n'est pas un presque", () {
      final ledger = PresqueLedger();
      ledger.noteCroisement('u-mimi');
      expect(
        ledger.finDePresence('u-mimi'),
        isFalse,
        reason: 'contact assez long pour un constat = croisement, pas presque',
      );
    });

    test('une présence qui n\'a rien produit EST un presque', () {
      final ledger = PresqueLedger();
      expect(ledger.finDePresence('u-mimi'), isTrue);
    });

    test('rester à côté toute la journée ne produit aucun presque', () {
      // 🔴 Le cas exact de Jay. Le balayage passe toutes les deux secondes ; la
      // présence ne se termine jamais, donc rien ne part.
      final ledger = PresqueLedger();
      for (var tour = 0; tour < 500; tour++) {
        ledger.noteCroisement('u-mimi');
      }
      expect(ledger.length, 1, reason: 'une personne, une entrée');
      expect(ledger.finDePresence('u-mimi'), isFalse);
    });

    test('la mémoire décrit UNE présence, pas une personne', () {
      // Un vrai presque plus tard avec le même ami doit encore partir : sinon
      // la première rencontre longue de la journée éteindrait toutes les
      // suivantes.
      final ledger = PresqueLedger();
      ledger.noteCroisement('u-mimi');
      expect(ledger.finDePresence('u-mimi'), isFalse);
      expect(
        ledger.finDePresence('u-mimi'),
        isTrue,
        reason: 'la présence suivante repart de zéro',
      );
    });

    test('deux personnes ne se mélangent pas', () {
      final ledger = PresqueLedger();
      ledger.noteCroisement('u-mimi');
      expect(ledger.finDePresence('u-charles'), isTrue);
      expect(ledger.finDePresence('u-mimi'), isFalse);
    });

    test('la fin de présence vide la mémoire dans les DEUX cas', () {
      // ⚠️ Une mémoire non bornée dans un objet qui vit des jours est une fuite,
      // et elle ne se voit qu'au bout de longtemps.
      final ledger = PresqueLedger();
      ledger.noteCroisement('u-a');
      ledger.finDePresence('u-a');
      ledger.finDePresence('u-b');
      expect(ledger.length, 0);
    });

    test('la radio qui s\'arrête oublie les présences en cours', () {
      // Couper sa visibilité n'émet aucun `PeerLost` : sans cet oubli, les
      // entrées resteraient pour toujours et avaleraient le premier vrai
      // presque d'après.
      final ledger = PresqueLedger();
      ledger.noteCroisement('u-mimi');
      ledger.oublieTout();
      expect(ledger.length, 0);
      expect(
        ledger.finDePresence('u-mimi'),
        isTrue,
        reason: 'une nouvelle rencontre brève doit pouvoir être un presque',
      );
    });
  });
}
