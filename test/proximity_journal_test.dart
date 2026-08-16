import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/proximity_journal.dart';
import 'package:neovibe/features/proximity/ping_store.dart';

const profil = PingPeerSnapshot(
  userId: 'u-1',
  username: 'Mimi',
  verified: true,
);

PendingFriendRequest demande(String de, {DateTime? recue}) =>
    PendingFriendRequest(
      fromUserId: de,
      snapshot: PingPeerSnapshot(userId: de, username: de, verified: true),
      payload: {'from': de, 'to': 'moi', 'ts': 'x'},
      receivedAt: recue ?? DateTime.now(),
    );

void main() {
  late Directory dossier;

  setUp(() => dossier = Directory.systemTemp.createTempSync('nv-journal'));
  tearDown(() => dossier.deleteSync(recursive: true));

  ProximityJournal ouvrir() => ProximityJournal(directory: dossier);

  test('une demande survit à la fermeture de l\'app', () async {
    await ouvrir().putRequest(demande('u-a'));

    // Nouvelle instance = nouveau lancement : rien en mémoire.
    final apres = await ouvrir().pendingRequests();

    // ⚠️ L'ancienne version gardait la demande dans l'état Riverpod. Fermer
    // l'app la perdait, sans copie serveur — donc définitivement.
    expect(apres.single.fromUserId, 'u-a');
  });

  test('PLUSIEURS personnes peuvent demander en même temps', () async {
    final journal = ouvrir();
    await journal.putRequest(demande('u-a'));
    await journal.putRequest(demande('u-b'));
    await journal.putRequest(demande('u-c'));

    // L'ancienne version n'avait qu'un emplacement : la deuxième écrasait la
    // première sans trace. C'est pourtant le cas normal dans un groupe.
    expect((await journal.pendingRequests()).length, 3);
  });

  test(
    'renvoyer sa demande la rafraîchit au lieu d\'en créer une deuxième',
    () async {
      final journal = ouvrir();
      await journal.putRequest(demande('u-a'));
      await journal.putRequest(demande('u-a'));

      expect((await journal.pendingRequests()).length, 1);
    },
  );

  test('une demande trop vieille n\'est plus proposée', () async {
    await ouvrir().putRequest(
      demande(
        'u-vieux',
        recue: DateTime.now().subtract(
          PendingFriendRequest.ttl + const Duration(hours: 1),
        ),
      ),
    );

    // Une demande de proximité qui traîne n'a plus de sens : la rencontre est
    // passée depuis longtemps.
    expect(await ouvrir().pendingRequests(), isEmpty);
  });

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
    File(
      '${dossier.path}${Platform.pathSeparator}pending_requests.json',
    ).writeAsStringSync('{ ceci n\'est pas du JSON');

    // Le ping doit démarrer même avec un journal abîmé : perdre des demandes
    // est ennuyeux, ne plus détecter personne serait pire.
    expect(await ouvrir().pendingRequests(), isEmpty);
  });

  test('effacer le journal ne laisse rien derrière', () async {
    final journal = ouvrir();
    await journal.putRequest(demande('u-a'));
    await journal.noteWave('u-1');

    await journal.clear();

    expect(await journal.pendingRequests(), isEmpty);
    expect(await journal.mayWave('u-1', const Duration(hours: 2)), isTrue);
  });
}
