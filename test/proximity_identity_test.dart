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
      identite.x25519PublicKey(),
      identite.currentPublicPingId(),
      identite.edPublicKey(),
    ]);

    expect(
      keystore.ecritures.where((k) => k == 'nv_ed25519_seed').length,
      1,
      reason: 'la clé d\'appareil ne doit être créée qu\'une fois',
    );
    expect(
      keystore.ecritures.where((k) => k == 'nv_x25519_seed').length,
      1,
      reason: "la clé X25519 ne doit être créée qu'une fois",
    );
    expect(resultats[0], resultats[3]);
  });

  test('les vestiges de la clé de diffusion sont EFFACÉS au chargement', () async {
    // ⚠️ **Un secret orphelin reste un secret.** La clé de diffusion n'a plus
    // aucun usage depuis le 2026-08-20, mais la laisser dormir dans le Keystore
    // reviendrait à garder un secret que plus rien ne protège, ne fait tourner
    // ni ne révoque. On le supprime, on ne se contente pas de l'ignorer.
    keystore.valeurs['nv_broadcast_key'] = 'AAAA';
    keystore.valeurs['nv_broadcast_v2'] = '{"key":"AAAA"}';

    await ProximityIdentity().edPublicKey();

    expect(keystore.valeurs.containsKey('nv_broadcast_key'), isFalse);
    expect(keystore.valeurs.containsKey('nv_broadcast_v2'), isFalse);
  });

  test('deux appareils dérivent LE MÊME secret de paire', () async {
    // ⚠️ **La propriété qui remplace toute la distribution de clés.** Aucun
    // secret ne circule : chacun combine sa clé privée avec la clé publique de
    // l'autre, et les deux tombent sur la même valeur. C'est ce qui supprime le
    // trou de 7 jours — il n'y a plus rien à synchroniser.
    final alice = ProximityIdentity();
    final pubA = await alice.x25519PublicKey();

    keystore.valeurs.clear();
    keystore.ecritures.clear();
    final bob = ProximityIdentity();
    final pubB = await bob.x25519PublicKey();

    expect(pubA, isNot(pubB));
    expect(await alice.pairSecret(pubB), await bob.pairSecret(pubA));
  });

  test("un jeton de paire n'est lisible que par le couple", () async {
    final alice = ProximityIdentity();
    final pubA = await alice.x25519PublicKey();
    keystore.valeurs.clear();
    final bob = ProximityIdentity();
    final pubB = await bob.x25519PublicKey();
    keystore.valeurs.clear();
    final carole = ProximityIdentity();
    final pubC = await carole.x25519PublicKey();

    final slot = ProximityIdentity.slotIndex(DateTime.now());
    final aliceBob = await ProximityIdentity.pairToken(
      await alice.pairSecret(pubB),
      slot,
    );
    final aliceCarole = await ProximityIdentity.pairToken(
      await alice.pairSecret(pubC),
      slot,
    );

    // Bob retrouve le jeton qu'Alice lui destine...
    expect(
      await ProximityIdentity.pairToken(await bob.pairSecret(pubA), slot),
      aliceBob,
    );
    // ...et Carole, amie d'Alice elle aussi, n'y voit rien.
    expect(aliceBob, isNot(aliceCarole));
  });

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

  test("l'identifiant PUBLIC change de créneau en créneau", () async {
    // Il ne sert qu'au mode ping, et n'est reconnu par personne : il rend
    // découvrable, il n'identifie pas. Sa seule propriété exigible est de ne
    // pas permettre de suivre celui qui l'émet.
    final identite = ProximityIdentity();
    final graine = identite.pingSeed();

    final slot = ProximityIdentity.slotIndex(DateTime.now());
    final ici = await ProximityIdentity.publicPingId(graine, slot);
    final apres = await ProximityIdentity.publicPingId(graine, slot + 1);

    expect(await identite.currentPublicPingId(), ici);
    expect(ici, isNot(apres), reason: 'sinon le pistage serait trivial');
    expect(ici.length, 16, reason: "la place dans l'annonce BLE est comptée");
  });
}
