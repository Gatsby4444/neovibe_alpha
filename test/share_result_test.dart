import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/cards/send/share_publisher.dart';

/// Ce que ces tests défendent : **un envoi partiel ne se dit ni « réussi » ni
/// « échoué ».**
///
/// C'est le seul cas où l'écran peut mentir sans qu'aucune erreur ne soit
/// levée. Dire « envoyé » ferait perdre en silence la destination manquante ;
/// dire « échec » ferait renvoyer celles qui sont déjà parties — et une story
/// publiée deux fois, ça se voit.
void main() {
  ShareOutcome ok(String l) => ShareOutcome(label: l);
  ShareOutcome ko(String l) => ShareOutcome(label: l, erreur: StateError(l));

  test('tout est parti', () {
    final r = ShareResult([ok('Ma story'), ok('Louis')]);
    expect(r.toutEstParti, isTrue);
    expect(r.rienNEstParti, isFalse);
    expect(r.echecs, isEmpty);
  });

  test('rien n\'est parti', () {
    final r = ShareResult([ko('Ma story'), ko('Louis')]);
    expect(r.toutEstParti, isFalse);
    expect(r.rienNEstParti, isTrue);
  });

  test('🔴 un envoi PARTIEL n\'est ni l\'un ni l\'autre', () {
    final r = ShareResult([ok('Ma story'), ko('Louis'), ok('Julie')]);
    expect(r.toutEstParti, isFalse, reason: 'Louis n\'a rien reçu');
    expect(r.rienNEstParti, isFalse, reason: 'la story EST en ligne');
    expect(r.reussites.map((o) => o.label), ['Ma story', 'Julie']);
    expect(r.echecs.single.label, 'Louis');
  });

  test('un plan vide n\'est PAS « tout est parti »', () {
    // Sinon un écran qui n'envoie rien afficherait « envoyé ✓ ».
    expect(const ShareResult([]).toutEstParti, isFalse);
  });
}
