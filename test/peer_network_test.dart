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
    final identite = await IdentiteMemoire.creer(graine: graine);
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

  /// Une annonce BLE de [autre], vue une fois.
  Future<void> voit(Appareil autre, {int rssi = -60, String? depuis}) async {
    await reseau.onRadioEvent(
      RadioScan(
        address: depuis ?? autre.radio.adresse,
        advertId: await autre.identite.currentRotatingId(),
        rssi: rssi,
      ),
    );
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

  test('deux inconnus se découvrent, se révèlent, et se parlent', () async {
    // Les deux se voient DURABLEMENT : l'un des deux initie (comparaison des ID
    // diffusés).
    await a.voitLongtemps(b);
    await b.voitLongtemps(a);

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

  test('un passant ne coûte AUCUNE connexion', () async {
    // ⚠️ **L'objection de Jay du 2026-08-18, en test.**
    //
    // Le code ouvrait une connexion GATT dès la PREMIÈRE annonce d'un inconnu :
    // une poignée de main complète — connexion, négociation de MTU, découverte
    // de services, deux signatures — pour quelqu'un qui traverse le couloir.
    //
    // On voit le pair plusieurs fois, mais brièvement : rien ne doit s'ouvrir.
    for (var i = 0; i < 3; i++) {
      await a.voit(b);
      a.horloge.avance(const Duration(seconds: 1));
    }
    expect(a.reseau.presence.length, 1, reason: 'il est bien détecté');
    expect(radioA.connexions, isEmpty, reason: 'mais il ne coûte rien');

    // Il s'installe : là, on ouvre.
    //
    // ⚠️ **Le rôle n'est pas choisissable**, et ce test l'a appris à ses
    // dépens : l'initiateur vient de la comparaison des ID rotatifs, qui
    // dépendent du créneau de 15 minutes. Écrit en supposant qu'Alice initie,
    // ce test était vert dans un créneau et rouge dans le suivant — le piège
    // que `quel que soit le rôle…` documente depuis le 2026-08-16.
    await a.voitLongtemps(b);
    if (radioA.connexions.isEmpty) {
      a.horloge.avance(
        PeerNetwork.passiveFallback + const Duration(seconds: 1),
      );
      await a.reseau.tick();
    }
    await jusqua(() => radioA.connexions.isNotEmpty);
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

  test('un ami est reconnu à son ID rotatif, SANS aucun échange', () async {
    // Chacun a la clé de diffusion de l'autre : c'est ce que fait la synchro
    // serveur quand les deux sont amis.
    await a.carnet.put(
      FriendKeys(
        userId: 'u-b',
        username: 'Bob',
        edPublicKey: await b.identite.edPublicKey(),
        broadcastKey: await b.identite.broadcastKey(),
      ),
    );
    await a.reseau.refreshFriends();

    // La radio d'en face est morte : aucun lien ne peut s'ouvrir.
    radioB.injoignable = true;
    await a.voit(b);

    // Reconnu, donc identifié — sans le moindre échange, et **dès la première
    // annonce** : le seuil anti-passant ne s'applique qu'aux inconnus, puisque
    // reconnaître un ami ne coûte rien.
    expect(a.reseau.presence.byUser('u-b'), isNotNull);
    expect(a.reseau.presence.byUser('u-b')!.stage, PresenceStage.identified);
    expect(radioA.connexions, isEmpty, reason: 'aucun lien ne doit s\'ouvrir');
  });

  test('un ami reconnu sous sa CLÉ PRÉCÉDENTE reste un ami', () async {
    // ⚠️ **La contrepartie de la rotation, en test.**
    //
    // La clé de diffusion tourne tous les 7 jours. Si l'index d'en face
    // n'indexait que la clé courante, chaque rotation rendrait son auteur
    // invisible à tous ses amis jusqu'à leur prochaine synchronisation.
    final ancienne = await b.identite.broadcastKey();
    await b.identite.rotateBroadcast(keepPrevious: true);

    // Nous n'avons pas encore resynchronisé : notre carnet porte l'ANCIENNE en
    // clé courante, et la nouvelle nous est inconnue.
    await a.carnet.put(
      FriendKeys(
        userId: 'u-b',
        username: 'Bob',
        edPublicKey: await b.identite.edPublicKey(),
        broadcastKey: ancienne,
      ),
    );
    await a.reseau.refreshFriends();
    radioB.injoignable = true;

    // Bob diffuse désormais avec sa NOUVELLE clé.
    await a.voit(b);
    expect(
      a.reseau.presence.byUser('u-b'),
      isNull,
      reason: 'sans la clé neuve, il est bien un inconnu',
    );

    // La synchro arrive : le carnet porte les deux clés.
    await a.carnet.put(
      FriendKeys(
        userId: 'u-b',
        username: 'Bob',
        edPublicKey: await b.identite.edPublicKey(),
        broadcastKey: await b.identite.broadcastKey(),
        previousBroadcastKey: ancienne,
      ),
    );
    await a.reseau.refreshFriends();

    // Reconnu sous la neuve…
    await a.voit(b, depuis: 'CC');
    expect(a.reseau.presence.byUser('u-b'), isNotNull);
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
        broadcastKey: await b.identite.broadcastKey(),
      ),
    );

    // ⚠️ **Aucun `refreshFriends()` explicite ici.** C'est tout le sujet : le
    // carnet prévient, l'index se reconstruit seul. Si on l'appelait à la main,
    // ce test ne prouverait rien — il vérifierait qu'une méthode appelée fait
    // ce qu'elle dit, pas que quelqu'un l'appelle au bon moment.
    radioB.injoignable = true;
    await jusqua(() {
      unawaited(a.voit(b));
      return a.reseau.presence.byUser('u-b')?.stage == PresenceStage.identified;
    });

    // Une fois reconnu, un ami n'ouvre plus aucun lien.
    final avant = radioA.connexions.length;
    await a.voit(b);
    expect(
      radioA.connexions.length,
      avant,
      reason: 'un ami reconnu n\'ouvre aucun lien',
    );
  });

  test('quel que soit le rôle, le lien finit par s\'ouvrir', () async {
    // ⚠️ **Le rôle n'est pas choisissable** : il vient de la comparaison des ID
    // rotatifs, qui dépendent du créneau horaire. Un test qui supposerait un
    // rôle serait vert un jour et rouge le lendemain — pire qu'absent.
    //
    // On teste donc la PROPRIÉTÉ, valable dans les deux cas : que P initie tout
    // de suite, ou qu'il attende, la paire se rencontre. C'est exactement ce
    // que l'ancienne couche ne garantissait pas — le côté passif attendait
    // indéfiniment un rendez-vous qui n'aurait jamais lieu.
    final radioP = RadioSimulee('PP');
    final radioQ = RadioSimulee('QQ');
    radioP.pair = radioQ;
    radioQ.pair = radioP;

    final p = await Appareil.creer(
      'P',
      userId: 'u-p',
      graine: 5,
      radio: radioP,
    );
    final q = await Appareil.creer(
      'Q',
      userId: 'u-q',
      graine: 6,
      radio: radioQ,
    );

    await p.voitLongtemps(q);

    if (radioP.connexions.isEmpty) {
      // P est le côté passif : il a armé son échéance.
      p.horloge.avance(
        PeerNetwork.passiveFallback + const Duration(seconds: 1),
      );
      await p.reseau.tick();
    }
    expect(radioP.connexions, isNotEmpty);

    await p.reseau.dispose();
    await q.reseau.dispose();
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
    await a.voitLongtemps(b);
    await b.voitLongtemps(a);
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
      await a.voitLongtemps(b);
      await b.voitLongtemps(a);
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
    await a.voitLongtemps(b);
    await b.voitLongtemps(a);
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

    await p.voitLongtemps(q);
    await q.voitLongtemps(p);
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

      await p.voitLongtemps(q);
      await q.voitLongtemps(p);
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
          broadcastKey: await b.identite.broadcastKey(),
        ),
      );
      await a.reseau.refreshFriends();

      // Bob est reconnu, puis on ouvre un lien (comme le ferait un certificat).
      await a.voit(b);
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
      await a.voit(b, depuis: 'ZZ');
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
