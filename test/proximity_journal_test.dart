import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/proximity_journal.dart';

/// Ce que le journal garde encore : le **cooldown des waves**.
///
/// ⚠️ **Les tests des demandes d'amis ont été retirés le 2026-08-27**, avec les
/// deux modèles qu'ils vérifiaient. Ils couvraient de vrais défauts — une seconde
/// demande qui écrasait la première, un refus qui touchait le mauvais magasin —
/// mais une demande de proximité est désormais une ligne de
/// `connection_requests`, donc du ressort du serveur.
void main() {
  late Directory dossier;

  setUp(() => dossier = Directory.systemTemp.createTempSync('nv-journal'));
  tearDown(() => dossier.deleteSync(recursive: true));

  ProximityJournal ouvrir() => ProximityJournal(directory: dossier);

  test('le cooldown des waves SURVIT au redémarrage', () async {
    await ouvrir().noteWave('u-1');

    // ⚠️ C'est le défaut C4 : la fenêtre vivait en mémoire, donc relancer
    // l'app suffisait à renotifier « le presque » pour la même personne.
    expect(await ouvrir().mayWave('u-1', const Duration(hours: 2)), isFalse);
    expect(await ouvrir().mayWave('u-2', const Duration(hours: 2)), isTrue);
  });

  test('un cooldown écoulé rouvre le droit', () async {
    final journal = ouvrir();
    await journal.noteWave('u-1');
    expect(await journal.mayWave('u-1', Duration.zero), isTrue);
  });

  test('un fichier illisible ne fait pas planter le ping', () async {
    final dir = await Directory.systemTemp.createTemp('journal');
    await File(
      '${dir.path}${Platform.pathSeparator}wave_cooldown.json',
    ).writeAsString('{pas du json');
    // Un fichier corrompu ne doit pas empêcher d'envoyer un wave : on repart
    // d'une mémoire vide plutôt que de lever.
    expect(
      await ProximityJournal(directory: dir).mayWave('u-a', Duration.zero),
      isTrue,
    );
  });

  test('effacer le journal ne laisse rien derrière', () async {
    final dir = await Directory.systemTemp.createTemp('journal');
    final journal = ProximityJournal(directory: dir);
    await journal.noteWave('u-a');
    // Les reliquats du chat BLE partent aussi : d'anciens appareils en portent.
    await File(
      '${dir.path}${Platform.pathSeparator}pending_requests.json',
    ).writeAsString(jsonEncode([]));

    await journal.clear();

    expect(await dir.list().toList(), isEmpty);
  });
}
