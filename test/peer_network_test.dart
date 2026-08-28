import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/peer_network.dart';
import 'package:neovibe/features/proximity/net/peer_session.dart';
import 'package:neovibe/features/proximity/net/radio_status.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

import 'support/proximity_doubles.dart';

/// Ce que la radio apprend **toute seule** : reconnaître un ami à son jeton.
///
/// ## ⚠️ Ce que ce fichier ne teste plus, depuis le 2026-08-27
///
/// Il faisait tourner **deux piles complètes** branchées l'une sur l'autre par
/// une radio simulée : poignée de main signée, révélation de profil, chat,
/// reconstruction de session, message fantôme. Une dizaine de tests, et le
/// montage le plus utile du chantier — il avait remplacé « deux téléphones dans
/// les mains de Jay » par quelques millisecondes de `flutter test`.
///
/// Le transport BLE est supprimé (décision de Jay du 2026-08-27) : il n'y a plus
/// de lien, plus de canal, plus de trame. Ces tests ne pouvaient pas être
/// adaptés — **ils testaient précisément ce qui n'existe plus**. Les garder
/// aurait demandé de garder le code qu'ils éprouvent.
///
/// ⚠️ **Ce qu'ils protégeaient est passé au serveur, et n'est donc plus couvert
/// ici** : l'identité d'un inconnu (`ping_nearby`), la messagerie de proximité,
/// la demande d'ami (`request_connection_from_proximity`). Ces trois chemins
/// sont éprouvés **en base**, sous identité utilisateur, pas en test Dart —
/// c'est une différence de nature à ne pas oublier au prochain chantier.
///
/// Ce qui reste ici est ce que le serveur ne saura jamais faire : reconnaître un
/// ami hors ligne, à un jeton que lui seul peut lire.
class Appareil {
  Appareil._(this.nom, this.reseau, this.identite, this.carnet, this.horloge);

  static Future<Appareil> creer(
    String nom, {
    required String userId,
    required int graine,
    HorlogeMobile? horloge,
  }) async {
    // ⚠️ **Chaque appareil a une horloge pilotée.** Les règles de présence se
    // comptent en secondes (fraîcheur, stabilité, oubli) : sans horloge
    // maîtrisée, un test devrait ou bien attendre réellement dix secondes, ou
    // bien ne rien vérifier de ces règles.
    final montre = horloge ?? HorlogeMobile();
    // ⚠️ **L'identité porte l'identifiant de compte**, parce que le jeton d'ami
    // porte le nom de celui qui l'émet depuis le 2026-08-26.
    final identite = await IdentiteMemoire.creer(
      graine: graine,
      userId: userId,
    );
    final carnet = CarnetMemoire();
    final reseau = PeerNetwork(
      identity: identite,
      keyBook: carnet,
      clock: montre.call,
    );
    await reseau.refreshFriends();
    return Appareil._(nom, reseau, identite, carnet, montre);
  }

  final String nom;
  final PeerNetwork reseau;
  final IdentiteMemoire identite;
  final CarnetMemoire carnet;
  final HorlogeMobile horloge;

  /// L'adresse BLE sous laquelle cet appareil est entendu, par défaut.
  String get adresse => 'ADR-$nom';

  /// Une annonce BLE **publique** de [autre] — ce que voit un inconnu.
  ///
  /// ⚠️ Depuis le 2026-08-20, un appareil n'émet plus un identifiant unique
  /// pour tout le monde : il émet un jeton PAR AMI, plus un identifiant public
  /// quand le mode ping est actif. Simuler « je vois quelqu'un » demande donc
  /// de choisir **lequel des deux** — et c'est une bonne chose : le test ne
  /// peut plus confondre les deux publics.
  /// ⚠️ **La date de l'annonce vient de l'horloge PILOTÉE de cet appareil.**
  ///
  /// `PeerNetwork` écarte depuis le 2026-08-28 les annonces plus vieilles que
  /// [PresenceRules.freshFor] — le natif rejoue ce qu'il a capté en l'absence
  /// d'interface, et un souvenir n'est pas une présence. Dater ces scans avec
  /// `DateTime.now()` pendant que le réseau juge avec une horloge simulée
  /// faisait diverger les deux : dès qu'un test avançait sa montre de plus de
  /// cinq secondes, **toutes** ses annonces étaient jetées comme périmées.
  ///
  /// C'est la même règle que partout ailleurs ici : l'instant qu'on observe et
  /// l'instant qui juge doivent venir de la même autorité.
  Future<void> voit(Appareil autre, {int rssi = -60, String? depuis}) async {
    await reseau.onRadioEvent(
      RadioScan(
        at: horloge.instant,
        address: depuis ?? autre.adresse,
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
        at: horloge.instant,
        address: depuis ?? autre.adresse,
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
        at: horloge.instant,
        address: depuis ?? autre.adresse,
        advertId: await autre.identite.jetonPour(identite, slot: null),
        rssi: rssi,
        type: AdvertType.friend,
      ),
    );
  }

