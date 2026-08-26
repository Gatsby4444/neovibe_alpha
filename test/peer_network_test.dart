import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/peer_network.dart';
import 'package:neovibe/features/proximity/net/peer_session.dart';
import 'package:neovibe/features/proximity/net/proximity_protocol.dart';
import 'package:neovibe/features/proximity/net/radio_status.dart';
import 'package:neovibe/features/proximity/ping_store.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

import 'support/proximity_doubles.dart';

/// Deux appareils complets, branchés l'un sur l'autre par une radio simulée.
///
/// ## Pourquoi ce montage est le test le plus important du chantier
///
/// L'ancienne couche ne pouvait être éprouvée qu'avec **deux téléphones dans les
/// mains de Jay**. Résultat : elle ne l'était presque jamais, et les treize
/// défauts du diagnostic ont tous vécu des semaines. Ici, la découverte, la
/// poignée de main signée, la révélation de profil et le chat tournent en
/// quelques millisecondes, sur un ordinateur, à chaque `flutter test`.
class Appareil {
  Appareil._(
    this.nom,
    this.reseau,
    this.radio,
    this.identite,
    this.carnet,
    this.horloge,
  );

  static Future<Appareil> creer(
    String nom, {
    required String userId,
    required int graine,
    required RadioSimulee radio,
    HorlogeMobile? horloge,
    Duration profilLent = Duration.zero,
  }) async {
    // ⚠️ **Chaque appareil a une horloge pilotée.** Les règles de présence se
    // comptent désormais en secondes (fraîcheur, stabilité, oubli) : sans
    // horloge maîtrisée, un test devrait ou bien attendre réellement dix
    // secondes, ou bien ne rien vérifier de ces règles.
    final montre = horloge ?? HorlogeMobile();
    // ⚠️ **L'identité porte l'identifiant de compte**, parce que le jeton d'ami
    // porte le nom de celui qui l'émet depuis le 2026-08-26.
    final identite = await IdentiteMemoire.creer(
      graine: graine,
      userId: userId,
    );
    final carnet = CarnetMemoire();
    final reseau = PeerNetwork(
      myUserId: userId,
      myProfile: () async {
        // ⚠️ **Le profil vient d'un provider Riverpod, parfois du réseau.**
        // Sur l'appareil de Jay, c'est ce délai qui a ouvert la fenêtre : le
        // canal chiffrait déjà, et notre profil attendait encore sa source.
        if (profilLent > Duration.zero) await Future<void>.delayed(profilLent);
        return PingPeerSnapshot(userId: userId, username: nom, verified: true);
      },
      radio: radio,
      identity: identite,
      keyBook: carnet,
      clock: montre.call,
    );
    radio.reseau = reseau;
    await reseau.refreshFriends();
    return Appareil._(nom, reseau, radio, identite, carnet, montre);
  }

  final String nom;
  final PeerNetwork reseau;
  final RadioSimulee radio;
  final IdentiteMemoire identite;
  final CarnetMemoire carnet;
  final HorlogeMobile horloge;

  /// Une annonce BLE **publique** de [autre] — ce que voit un inconnu.
  ///
  /// ⚠️ Depuis le 2026-08-20, un appareil n'émet plus un identifiant unique
  /// pour tout le monde : il émet un jeton PAR AMI, plus un identifiant public
  /// quand le mode ping est actif. Simuler « je vois quelqu'un » demande donc
  /// de choisir **lequel des deux** — et c'est une bonne chose : le test ne
  /// peut plus confondre les deux publics.
  Future<void> voit(Appareil autre, {int rssi = -60, String? depuis}) async {
    await reseau.onRadioEvent(
      RadioScan(
        address: depuis ?? autre.radio.adresse,
        advertId: await autre.identite.currentPublicPingId(),
        rssi: rssi,
        type: AdvertType.public,
      ),
    );
  }

  /// L'annonce que [autre] émet à l'intention de **quelqu'un d'autre**.
  ///
  /// ⚠️ **C'est le cas qui a produit « 13 détections » chez Jay le
  /// 2026-08-25.** Un appareil crie un jeton par ami : celui qui a cinq amis
  /// crie cinq jetons, dont **quatre me sont totalement opaques**. Ce ne sont
  /// pas des inconnus — ce sont les jetons privés d'autres paires. Les afficher
  /// comme des découvertes, c'est inventer des gens.
  Future<void> voitJetonDUnTiers(
    Appareil autre,
    Appareil destinataire, {
    int rssi = -60,
    String? depuis,
  }) async {
    await reseau.onRadioEvent(
      RadioScan(
        address: depuis ?? autre.radio.adresse,
        advertId: await autre.identite.jetonPour(
          destinataire.identite,
          slot: null,
        ),
        rssi: rssi,
        type: AdvertType.friend,
      ),
    );
  }

