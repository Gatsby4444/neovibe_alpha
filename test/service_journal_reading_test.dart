import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/diagnostics/service_journal_reading.dart';

/// Ce que ces tests protègent : **la phrase que Jay lit après une nuit.**
///
/// Le carnet natif est écrit pour le seul moment où personne ne regarde. Si sa
/// lecture se trompe — une mort qu'elle ne voit pas, un redémarrage qu'elle
/// prend pour une mort —, le diagnostic envoie chercher la panne au mauvais
/// endroit, avec l'assurance d'un instrument. C'est exactement l'erreur de
/// `RAPPELS.md` #94 (un critère écrit sans être joué sur un vrai relevé).
void main() {
  const nuitOrdinaire = '''
2026-09-13 03:07:08 up=51234s cree
2026-09-13 03:07:08 up=51234s demarre par l'app
2026-09-13 03:07:09 up=51235s radio : running
2026-09-13 03:15:00 up=51706s alarme — retard=312ms
2026-09-13 03:30:00 up=52606s alarme — retard=1ms
''';

  test('une ligne se décode entièrement', () {
    final l = ServiceJournalLine.parse(
      '2026-09-13 03:15:00 up=51706s alarme — retard=312ms',
    );
    expect(l, isNotNull);
    expect(l!.at, DateTime(2026, 9, 13, 3, 15));
    expect(l.uptimeSeconds, 51706);
    expect(l.event, 'alarme');
    expect(l.detail, 'retard=312ms');
  });

  test('une ligne sans détail, et la marque de coupe, ne cassent rien', () {
    expect(
      ServiceJournalLine.parse('2026-09-13 03:07:08 up=51234s cree')?.event,
      'cree',
    );
    expect(ServiceJournalLine.parse('[…] plus ancien retiré'), isNull);
    expect(ServiceJournalLine.parse(''), isNull);
  });

  test('carnet vide : on le dit, sans inventer', () {
    expect(ServiceJournalReading.lecture(''), contains('Aucun carnet'));
  });

  test('une vie normale : ni mort, ni redémarrage', () {
    final lecture = ServiceJournalReading.lecture(nuitOrdinaire);
    expect(lecture, contains('5 lignes'));
    expect(lecture, contains('alarmes 2'));
    expect(lecture, contains('aucune mort sans « detruit »'));
    expect(lecture, isNot(contains('🔴')));
  });

  test('deux « cree » sans « detruit » = une mort, datée', () {
    final lecture = ServiceJournalReading.lecture(
      '$nuitOrdinaire'
      '2026-09-13 09:57:31 up=76400s cree\n'
      '2026-09-13 09:57:31 up=76400s demarre par l\'app\n',
    );
    expect(lecture, contains('🔴 mort sans prévenir entre 03:30'));
    expect(lecture, contains('(dernier signe : alarme) et 09:57'));
    expect(lecture, contains('créé 2'));
  });

  test('un « detruit » entre deux vies n\'est pas une mort', () {
    final lecture = ServiceJournalReading.lecture(
      '$nuitOrdinaire'
      '2026-09-13 04:00:00 up=54400s arret voulu\n'
      '2026-09-13 04:00:00 up=54400s detruit\n'
      '2026-09-13 09:57:31 up=76400s cree\n',
    );
    expect(lecture, isNot(contains('🔴')));
    expect(lecture, contains('arrêt voulu 1'));
  });

  test('un `up=` qui redescend = le téléphone a redémarré', () {
    final lecture = ServiceJournalReading.lecture(
      '$nuitOrdinaire'
      '2026-09-13 09:57:31 up=120s cree\n',
    );
    expect(
      lecture,
      contains('⚠️ le téléphone a redémarré entre 03:30 et 09:57'),
    );
    // Une mort ET un redémarrage : les deux se disent, on ne choisit pas.
    expect(lecture, contains('🔴 mort sans prévenir'));
  });

  test('la relance par Android et ses deux issues se comptent', () {
    final lecture = ServiceJournalReading.lecture(
      '$nuitOrdinaire'
      '2026-09-13 05:00:00 up=58000s cree\n'
      '2026-09-13 05:00:00 up=58000s relance par Android — flags=0\n'
      '2026-09-13 05:00:00 up=58000s reprise du disque : ok\n'
      '2026-09-13 07:00:00 up=65000s cree\n'
      '2026-09-13 07:00:00 up=65000s relance par Android — flags=0\n'
      '2026-09-13 07:00:00 up=65000s reprise du disque : rien — pas de plan\n'
      '2026-09-13 07:00:00 up=65000s detruit\n',
    );
    expect(lecture, contains('relancé par Android 2 (reprise ok 1, rien 1)'));
    expect(lecture, contains('détruit 1'));
  });
}
