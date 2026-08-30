import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/diagnostics/diagnostic_bundle.dart';
import 'package:neovibe/features/proximity/net/presence_book.dart';
import 'package:neovibe/features/proximity/net/wave_rules.dart';

/// Ce que ces tests défendent : **le carnet doit survivre à la fermeture de
/// l'app, et ne jamais tailler dans ce que la règle doit encore lire.**
///
/// Les deux défauts visés ne lèvent aucune erreur :
/// - un carnet en mémoire vive perdrait exactement les contacts dont le verdict
///   se rend une heure plus tard ;
/// - un élagage plus court que `WaveRules.memoire` rendrait la règle fausse en
///   silence — elle lirait un historique amputé et conclurait « rien avant ».
void main() {
  late Directory dossier;

  setUp(() async {
    dossier = await Directory.systemTemp.createTemp('presences');
  });

  tearDown(() async {
    if (await dossier.exists()) await dossier.delete(recursive: true);
  });

  final t = DateTime(2026, 8, 30, 15, 0);
  Presence p(DateTime debut, Duration duree) =>
      Presence(debut: debut, fin: debut.add(duree));

  PresenceBook carnet({DateTime? maintenant}) =>
      PresenceBook(directory: dossier, clock: () => maintenant ?? t);

  test('un contact noté se relit', () async {
    final contact = p(
      t.subtract(const Duration(minutes: 5)),
      const Duration(seconds: 10),
    );
    await carnet().noter('ami', contact: contact, detections: 7);

    expect(await carnet().historique('ami'), [contact]);
  });

  test('il survit à une NOUVELLE instance — c\'est tout son intérêt', () async {
    // Le verdict du presque se rend une heure après : l'app a eu toutes les
    // chances d'être fermée et rouverte entre les deux.
    final contact = p(
      t.subtract(const Duration(minutes: 5)),
      const Duration(seconds: 10),
    );
    await carnet().noter('ami', contact: contact, detections: 7);

    final relu = PresenceBook(directory: dossier, clock: () => t);
    expect(await relu.historique('ami'), [contact]);
  });

  test('le contact jugé est exclu de son propre historique', () async {
    // Sinon il se disqualifierait lui-même dès qu'il dépasse un seuil.
    final contact = p(t, const Duration(seconds: 10));
    final autre = p(
      t.subtract(const Duration(minutes: 30)),
      const Duration(minutes: 1),
    );
    await carnet().noter('ami', contact: contact, detections: 7);
    await carnet().noter('ami', contact: autre, detections: 40);

    expect(await carnet().historique('ami', sauf: contact), [autre]);
  });

  test('rien à juger avant que l\'heure d\'après soit écoulée', () async {
    final contact = p(t, const Duration(seconds: 10));
    await carnet().noter('ami', contact: contact, detections: 7);

    expect(
      await carnet(maintenant: t.add(const Duration(minutes: 30))).aJuger(),
      isEmpty,
    );

    final murs = await carnet(
      maintenant: t.add(const Duration(hours: 2)),
    ).aJuger();
    expect(murs.map((m) => m.userId), ['ami']);
    expect(murs.single.contact, contact);
  });

  test('un contact jugé ne revient JAMAIS — même refusé', () async {
    // 🔴 Sans la marque, chaque tour de balayage rejugerait les mêmes contacts
    // pour toujours : un presque refusé repartirait en boucle.
    final contact = p(t, const Duration(seconds: 10));
    await carnet().noter('ami', contact: contact, detections: 7);

    final tard = t.add(const Duration(hours: 2));
    final livre = carnet(maintenant: tard);
    expect(await livre.aJuger(), hasLength(1));
    await livre.marquerJuge('ami', contact);
    expect(await livre.aJuger(), isEmpty);

    // Et la marque tient au rechargement.
    expect(
      await PresenceBook(directory: dossier, clock: () => tard).aJuger(),
      isEmpty,
    );
  });

  test('l\'élagage ne coupe pas dans la fenêtre de la règle', () async {
    // 🔴 Le contre-test de la mémoire : un contact tout juste dans la fenêtre
    // doit SURVIVRE, un contact tout juste dehors doit partir.
    final dedans = p(
      t.subtract(WaveRules.memoire).add(const Duration(minutes: 1)),
      const Duration(seconds: 30),
    );
    final dehors = p(
      t.subtract(WaveRules.memoire).subtract(const Duration(hours: 1)),
      const Duration(seconds: 30),
    );
    final livre = carnet();
    await livre.noter('ami', contact: dehors, detections: 9);
    await livre.noter('ami', contact: dedans, detections: 9);

    expect(await livre.historique('ami'), [dedans]);
  });

  test('🔴 la mesure a un LECTEUR — le diagnostic la rend', () async {
    // Le carnet a été livré le 2026-08-30 sans être branché sur aucun rapport :
    // la mesure était juste, et personne ne pouvait la sortir de l'appareil.
    // Ce test est le contre-défaut — il tombe si la section cesse de dire ce
    // qu'elle a mesuré.
    final livre = carnet();
    await livre.noter(
      'abcdef0123456789',
      contact: p(
        t.subtract(const Duration(minutes: 10)),
        const Duration(seconds: 12),
      ),
      detections: 9,
    );

    final texte = await DiagnosticBundle.presences(livre: livre);

    expect(texte, contains('abcdef01'), reason: 'de quoi retrouver qui');
    expect(texte, isNot(contains('abcdef0123456789')), reason: 'et pas plus');
    expect(texte, contains('12s'), reason: 'la durée, la donnée qui manquait');
    expect(texte, contains('9 vues'));
    expect(texte, contains('en attente'), reason: "le verdict n'est pas rendu");
    expect(texte, contains('total 1 contacts'));
  });

  test('un carnet vide le DIT, il ne rend pas une section muette', () async {
    expect(
      await DiagnosticBundle.presences(livre: carnet()),
      'Aucun contact retenu.',
    );
  });

  test('effacer oublie tout — bascule de compte', () async {
    await carnet().noter(
      'ami',
      contact: p(t, const Duration(seconds: 10)),
      detections: 7,
    );
    final livre = carnet();
    await livre.clear();
    expect(await livre.historique('ami'), isEmpty);
  });
}