  /// L'annonce que [autre] émet **à mon intention**, parce qu'il me compte
  /// parmi ses amis. Personne d'autre au monde ne peut la reconnaître.
  Future<void> voitAmi(Appareil autre, {int rssi = -60, String? depuis}) async {
    await reseau.onRadioEvent(
      RadioScan(
        address: depuis ?? autre.radio.adresse,
        advertId: await autre.identite.jetonPour(identite, slot: null),
        rssi: rssi,
        type: AdvertType.friend,
      ),
    );
  }

  /// Ouvre le canal chiffré vers [autre] **par un geste explicite**.
  ///
  /// ⚠️ **C'est le seul chemin qui subsiste depuis le 2026-08-27.** Voir un
  /// inconnu, même longtemps, n'ouvre plus rien : son identité vient du serveur.
  /// Le canal ne s'ouvre plus que lorsque l'utilisateur agit — c'est ce que
  /// `ensureChannel` documente, et c'est ce que les tests de transport doivent
  /// désormais emprunter pour avoir un canal à éprouver.
  Future<void> ouvreLeCanalVers(Appareil autre) async {
    await voit(autre);
    await reseau.ensureChannel(autre.radio.adresse);
  }

  /// Un contact **continu** assez long pour que l'on accepte d'ouvrir un lien.
  ///
  /// ⚠️ C'est la règle posée le 2026-08-18 : on n'ouvre pas de connexion GATT
  /// avec un inconnu au premier signe de vie, sinon on la paie pour chaque
  /// passant et chaque voiture qui s'arrête au feu. Il faut
  /// [PresenceRules.stableAfter] de contact et [PresenceRules.minSightings]
  /// annonces.
  Future<void> voitLongtemps(Appareil autre, {int rssi = -60}) async {
    final pas =
        (PresenceRules.stableAfter ~/ PresenceRules.minSightings) +
        const Duration(seconds: 1);
    for (var i = 0; i <= PresenceRules.minSightings; i++) {
      await voit(autre, rssi: rssi);
      horloge.avance(pas);
    }
    await voit(autre, rssi: rssi);
  }
}