  /// Range [autre] dans mon carnet — ce que fait la synchro serveur.
  Future<void> ajouteAmi(Appareil autre) async {
    await carnet.put(
      FriendKeys(
        userId: autre.identite.userId,
        username: autre.nom,
        x25519PublicKey: await autre.identite.x25519PublicKey(),
      ),
    );
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
  late Appareil a;
  late Appareil b;

  setUp(() async {
    a = await Appareil.creer('Alice', userId: 'u-a', graine: 1);
    b = await Appareil.creer('Bob', userId: 'u-b', graine: 2);
  });

  tearDown(() async {
    await a.reseau.dispose();
    await b.reseau.dispose();
  });

  group("Deux formats d'annonce, deux chemins — jamais un seul", () {
    test("le jeton privé de Bob destiné à Carole ne crée AUCUNE détection chez "
        "Alice", () async {
      final carole = await Appareil.creer('Carole', userId: 'u-c', graine: 3);
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
    });

    test("le jeton privé de Bob destiné à Alice, lui, identifie Bob", () async {
      // Alice doit avoir la clé publique de Bob : c'est ce que la synchro
      // serveur transporte, et ce dont dérive le secret de paire.
      await a.ajouteAmi(b);
      await a.reseau.refreshFriends();

      await a.voitAmi(b);
      final session = a.reseau.presence.byUser('u-b');
      expect(session, isNotNull);
      expect(
        session!.snapshot?.userId,
        'u-b',
        reason:
            "Un jeton reconnu doit NOMMER son émetteur : c'est toute la "
            "différence avec le jeton d'une autre paire, écarté juste "
            "au-dessus.",
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

  group("Un scan REJOUÉ n'est pas une présence", () {
    test("une annonce plus vieille que la fraîcheur est écartée", () async {
      // ⚠️ **Le défaut du 2026-08-28.** Le service natif met de côté ce qu'il
      // capte pendant que l'interface est absente (jusqu'à 200 annonces) et le
      // rejoue à son retour. Ces annonces n'avaient **aucune date** : le
      // registre les datait donc de « maintenant ». Un pair croisé il y a des
      // heures réapparaissait « à portée », et — le plus visible — une
      // notification « Le presque… » partait pour quelqu'un de parti depuis
      // longtemps.
      await a.ajouteAmi(b);
      await a.reseau.refreshFriends();

      await a.reseau.onRadioEvent(
        RadioScan(
          at: a.horloge.instant.subtract(const Duration(hours: 3)),
          address: 'ZZ',
          advertId: await b.identite.jetonPour(a.identite),
          rssi: -60,
          type: AdvertType.friend,
        ),
      );

      expect(
        a.reseau.presence.sessions,
        isEmpty,
        reason:
            "Une annonce de trois heures n'ouvre aucune session : ce n'est pas "
            "une observation, c'est un souvenir.",
      );
    });

    test("une annonce de l'instant, elle, passe", () async {
      // Le pendant du test précédent : sans lui, un filtre trop large
      // passerait pour un correctif alors qu'il aurait tout coupé.
      await a.ajouteAmi(b);
      await a.reseau.refreshFriends();

      await a.reseau.onRadioEvent(
        RadioScan(
          at: a.horloge.instant,
          address: 'ZZ',
          advertId: await b.identite.jetonPour(a.identite),
          rssi: -60,
          type: AdvertType.friend,
        ),
      );

      expect(a.reseau.presence.byUser('u-b'), isNotNull);
    });
  });

  test('un inconnu détecté EXISTE, et il RESTE inconnu', () async {
    await a.voit(b);

    // Le pair est là, visible, dans un état qui se dit — au lieu du « personne
    // à proximité » de l'ancienne couche.
    expect(a.reseau.presence.length, 1);
    expect(a.reseau.presence.identifiedCount, 0);

    // ⚠️ **Et il le reste, quoi qu'il arrive** : depuis le 2026-08-27, la radio
    // n'a plus aucun moyen d'apprendre qui il est. Le stade « poignée de main
    // en cours » a disparu avec le transport ; son identité, si elle vient,
    // viendra du serveur (`ping_nearby`) et n'entrera jamais par ici.
    for (var i = 0; i < 20; i++) {
      a.horloge.avance(const Duration(seconds: 1));
      await a.voit(b);
    }
    expect(a.reseau.presence.peers.single.stage, PresenceStage.detected);
  });

  test('un ami est reconnu à son jeton de paire, SANS aucun échange', () async {
    // Chacun a la clé PUBLIQUE de l'autre : c'est tout ce que la synchro
    // serveur transporte désormais. Le secret, lui, se dérive des deux côtés.
    await a.ajouteAmi(b);
    await a.reseau.refreshFriends();

    await a.voitAmi(b);

    // Reconnu, donc identifié — sans le moindre échange, et **dès la première
    // annonce** : le seuil anti-passant ne s'applique qu'aux croisements, pas à
    // la reconnaissance, qui ne coûte rien.
    expect(a.reseau.presence.byUser('u-b'), isNotNull);
    expect(a.reseau.presence.byUser('u-b')!.stage, PresenceStage.identified);
  });

  test("le jeton d'un ami n'est lisible QUE par lui", () async {
    // ⚠️ **La propriété qui remplace toute la mécanique de rotation.**
    //
    // Avec une clé de diffusion unique, tout ami pouvait reconnaître l'annonce
    // — donc la retirer à l'un obligeait à la changer pour tous. Ici, le jeton
    // que Bob émet à l'intention d'Alice ne veut rien dire pour Carole, même si
    // Carole est aussi son amie.
    final c = await Appareil.creer('Carole', userId: 'u-c', graine: 9);
    addTearDown(c.reseau.dispose);

    await a.ajouteAmi(b);
    await c.ajouteAmi(b);
    await a.reseau.refreshFriends();
    await c.reseau.refreshFriends();

    // Bob émet le jeton destiné à Alice. Carole le capte aussi — la radio est
    // publique — mais il ne lui dit rien.
    final pourAlice = await b.identite.jetonPour(a.identite);
    await c.reseau.onRadioEvent(
      RadioScan(
        at: c.horloge.instant,
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
        at: a.horloge.instant,
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
    final c = await Appareil.creer('Carole', userId: 'u-c', graine: 9);
    addTearDown(c.reseau.dispose);

    await a.ajouteAmi(b);
    await a.ajouteAmi(c);
    await a.reseau.refreshFriends();

    await a.voitAmi(b);
    expect(a.reseau.presence.byUser('u-b'), isNotNull);

    // Bob est retiré. Carole ne doit rien perdre au passage.
    await a.carnet.retire('u-b');
    await a.reseau.refreshFriends();

    // ⚠️ **La session déjà ouverte perd son NOM, tout de suite** (2026-08-28).
    // Sans ça, l'identité survivait au retrait jusqu'à l'expiration de la
    // session : la tuile continuait de nommer Bob, et l'écran lui proposait un
    // bouton « demander en ami » sur quelqu'un que la radio n'a plus le droit
    // de reconnaître.
    expect(
      a.reseau.presence.byUser('u-b'),
      isNull,
      reason: "Une identité vient du carnet ; elle s'en va avec lui.",
    );

    await a.reseau.onRadioEvent(
      RadioScan(
        at: a.horloge.instant,
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
        at: a.horloge.instant,
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
    await a.ajouteAmi(b);

    // ⚠️ **Aucun `refreshFriends()` explicite ici.** C'est tout le sujet : le
    // carnet prévient, l'index se reconstruit seul. Si on l'appelait à la main,
    // ce test ne prouverait rien — il vérifierait qu'une méthode appelée fait
    // ce qu'elle dit, pas que quelqu'un l'appelle au bon moment.
    await jusqua(() {
      unawaited(a.voitAmi(b));
      return a.reseau.presence.byUser('u-b')?.stage == PresenceStage.identified;
    });
  });

  test('la radio qui s\'arrête vide la présence', () async {
    await a.ajouteAmi(b);
    await a.reseau.refreshFriends();
    await a.voitAmi(b);
    expect(a.reseau.presence.identifiedCount, 1);

    await a.reseau.onRadioEvent(const RadioStatusEvent(RadioAdapterOff()));

    // ⚠️ Garder la liste présenterait un **souvenir** comme une observation —
    // exactement ce que tout ce chantier supprime. Et ce n'est pas cosmétique :
    // `isPresent` est le point d'entrée de la barrière de présence physique.
    expect(a.reseau.presence.length, 0);
  });
}
