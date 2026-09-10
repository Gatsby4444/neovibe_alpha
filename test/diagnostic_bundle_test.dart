import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/diagnostics/diagnostic_bundle.dart';

/// Ce que ces tests défendent : **un rapport tronqué ne doit jamais se lire
/// comme un rapport complet.**
///
/// ## 🔴 Le défaut d'origine, relevé le 2026-09-11 en lisant les VRAIS envois
///
/// En base, les rapports de la tablette Lenovo pesaient **408 125 caractères
/// pour un plafond de 409 600** — 99,6 %. Le prochain un peu plus bavard se
/// faisait couper.
///
/// ⚠️ **Et par le mauvais bout.** La troncature garde la FIN, ce qui est juste
/// pour un journal. Mais le paquet place délibérément les sections courtes et
/// décisives — radio, présences, connexions, position — **en TÊTE**, justement
/// pour qu'elles ne soient pas enfouies sous 40 000 caractères de journal
/// caméra. Le jour où le plafond serait atteint, la coupe aurait donc supprimé
/// **exactement ce qu'on avait pris soin de mettre en premier**, sans que rien
/// ne l'indique.
///
/// Deux règles justes chacune de son côté, qui se contredisaient en silence.
void main() {
  group('la place accordée à un journal', () {
    test('un journal court passe INTACT — pas de marque parasite', () {
      // Sinon on paierait un avertissement de troncature sur tous les rapports
      // qui n'en ont pas besoin, et il ne voudrait plus rien dire.
      const court = 'trois lignes\nde journal\ntranquille';
      expect(DiagnosticBundle.bornerJournal(court), court);
    });

    test('à la limite EXACTE, rien n\'est retiré', () {
      // La borne est inclusive : un journal pile à la taille maximale est
      // complet, il n'y a rien à annoncer.
      final pile = 'x' * DiagnosticBundle.maxLogChars;
      expect(DiagnosticBundle.bornerJournal(pile), pile);
    });

    test('un journal trop long est ramené SOUS une taille lisible', () {
      final long = 'y' * (DiagnosticBundle.maxLogChars * 3);
      final borne = DiagnosticBundle.bornerJournal(long);
      // Le texte gardé fait exactement la borne ; l'en-tête ajoute quelques
      // dizaines de caractères, d'où la marge.
      expect(borne.length, lessThan(DiagnosticBundle.maxLogChars + 200));
    });

    test('on garde la FIN, jamais le début', () {
      // Un journal se lit par ce qui vient de se passer. Garder le début
      // rendrait un rapport qui décrit le démarrage de l'app et rien du défaut.
      final long = '${'a' * DiagnosticBundle.maxLogChars}DERNIERE-LIGNE';
      final borne = DiagnosticBundle.bornerJournal(long);
      expect(borne.endsWith('DERNIERE-LIGNE'), isTrue);
    });

    test('🔴 la coupe se DIT — sinon on conclut sur ce qui manque', () {
      // C'est le cœur du défaut : un journal tronqué en silence se lit comme un
      // journal complet. On en déduit « ça n'est jamais arrivé » alors que la
      // ligne est simplement tombée par le haut.
      final long = 'z' * (DiagnosticBundle.maxLogChars + 5000);
      final borne = DiagnosticBundle.bornerJournal(long);
      expect(borne, startsWith('[...]'));
      expect(borne, contains('5000 caracteres plus anciens retires'));
    });

    test('le plafond par journal laisse la place aux DEUX plus le reste', () {
      // ⚠️ La vraie contrainte : deux journaux bornés doivent tenir sous le
      // plafond d'envoi de `DevReport` (400 Ko) en laissant de la place aux
      // sections structurées. Sans cette marge, borner les journaux n'aurait
      // fait que déplacer le problème.
      const plafondEnvoi = 400 * 1024;
      const deuxJournaux = 2 * DiagnosticBundle.maxLogChars;
      expect(deuxJournaux, lessThan(plafondEnvoi));
      expect(
        plafondEnvoi - deuxJournaux,
        greaterThan(100 * 1024),
        reason: 'moins de 100 Ko pour toutes les sections structurees',
      );
    });
  });
}
