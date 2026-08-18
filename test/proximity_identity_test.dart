import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// Keystore simulé, qui **compte ses écritures**.
///
/// ⚠️ Le compteur n'est pas décoratif : c'est lui qui prouve la correction de la
/// course du premier lancement. Deux appelants simultanés qui ne trouvent rien
/// en stockage généraient chacun leur clé et l'écrivaient tous les deux — sans
/// que rien ne le signale.
class KeystoreSimule {
  final Map<String, String> valeurs = {};
  final ecritures = <String>[];

  /// Retarde les lectures, pour que deux appelants se croisent réellement.
  Duration latence = Duration.zero;

  void installer() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map).cast<String, dynamic>();
            final cle = args['key'] as String?;
            switch (call.method) {
              case 'read':
                if (latence > Duration.zero) {
                  await Future<void>.delayed(latence);
                }
                return valeurs[cle];
              case 'write':
                ecritures.add(cle!);
                valeurs[cle] = args['value'] as String;
                return null;
              case 'delete':
                valeurs.remove(cle);
                return null;
              case 'readAll':
                return Map<String, String>.from(valeurs);
              case 'deleteAll':
                valeurs.clear();
                return null;
              case 'containsKey':
                return valeurs.containsKey(cle);
              default:
                return null;
            }
          },
        );
  }

  void retirer() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KeystoreSimule keystore;

  setUp(() {
    keystore = KeystoreSimule()..installer();
  });
  tearDown(() => keystore.retirer());

  test('deux appels simultanés ne fabriquent QU\'UNE identité', () async {
    // ⚠️ **Le défaut du 2026-08-18, en test.**
    //
    // `ProximityIdentity` se construisait avec `new` à cinq endroits, et
    // `_ensureLoaded` n'avait aucun verrou. Au tout premier démarrage, le
    // superviseur (qui lance la radio) et la synchro (qui publie les clés)
    // appelaient chacun le leur en parallèle ; aucun ne trouvait de clé, **les
    // deux en généraient une et l'écrivaient**.
    //
    // Conséquences possibles, toutes silencieuses : diffuser un ID dérivé de la
    // clé A pendant que le serveur reçoit la clé B — donc n'être jamais reconnu
    // par ses amis — ou signer la poignée de main avec une clé d'appareil et le
    // profil avec une autre, ce qui fait échouer `isPeerDeviceKey` et renvoie
    // « profil non authentifié ».
    //
    // La latence force le croisement : sans elle, le premier appel finirait
    // avant que le second ne commence, et le test serait vert sans rien prouver.
    keystore.latence = const Duration(milliseconds: 20);
    final identite = ProximityIdentity();

    final resultats = await Future.wait([
      identite.edPublicKey(),
      identite.broadcastKey(),
      identite.currentRotatingId(),
      identite.edPublicKey(),
    ]);

    expect(
      keystore.ecritures.where((k) => k == 'nv_ed25519_seed').length,
      1,
      reason: 'la clé d\'appareil ne doit être créée qu\'une fois',
    );
    expect(
      keystore.ecritures.where((k) => k == 'nv_broadcast_v2').length,
      1,
      reason: 'la clé de diffusion ne doit être créée qu\'une fois',
    );

    // Et la clé rendue est bien celle qui a été stockée.
    final stockee = base64Decode(
      jsonDecode(keystore.valeurs['nv_broadcast_v2']!)['key'] as String,
    );
    expect(resultats[1], stockee);
  });

  test(
    'la clé de diffusion est stable tant qu\'elle n\'a pas 7 jours',
    () async {
      final identite = ProximityIdentity();
      final premiere = await identite.broadcastKey();

      expect(await identite.rotateBroadcastIfDue(), isFalse);
      expect(await identite.broadcastKey(), premiere);
      expect(await identite.previousBroadcastKey(), isNull);
    },
  );

  test('passé 7 jours elle tourne, et l\'ancienne reste publiée', () async {
    // On écrit directement une clé datée d'il y a huit jours : c'est la seule
    // façon de vieillir l'identité sans horloge injectable, et c'est fidèle —
    // c'est exactement ce que le Keystore contiendra au bout d'une semaine.
    final ancienne = List<int>.generate(32, (i) => i);
    keystore.valeurs['nv_broadcast_v2'] = jsonEncode({
      'key': base64Encode(ancienne),
      'at': DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 8))
          .toIso8601String(),
    });

    final identite = ProximityIdentity();
    expect(await identite.rotateBroadcastIfDue(), isTrue);

    expect(await identite.broadcastKey(), isNot(ancienne));
    expect(
      await identite.previousBroadcastKey(),
      ancienne,
      reason:
          'sans elle, la rotation nous rendrait invisible à tous nos amis '
          'jusqu\'à leur prochaine synchronisation',
    );
  });

  test('une RÉVOCATION jette l\'ancienne clé', () async {
    final identite = ProximityIdentity();
    final avant = await identite.broadcastKey();

    await identite.rotateBroadcast(keepPrevious: false);

    // ⚠️ **C'est le seul moyen de reprendre ce qui a déjà été distribué.** Une
    // clé de diffusion n'est pas un droit de lecture qu'on révoque côté serveur :
    // c'est un secret copié sur l'appareil de l'autre. Garder la précédente
    // laisserait l'ex-ami nous reconnaître — donc annulerait la révocation.
    expect(await identite.broadcastKey(), isNot(avant));
    expect(await identite.previousBroadcastKey(), isNull);
  });

  test(
    'l\'ancien format de clé est repris sans faire tourner le parc',
    () async {
      final ancienne = List<int>.generate(32, (i) => (i * 3) % 256);
      keystore.valeurs['nv_broadcast_key'] = base64Encode(ancienne);

      final identite = ProximityIdentity();

      // La clé en place reste valable : la faire tourner au premier lancement de
      // cette version aurait rendu tout le monde invisible en même temps.
      expect(await identite.broadcastKey(), ancienne);
      expect(keystore.valeurs.containsKey('nv_broadcast_key'), isFalse);
      expect(keystore.valeurs.containsKey('nv_broadcast_v2'), isTrue);
    },
  );

  test(
    'oublier l\'identité efface le Keystore, et la suite en recrée une neuve',
    () async {
      final identite = ProximityIdentity();
      final avant = await identite.edPublicKey();

      await identite.forget();
      expect(keystore.valeurs, isEmpty);

      // ⚠️ **Le changement de compte.** La clé de diffusion ne dépendait pas du
      // compte connecté : après une déconnexion, l'appareil continuait de diffuser
      // l'ID rotatif du compte précédent, et les amis de A voyaient « A est là »
      // pendant que B utilisait le téléphone.
      final apres = await identite.edPublicKey();
      expect(apres, isNot(avant));
    },
  );

  test('l\'ID rotatif change de créneau en créneau, et se recalcule', () async {
    final identite = ProximityIdentity();
    final cle = await identite.broadcastKey();

    final slot = ProximityIdentity.slotIndex(DateTime.now());
    final ici = await ProximityIdentity.rotatingId(cle, slot);
    final apres = await ProximityIdentity.rotatingId(cle, slot + 1);

    expect(await identite.currentRotatingId(), ici);
    expect(ici, isNot(apres), reason: 'sinon le pistage serait trivial');
    expect(ici.length, 16, reason: 'la place dans l\'annonce BLE est comptée');
  });
}