/// Laisse tourner les échanges asynchrones jusqu'à ce que [condition] tienne.
Future<void> jusqua(bool Function() condition, {int tours = 200}) async {
  for (var i = 0; i < tours; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition jamais atteinte');
}

void main() {
  late RadioSimulee radioA;
  late RadioSimulee radioB;
  late Appareil a;
  late Appareil b;

  setUp(() async {
    radioA = RadioSimulee('AA');
    radioB = RadioSimulee('BB');
    radioA.pair = radioB;
    radioB.pair = radioA;
    a = await Appareil.creer('Alice', userId: 'u-a', graine: 1, radio: radioA);
    b = await Appareil.creer('Bob', userId: 'u-b', graine: 2, radio: radioB);
  });

  tearDown(() async {
    await a.reseau.dispose();
    await b.reseau.dispose();
  });

  group("Deux formats d'annonce, deux chemins — jamais un seul", () {
    test("le jeton privé de Bob destiné à Carole ne crée AUCUNE détection chez "
        "Alice", () async {
      final radioC = RadioSimulee('CC');
      final carole = await Appareil.creer(
        'Carole',
        userId: 'u-c',
        graine: 3,
        radio: radioC,
      );
      addTearDown(carole.reseau.dispose);

      await a.voitJetonDUnTiers(b, carole);

      expect(
        a.reseau.presence.sessions,
        isEmpty,
        reason:
            "Bob crie un jeton par ami. Celui destiné à Carole est opaque "
            "pour Alice : ce n'est pas un inconnu, c'est le jeton privé "
            "d'une autre paire. L'afficher, c'est inventer quelqu'un — et "
            "c'est ce qui a produit « 13 détections » le 2026-08-25.",
      );
      expect(a.reseau.foreignTokenScans, 1);
    });

    test("le jeton privé de Bob destiné à Alice, lui, identifie Bob", () async {
      // Alice doit avoir la clé publique de Bob : c'est ce que la synchro
      // serveur transporte, et ce dont dérive le secret de paire.
      await a.carnet.put(
        FriendKeys(
          userId: 'u-b',
          username: 'Bob',
          edPublicKey: await b.identite.edPublicKey(),
          x25519PublicKey: await b.identite.x25519PublicKey(),
        ),
      );
      await a.reseau.refreshFriends();

      await a.voitAmi(b);
      expect(a.reseau.presence.byUser('u-b'), isNotNull);
      expect(
        a.reseau.foreignTokenScans,
        0,
        reason: "Un jeton reconnu ne doit jamais être compté comme étranger.",
      );
    });

    test(
      "l'identifiant PUBLIC reste une découverte, même sans être reconnu",
      () async {
        await a.voit(b);
        expect(
          a.reseau.presence.sessions,
          isNotEmpty,
          reason:
              "C'est tout le rôle de l'identifiant public : être capté par "
              "quelqu'un qui ne le reconnaît pas. Le jeter reviendrait à "
              "supprimer la découverte d'inconnus.",
        );
      },
    );
  });

  test('un geste explicite révèle l\'inconnu, et ils se parlent', () async {
    // ⚠️ **Ce test ouvrait le canal tout seul avant le 2026-08-27.** Il
    // suffisait de se voir durablement. Ce chemin est supprimé : l'identité
    // d'un inconnu vient du serveur, et le canal BLE ne s'ouvre plus que sur un
    // geste de l'utilisateur.
    //
    // Ce qui est protégé ici reste entier : quand le canal EST ouvert, la
    // poignée de main signée, la révélation de profil et le chat aboutissent.
    await a.ouvreLeCanalVers(b);
    await b.voit(a);

    await jusqua(
      () =>
          a.reseau.presence.identifiedCount == 1 &&
          b.reseau.presence.identifiedCount == 1,
    );

    // Chacun connaît le VRAI identifiant de l'autre — donc la poignée de main
    // signée et la vérification de profil ont abouti.
    expect(a.reseau.presence.byUser('u-b'), isNotNull);
    expect(b.reseau.presence.byUser('u-a'), isNotNull);
    expect(a.reseau.presence.byUser('u-b')!.snapshot!.username, 'Bob');

    // Et le tunnel chiffré transporte un message applicatif.
    final recus = <String>[];
    b.reseau.events.listen((e) {
      if (e is PeerMessageReceived && e.message is ChatMessage) {
        recus.add((e.message as ChatMessage).text);
      }
    });

    await a.reseau.sendToUser(
      'u-b',
      ChatMessage(id: 'm1', text: 'on se voit ?', sentAt: DateTime.now()),
    );
    await jusqua(() => recus.isNotEmpty);
    expect(recus.single, 'on se voit ?');
  });

  test('un inconnu ne coûte AUCUNE connexion, bref ou installé', () async {
    // ⚠️ **Ce test a changé de sens le 2026-08-27, et c'est voulu.**
    //
    // Il protégeait l'objection de Jay du 2026-08-18 : ne pas ouvrir une
    // connexion GATT dès la première annonce d'un inconnu — une poignée de main
    // complète pour quelqu'un qui traverse le couloir. Il vérifiait donc qu'un
    // passant ne coûte rien, **mais qu'un inconnu installé finit par ouvrir**.
    //
    // Cette seconde moitié n'existe plus. Décision de Jay : *« on n'utilise plus
    // la poignée de main GATT, le BLE ne sert qu'à valider et authentifier la
    // proximité réelle »*. L'identité d'un inconnu vient de `ping_nearby`, après
    // réciprocité prouvée côté serveur.
    //
    // Ce qu'on protège maintenant est plus fort : **aucune durée de contact,
    // si longue soit-elle, ne doit rouvrir ce chemin.** C'est le mur des sept
    // connexions GATT qu'on a supprimé, et il ne doit pas revenir par
    // inadvertance.
    for (var i = 0; i < 3; i++) {
      await a.voit(b);
      a.horloge.avance(const Duration(seconds: 1));
    }
    expect(a.reseau.presence.length, 1, reason: 'il est bien détecté');
    expect(radioA.connexions, isEmpty, reason: 'mais il ne coûte rien');

    // Il s'installe, longtemps — bien au-delà de l'ancien seuil de stabilité
    // et de l'ancien délai de repli passif.
    await a.voitLongtemps(b);
    a.horloge.avance(const Duration(minutes: 2));
    await a.reseau.tick();

    expect(
      radioA.connexions,
      isEmpty,
      reason:
          "voir un inconnu, même longtemps, ne doit plus dépenser une "
          "connexion : son identité vient du serveur",
    );
    expect(
      a.reseau.presence.identifiedCount,
      0,
      reason: 'et il reste un inconnu pour la radio',
    );
  });

  test('un inconnu détecté EXISTE avant d\'être identifié', () async {
    // On coupe la radio d'en face : la poignée de main ne pourra pas aboutir.
    radioB.injoignable = true;

    await a.voit(b);

    // Le pair est là, visible, dans un état qui se dit — au lieu du « personne
    // à proximité » de l'ancienne couche.
    expect(a.reseau.presence.length, 1);
    expect(a.reseau.presence.identifiedCount, 0);
    expect(
      a.reseau.presence.peers.single.stage,
      anyOf(PresenceStage.detected, PresenceStage.identifying),
    );
  });

  test('un ami est reconnu à son jeton de paire, SANS aucun échange', () async {
    // Chacun a la clé PUBLIQUE de l'autre : c'est tout ce que la synchro
    // serveur transporte désormais. Le secret, lui, se dérive des deux côtés.
    await a.carnet.put(
      FriendKeys(
        userId: 'u-b',
        username: 'Bob',
        edPublicKey: await b.identite.edPublicKey(),
        x25519PublicKey: await b.identite.x25519PublicKey(),
      ),
    );
    await a.reseau.refreshFriends();

    // La radio d'en face est morte : aucun lien ne peut s'ouvrir.
    radioB.injoignable = true;
    await a.voitAmi(b);

    // Reconnu, donc identifié — sans le moindre échange, et **dès la première
    // annonce** : le seuil anti-passant ne s'applique qu'aux inconnus, puisque
    // reconnaître un ami ne coûte rien.
    expect(a.reseau.presence.byUser('u-b'), isNotNull);
    expect(a.reseau.presence.byUser('u-b')!.stage, PresenceStage.identified);
    expect(radioA.connexions, isEmpty, reason: 'aucun lien ne doit s\'ouvrir');
  });

  test("le jeton d'un ami n'est lisible QUE par lui", () async {
    // ⚠️ **La propriété qui remplace toute la mécanique de rotation.**
    //
    // Avec une clé de diffusion unique, tout ami pouvait reconnaître l'annonce
    // — donc la retirer à l'un obligeait à la changer pour tous. Ici, le jeton
    // que Bob émet à l'intention d'Alice ne veut rien dire pour Carole, même si
    // Carole est aussi son amie.
    final radioC = RadioSimulee('CC');
    final c = await Appareil.creer(
      'Carole',
      userId: 'u-c',
      graine: 9,
      radio: radioC,
    );

    await a.carnet.put(
      FriendKeys(
        userId: 'u-b',
        username: 'Bob',
        edPublicKey: await b.identite.edPublicKey(),
        x25519PublicKey: await b.identite.x25519PublicKey(),
      ),
    );
    await c.carnet.put(
      FriendKeys(
        userId: 'u-b',
        username: 'Bob',
        edPublicKey: await b.identite.edPublicKey(),
        x25519PublicKey: await b.identite.x25519PublicKey(),
      ),
    );
    await a.reseau.refreshFriends();
    await c.reseau.refreshFriends();

    // Bob émet le jeton destiné à Alice. Carole le capte aussi — la radio est
    // publique — mais il ne lui dit rien.
    final pourAlice = await b.identite.jetonPour(a.identite);
    await c.reseau.onRadioEvent(
      RadioScan(
        address: 'BB',
        advertId: pourAlice,
        rssi: -60,
        type: AdvertType.friend,
      ),
    );
    expect(
      c.reseau.presence.byUser('u-b'),
      isNull,
      reason: 'le jeton destiné à Alice ne doit rien apprendre à Carole',
    );

    // Alice, elle, le reconnaît.
    await a.reseau.onRadioEvent(
      RadioScan(
        address: 'BB',
        advertId: pourAlice,
        rssi: -60,
        type: AdvertType.friend,
      ),
    );
    expect(a.reseau.presence.byUser('u-b'), isNotNull);
  });

  test('retirer un ami le rend aveugle SANS toucher aux autres', () async {
    // ⚠️ **Le gain principal du secret par paire.**
    //
    // Avant, révoquer voulait dire faire tourner l'unique clé de diffusion —
    // donc rendre l'appareil méconnaissable pour TOUS les amis jusqu'à leur
    // prochaine synchronisation (RAPPELS #46 ②). Ici, on retire une entrée du
    // carnet, et rien d'autre ne bouge.
    final radioC = RadioSimulee('CC');
    final c = await Appareil.creer(
      'Carole',
      userId: 'u-c',
      graine: 9,
      radio: radioC,
    );
    for (final ami in [
      FriendKeys(
        userId: 'u-b',
        username: 'Bob',
        edPublicKey: await b.identite.edPublicKey(),
        x25519PublicKey: await b.identite.x25519PublicKey(),
      ),
      FriendKeys(
        userId: 'u-c',
        username: 'Carole',
        edPublicKey: await c.identite.edPublicKey(),
        x25519PublicKey: await c.identite.x25519PublicKey(),
      ),
    ]) {
      await a.carnet.put(ami);
    }
    await a.reseau.refreshFriends();
    radioB.injoignable = true;

    await a.voitAmi(b);
    expect(a.reseau.presence.byUser('u-b'), isNotNull);

    // Bob est retiré. Carole ne doit rien perdre au passage.
    await a.carnet.remove('u-b');
    await a.reseau.refreshFriends();

    await a.reseau.onRadioEvent(
      RadioScan(
        address: 'DD',
        advertId: await b.identite.jetonPour(a.identite),
        type: AdvertType.friend,
        rssi: -60,
      ),
    );
    expect(
      a.reseau.presence.byAddress('DD')?.snapshot,
      isNull,
      reason: 'Bob retiré ne doit plus être reconnu, immédiatement',
    );

    await a.reseau.onRadioEvent(
      RadioScan(
        address: 'EE',
        advertId: await c.identite.jetonPour(a.identite),
        type: AdvertType.friend,
        rssi: -60,
      ),
    );
    expect(
      a.reseau.presence.byUser('u-c'),
      isNotNull,
      reason: "Carole n'est pas concernée par le retrait de Bob",
    );
  });

  test('des clés arrivées APRÈS le démarrage sont prises en compte', () async {
    // ⚠️ **Le défaut du 2026-08-17, en test.**
    //
    // `PeerNetwork.start()` construisait l'index rotatif, **puis** la synchro
    // téléchargeait les clés — sans que rien ne le dise. L'index n'était
    // reconstruit qu'au changement de créneau, toutes les 15 minutes, et depuis
    // un cache périmé : donc jamais. Un ami restait un inconnu jusqu'au
    // prochain lancement de l'app.
    await a.reseau.start();
    expect(a.reseau.presence.length, 0);

    // Les clés arrivent maintenant, comme le ferait la synchronisation.
    await a.carnet.put(
      FriendKeys(
        userId: 'u-b',
        username: 'Bob',
        edPublicKey: await b.identite.edPublicKey(),
        x25519PublicKey: await b.identite.x25519PublicKey(),
      ),
    );

    // ⚠️ **Aucun `refreshFriends()` explicite ici.** C'est tout le sujet : le
    // carnet prévient, l'index se reconstruit seul. Si on l'appelait à la main,
    // ce test ne prouverait rien — il vérifierait qu'une méthode appelée fait
    // ce qu'elle dit, pas que quelqu'un l'appelle au bon moment.
    radioB.injoignable = true;
    await jusqua(() {
      unawaited(a.voitAmi(b));
      return a.reseau.presence.byUser('u-b')?.stage == PresenceStage.identified;
    });

    // Une fois reconnu, un ami n'ouvre plus aucun lien.
    final avant = radioA.connexions.length;
    await a.voitAmi(b);
    expect(
      radioA.connexions.length,
      avant,
      reason: 'un ami reconnu n\'ouvre aucun lien',
    );
  });

  test('la radio qui s\'arrête ferme TOUT, présence et transport', () async {
    // ⚠️ **Le second chemin, jamais soupçonné avant le 2026-08-18.**
    //
    // `presence.clear()` vidait la présence **sans fermer les canaux** : il
    // restait des sessions chiffrées vivantes que plus aucune entrée ne
    // désignait, et le pair d'en face continuait de parler dans le vide.
    //
    // Avec une session unique, arrêter la radio ferme le transport dans le même
    // geste — il n'y a plus d'état à moitié défait.
    await a.ouvreLeCanalVers(b);
    await b.voit(a);
    await jusqua(() => a.reseau.presence.identifiedCount == 1);

    await a.reseau.onRadioEvent(const RadioStatusEvent(RadioAdapterOff()));

    expect(a.reseau.presence.length, 0);
    expect(
      radioA.coupures,
      contains(radioB.adresse),
      reason: 'le Dart n\'oublie jamais un lien que le natif tient encore',
    );
  });

  test(
    'un profil signé par une AUTRE clé que la poignée de main est rejeté',
    () async {
      await a.ouvreLeCanalVers(b);
      await b.voit(a);
      await jusqua(() => a.reseau.presence.identifiedCount == 1);

      // Un imposteur forge un profil parfaitement signé… avec sa propre clé.
      final imposteur = await IdentiteMemoire.creer(graine: 42);
      final faux = ProfileMessage(
        userId: 'u-victime',
        username: 'Victime',
        devicePublicKey: await imposteur.edPublicKey(),
        signature: await imposteur.sign(
          ProfileMessage.signedPayload('u-victime', 'Victime'),
        ),
      );

      await b.reseau.send(radioA.adresse, faux);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // La signature est valide, mais la clé n'est pas celle qui a ouvert la
      // session : l'identité d'origine tient.
      expect(a.reseau.presence.byUser('u-victime'), isNull);
      expect(a.reseau.presence.byUser('u-b'), isNotNull);
    },
  );

  test('les DEUX se connectent en meme temps : aucun message fantome', () async {
    // ⚠️ Le cas exact rapporte par Jay le 2026-08-16 : « charles envoie des
    // messages fantomes a mimi qui ne les recoit jamais ».
    //
    // Le repli passif de 12 s rend ce cas frequent : si l'initiateur tarde,
    // l'autre prend la main - et les deux finissent connectes. Chacun recevait
    // alors DEUX evenements de lien, et le second detruisait la session deja
    // negociee.
    await a.ouvreLeCanalVers(b);
    await b.voit(a);
    await jusqua(() => a.reseau.presence.identifiedCount == 1);

    // On force le second lien, dans l'autre sens, comme si les deux avaient
    // decide d'initier.
    await radioB.connect(radioA.adresse);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    final recus = <String>[];
    b.reseau.events.listen((e) {
      if (e is PeerMessageReceived && e.message is ChatMessage) {
        recus.add((e.message as ChatMessage).text);
      }
    });

    await a.reseau.sendToUser(
      'u-b',
      ChatMessage(id: 'm', text: 'toujours la ?', sentAt: DateTime.now()),
    );
    await jusqua(() => recus.isNotEmpty);

    // Sans le correctif, ce message n'arrivait jamais.
    expect(recus.single, 'toujours la ?');
  });

  test('ne plus ENTENDRE un pair ne coupe pas la session qui le relie', () async {
    // ⚠️ **Deux mesures qui portaient le même nom, et c'est ce qui a coûté cinq
    // itérations.**
    //
    // - **entendre** un pair, c'est recevoir son annonce — une diffusion non
    //   fiable, qu'un téléphone en poche ou un canal occupé font manquer ;
    // - **être relié**, c'est tenir une connexion GATT et un canal chiffré.
    //
    // La règle de 2026-08-18 sépare enfin les deux **sans les faire diverger** :
    // au bout de [PresenceRules.freshFor] on cesse de dire « il est là », mais
    // on ne démonte la session qu'à [PresenceRules.forgetAfter]. Entre les deux,
    // une conversation en cours survit à un trou de radio — et une trame reçue
    // rafraîchit la présence, parce qu'elle prouve la présence.
    final radioP = RadioSimulee('PP');
    final radioQ = RadioSimulee('QQ');
    radioP.pair = radioQ;
    radioQ.pair = radioP;

    final p = await Appareil.creer(
      'P',
      userId: 'u-p',
      graine: 7,
      radio: radioP,
    );
    final q = await Appareil.creer(
      'Q',
      userId: 'u-q',
      graine: 8,
      radio: radioQ,
    );

    await p.ouvreLeCanalVers(q);
    await q.voit(p);
    await jusqua(
      () =>
          p.reseau.presence.identifiedCount == 1 &&
          q.reseau.presence.identifiedCount == 1,
    );

    final recus = <String>[];
    p.reseau.events.listen((e) {
      if (e is PeerMessageReceived && e.message is ChatMessage) {
        recus.add((e.message as ChatMessage).text);
      }
    });

    // P n'entend plus Q : passé 5 s, P **cesse de dire qu'il est là**…
    p.horloge.avance(PresenceRules.freshFor + const Duration(seconds: 2));
    await p.reseau.tick();
    expect(
      p.reseau.presence.identifiedCount,
      0,
      reason:
          'la présence ne ment plus : sans preuve récente, il n\'est pas là',
    );

    // …mais la session vit encore, donc le message de Q arrive.
    await q.reseau.sendToUser(
      'u-p',
      ChatMessage(id: 'm', text: 'tu me reçois ?', sentAt: DateTime.now()),
    );
    await jusqua(() => recus.isNotEmpty);
    expect(recus.single, 'tu me reçois ?');

    // Et cette trame vaut observation : P le redit présent.
    expect(
      p.reseau.presence.identifiedCount,
      1,
      reason: 'une trame reçue prouve la présence autant qu\'une annonce',
    );

    await p.reseau.dispose();
    await q.reseau.dispose();
  });

  test(
    'au-delà de l\'oubli, la session est refermée ET la radio coupée',
    () async {
      // ⚠️ **La règle : le Dart n'oublie jamais un lien que le natif tient
      // encore.** L'ancien `prune` détruisait le canal sans rien couper côté
      // radio : le natif gardait une connexion GATT dont le Dart avait perdu la
      // trace, et `connect()` rendait ensuite un succès immédiat sans émettre le
      // moindre événement. L'état était **collant** jusqu'à ce que la radio lâche
      // d'elle-même.
      final radioP = RadioSimulee('PP');
      final radioQ = RadioSimulee('QQ');
      radioP.pair = radioQ;
      radioQ.pair = radioP;

      final p = await Appareil.creer(
        'P',
        userId: 'u-p',
        graine: 7,
        radio: radioP,
      );
      final q = await Appareil.creer(
        'Q',
        userId: 'u-q',
        graine: 8,
        radio: radioQ,
      );

      await p.ouvreLeCanalVers(q);
      await q.voit(p);
      await jusqua(() => p.reseau.presence.identifiedCount == 1);

      final perdus = <String>[];
      p.reseau.events.listen((e) {
        if (e is PeerLost) perdus.add(e.peer.address);
      });

      p.horloge.avance(PresenceRules.forgetAfter + const Duration(seconds: 1));
      await p.reseau.tick();
      // Le flux d'événements est asynchrone : sans ce tour de boucle, on
      // vérifierait la liste avant que `PeerLost` n'y soit arrivé.
      await Future<void>.delayed(Duration.zero);

      expect(p.reseau.presence.length, 0);
      expect(perdus, isNotEmpty, reason: 'le départ se dit');
      expect(radioP.coupures, contains(radioQ.adresse));

      await p.reseau.dispose();
      await q.reseau.dispose();
    },
  );

  // ------------------------------------------------------------------
  // Reconstruction d'une session perdue d'un seul côté
  // ------------------------------------------------------------------

  /// Monte une paire dont les rôles sont CHOISIS, au lieu de dépendre de la
  /// comparaison des ID rotatifs (qui change à chaque créneau de 15 min).
  Future<(Appareil, Appareil)> paireEtablie({
    required String nomInitiateur,
  }) async {
    final radio1 = RadioSimulee('11');
    final radio2 = RadioSimulee('22');
    radio1.pair = radio2;
    radio2.pair = radio1;
    final un = await Appareil.creer(
      'Un',
      userId: 'u-1',
      graine: 11,
      radio: radio1,
    );
    final deux = await Appareil.creer(
      'Deux',
      userId: 'u-2',
      graine: 12,
      radio: radio2,
    );
    // On ouvre le lien À LA MAIN : c'est ce qui rend le rôle déterministe.
    await (nomInitiateur == 'Un' ? radio1 : radio2).connect(
      nomInitiateur == 'Un' ? radio2.adresse : radio1.adresse,
    );
    await jusqua(
      () =>
          un.reseau.presence.identifiedCount == 1 &&
          deux.reseau.presence.identifiedCount == 1,
    );
    return (un, deux);
  }

  test('notre profil part TOUJOURS avant le premier message', () async {
    // ⚠️ **Relevé sur l'appareil de Jay le 2026-08-17** :
    // `message reçu avant le profil (CertOfferMessage, présence identifying)`.
    //
    // Le balayage des certificats n'attend que « canal établi ». Or l'identité
    // arrive APRÈS la poignée de main : le certificat pouvait doubler notre
    // profil, et en face la trame était **jetée** — alors que `certified` était
    // déjà marqué, donc plus aucune tentative.
    final radio1 = RadioSimulee('11');
    final radio2 = RadioSimulee('22');
    radio1.pair = radio2;
    radio2.pair = radio1;
    // ⚠️ **Le profil de Un est LENT** — reproduction fidèle de ce qui s'est
    // passé chez Jay : `myProfile()` lit un provider, parfois adossé au réseau.
    final un = await Appareil.creer(
      'Un',
      userId: 'u-1',
      graine: 11,
      radio: radio1,
      profilLent: const Duration(milliseconds: 80),
    );
    final deux = await Appareil.creer(
      'Deux',
      userId: 'u-2',
      graine: 12,
      radio: radio2,
    );

    // ⚠️ **L'écoute est posée AVANT la connexion.** Sinon l'identification a
    // déjà eu lieu quand on commence à regarder.
    final ordre = <String>[];
    deux.reseau.events.listen((e) {
      if (e is PeerIdentified) ordre.add('identité');
      if (e is PeerMessageReceived) ordre.add('message');
    });

    await radio1.connect(radio2.adresse);

    await jusqua(() => un.reseau.hasEstablishedChannel(radio2.adresse));
    await un.reseau.send(
      radio2.adresse,
      ChatMessage(id: 'm', text: 'premier', sentAt: DateTime.now()),
    );
    await jusqua(() => ordre.contains('message'));

    expect(
      ordre.first,
      'identité',
      reason: 'un message qui double le profil est jeté en face, sans un mot',
    );

    await un.reseau.dispose();
    await deux.reseau.dispose();
  });

  test(
    'un changement d\'adresse MAC ne perd ni la session ni les messages',
    () async {
      // ⚠️ **La vraie cause du relevé de Jay du 2026-08-17** (`ChatMessage,
      // présence ABSENTE`) : Android renouvelle périodiquement son adresse MAC.
      // La présence fusionnait alors deux lignes et **abandonnait** l'une des
      // deux, en se promettant de refermer son transport au battement suivant —
      // jusqu'à 3 secondes plus tard. Le correctif d'alors a produit la boucle
      // `takeMergedAway`, dupliquée à deux endroits qui ont divergé.
      //
      // Avec une session unique, une adresse de plus est **une adresse de plus** :
      // rien n'est abandonné, rien n'est différé.
      await a.carnet.put(
        FriendKeys(
          userId: 'u-b',
          username: 'Bob',
          edPublicKey: await b.identite.edPublicKey(),
          x25519PublicKey: await b.identite.x25519PublicKey(),
        ),
      );
      await a.reseau.refreshFriends();

      // Bob est reconnu, puis on ouvre un lien (comme le ferait un certificat).
      await a.voitAmi(b);
      await a.reseau.ensureChannel(radioB.adresse);
      await jusqua(() => a.reseau.presence.identifiedCount == 1);

      final recus = <String>[];
      a.reseau.events.listen((e) {
        if (e is PeerMessageReceived && e.message is ChatMessage) {
          recus.add((e.message as ChatMessage).text);
        }
      });

      // Bob réapparaît sous une NOUVELLE adresse. Reconnu au même ID rotatif, il
      // fusionne — et le lien vivant reste sur l'ancienne adresse.
      await a.voitAmi(b, depuis: 'ZZ');
      expect(a.reseau.presence.length, 1, reason: 'une personne, une ligne');
      expect(
        a.reseau.presence.byUser('u-b')!.addresses,
        containsAll(<String>['BB', 'ZZ']),
      );

      // Et la conversation continue, sur la session qui n'a jamais bougé.
      await b.reseau.send(
        radioA.adresse,
        ChatMessage(id: 'm', text: 'toujours moi', sentAt: DateTime.now()),
      );
      await jusqua(() => recus.isNotEmpty);
      expect(recus.single, 'toujours moi');
    },
  );

  for (final quiReconstruit in ['le même côté', 'l\'autre côté']) {
    test(
      'une session perdue d\'un seul côté se reconstruit — $quiReconstruit',
      () async {
        final (un, deux) = await paireEtablie(nomInitiateur: 'Un');

        // Un échange normal d'abord : c'est ce qui fait avancer les compteurs,
        // et donc ce qui rendra la session neuve d'en face inacceptable.
        final recusUn = <String>[];
        un.reseau.events.listen((e) {
          if (e is PeerMessageReceived && e.message is ChatMessage) {
            recusUn.add((e.message as ChatMessage).text);
          }
        });
        await deux.reseau.sendToUser(
          'u-1',
          ChatMessage(id: 'm0', text: 'salut', sentAt: DateTime.now()),
        );
        await jusqua(() => recusUn.isNotEmpty);

        // ⚠️ **Deux perd sa session, et Un n'en sait rien.**
        deux.reseau.onRadioEvent(
          RadioLink(
            linkId: un.radio.adresse,
            connected: false,
            mtu: 0,
            incoming: false,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        // Deux rouvre. Selon le côté qui rappelle, il reprend le rôle
        // d'initiateur ou prend celui que l'autre croit encore tenir.
        if (quiReconstruit == 'le même côté') {
          await un.radio.connect(deux.radio.adresse);
        } else {
          await deux.radio.connect(un.radio.adresse);
        }

        // Et Deux parle, sur sa session NEUVE (compteur 0).
        await jusqua(() => deux.reseau.presence.identifiedCount == 1);
        await deux.reseau.sendToUser(
          'u-1',
          ChatMessage(id: 'm1', text: 'tu me lis ?', sentAt: DateTime.now()),
        );

        await jusqua(() => recusUn.length == 2);
        expect(recusUn.last, 'tu me lis ?');

        await un.reseau.dispose();
        await deux.reseau.dispose();
      },
    );
  }
}
