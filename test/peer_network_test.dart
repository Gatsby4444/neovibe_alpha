import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/peer_network.dart';
import 'package:neovibe/features/proximity/net/presence_tracker.dart';
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
  Appareil._(this.nom, this.reseau, this.radio, this.identite, this.carnet);

  static Future<Appareil> creer(
    String nom, {
    required String userId,
    required int graine,
    required RadioSimulee radio,
    DateTime Function()? horloge,
    Duration profilLent = Duration.zero,
  }) async {
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
      clock: horloge,
    );
    radio.reseau = reseau;
    await reseau.refreshFriends();
    return Appareil._(nom, reseau, radio, identite, carnet);
  }

  final String nom;
  final PeerNetwork reseau;
  final RadioSimulee radio;
  final IdentiteMemoire identite;
  final CarnetMemoire carnet;

  /// Simule une annonce BLE de [autre] vue par cet appareil.
  Future<void> voit(Appareil autre, {int rssi = -60}) async {
    await reseau.onRadioEvent(
      RadioScan(
        address: autre.radio.adresse,
        advertId: await autre.identite.currentRotatingId(),
        rssi: rssi,
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
    // Les deux se voient : l'un des deux initie (comparaison des ID diffusés).
    await a.voit(b);
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

    // Reconnu, donc identifié — sans le moindre échange. C'est tout l'intérêt
    // de l'ID rotatif, et c'est ce qui se vérifie ici : une IDENTITÉ.
    expect(a.reseau.presence.byUser('u-b'), isNotNull);
    expect(a.reseau.presence.byUser('u-b')!.stage, PresenceStage.identified);
    expect(radioA.connexions, isEmpty, reason: 'aucun lien ne doit s\'ouvrir');
  });

  test('des clés arrivées APRÈS le démarrage sont prises en compte', () async {
    // ⚠️ **Le défaut du 2026-08-17, en test.**
    //
    // `PeerNetwork.start()` construisait l'index rotatif, **puis** la synchro
    // téléchargeait les clés — sans que rien ne le dise. L'index n'était
    // reconstruit qu'au changement de créneau, toutes les 15 minutes, et depuis
    // un cache périmé : donc jamais. Un ami restait un inconnu jusqu'au
    // prochain lancement de l'app, et l'écran lui proposait « demander à se
    // connecter ».
    //
    // Ici le réseau tourne déjà, le carnet est vide, et les clés arrivent
    // ensuite — exactement l'ordre réel.
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

    // Reconnu à son ID rotatif : l'index a bien été reconstruit après coup.
    // Et une fois reconnu, un ami n'ouvre plus aucun lien — c'est la propriété
    // que la reconnaissance silencieuse doit garantir.
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
    final horloge = HorlogeMobile();
    final radioP = RadioSimulee('PP');
    final radioQ = RadioSimulee('QQ');
    radioP.pair = radioQ;
    radioQ.pair = radioP;

    final p = await Appareil.creer(
      'P',
      userId: 'u-p',
      graine: 5,
      radio: radioP,
      horloge: horloge.call,
    );
    final q = await Appareil.creer(
      'Q',
      userId: 'u-q',
      graine: 6,
      radio: radioQ,
    );

    await p.voit(q);

    if (radioP.connexions.isEmpty) {
      // P est le côté passif : il a armé son échéance.
      horloge.avance(PeerNetwork.passiveFallback + const Duration(seconds: 1));
      await p.reseau.tick();
    }
    expect(radioP.connexions, isNotEmpty);

    await p.reseau.dispose();
    await q.reseau.dispose();
  });

  test('la radio qui s\'arrête vide la présence', () async {
    await a.voit(b);
    await b.voit(a);
    await jusqua(() => a.reseau.presence.identifiedCount == 1);

    await a.reseau.onRadioEvent(const RadioStatusEvent(RadioAdapterOff()));

    expect(a.reseau.presence.length, 0);
  });

  test(
    'un profil signé par une AUTRE clé que la poignée de main est rejeté',
    () async {
      await a.voit(b);
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
    // negociee. L'emetteur chiffrait avec l'ancienne cle, le destinataire
    // dechiffrait avec la nouvelle, et le message disparaissait sans un mot.
    await a.voit(b);
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

  test('cesser d\'ENTENDRE un pair ne coupe pas la session qui le relie', () async {
    // ⚠️ **Le message fantôme qui restait après la v0.9.111.**
    //
    // Deux mesures indépendantes portent le même nom dans la tête, et ce sont
    // deux choses différentes :
    //
    // - **entendre** un pair, c'est recevoir son annonce — une diffusion non
    //   fiable, qu'un téléphone en poche, un canal occupé ou un écran éteint
    //   font manquer plusieurs fois de suite ;
    // - **être relié** à un pair, c'est tenir une connexion GATT et un canal
    //   chiffré — qui, lui, ne bouge pas parce qu'une annonce s'est perdue.
    //
    // `prune()` traitait la première comme une preuve de la seconde : passée la
    // période de grâce, il rendait le pair « parti », et `tick()` détruisait le
    // lien ET le canal — **sans rien couper côté radio**. En face, rien n'avait
    // changé : le canal restait établi, l'envoi réussissait sans erreur, et la
    // trame arrivait sur un lien devenu sans canal, où `_handleFrame` la jetait
    // en silence.
    //
    // Émetteur satisfait, destinataire muet : la signature exacte du défaut
    // décrit par Jay.
    //
    // ⚠️ **`hasLiveLink` existait déjà** — posé le 2026-08-16 pour empêcher la
    // FUSION d'adresses d'abandonner une session vivante. La cause avait donc
    // été traitée à un endroit sur deux : `prune`, l'autre porte de sortie, ne
    // le consultait pas.
    final horloge = HorlogeMobile();
    final radioP = RadioSimulee('PP');
    final radioQ = RadioSimulee('QQ');
    radioP.pair = radioQ;
    radioQ.pair = radioP;

    // Seul P a une horloge pilotée : c'est LUI qui cesse d'entendre.
    final p = await Appareil.creer(
      'P',
      userId: 'u-p',
      graine: 7,
      radio: radioP,
      horloge: horloge.call,
    );
    final q = await Appareil.creer(
      'Q',
      userId: 'u-q',
      graine: 8,
      radio: radioQ,
    );

    await p.voit(q);
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

    // P n'entend plus l'annonce de Q au-delà de la période de grâce. Le lien,
    // lui, est intact — et Q, qui entend toujours P, n'a aucune raison de s'en
    // douter.
    horloge.avance(PresenceTracker.gracePeriod + const Duration(seconds: 5));
    await p.reseau.tick();

    // L'envoi de Q **réussit** : son canal est établi, son lien est vivant.
    // C'est précisément ce succès qui rend le défaut invisible des deux côtés.
    await q.reseau.sendToUser(
      'u-p',
      ChatMessage(id: 'm', text: 'tu me reçois ?', sentAt: DateTime.now()),
    );

    await jusqua(() => recus.isNotEmpty);
    expect(recus.single, 'tu me reçois ?');

    await p.reseau.dispose();
    await q.reseau.dispose();
  });

  // ------------------------------------------------------------------
  // Reconstruction d'une session perdue d'un seul côté
  // ------------------------------------------------------------------
  //
  // ⚠️ **La quatrième cause de message fantôme, mesurée le 2026-08-17.**
  //
  // Relevé croisé sur les deux appareils de Jay : la tablette ferme une session
  // ÉTABLIE (fusion d'adresses), et 2 minutes plus tard le smartphone consigne
  // `second lien ignoré (canal established)` puis **`déchiffrement refusé` aux
  // compteurs 0 et 1**.
  //
  // Les compteurs 0 et 1 sont la signature d'une **session neuve** : le pair
  // avait reconstruit son canal. Nous, non — et la règle « un canal établi ne
  // se remplace jamais », posée la veille pour corriger un AUTRE défaut,
  // interdisait de le suivre.
  //
  // Ces deux tests couvrent les deux cas, selon que le côté qui reconstruit
  // reprend le même rôle ou l'inverse. Sur le terrain, c'est le hasard qui
  // tranche — d'où un défaut intermittent.

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
    // Le balayage des certificats tourne toutes les 2 s et n'attend que « canal
    // établi ». Or l'identité arrive APRÈS la poignée de main : le certificat
    // pouvait donc doubler notre profil. En face, on ne savait pas encore qui
    // parlait, et la trame était **jetée**.
    //
    // Le coût était pire que la trame perdue : `_certified` était déjà marqué,
    // donc **aucune nouvelle tentative** — le croisement était perdu pour de
    // bon, en silence, alors que c'est la fondation des streaks.
    //
    // On ne peut pas régler ça en face : c'est l'ordre d'ÉMISSION qui décide.
    final radio1 = RadioSimulee('11');
    final radio2 = RadioSimulee('22');
    radio1.pair = radio2;
    radio2.pair = radio1;
    // ⚠️ **Le profil de Un est LENT** — c'est la reproduction fidèle de ce qui
    // s'est passé chez Jay : `myProfile()` lit un provider Riverpod, parfois
    // adossé au réseau. Le canal chiffre bien avant que la réponse n'arrive.
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
    // déjà eu lieu quand on commence à regarder, et le test ne peut plus voir
    // l'ordre — il ne pourrait contenir que la moitié de la réponse.
    final ordre = <String>[];
    deux.reseau.events.listen((e) {
      if (e is PeerIdentified) ordre.add('identité');
      if (e is PeerMessageReceived) ordre.add('message');
    });

    await radio1.connect(radio2.adresse);

    // Dès que le canal chiffre, on envoie — c'est exactement ce que fait le
    // balayage des certificats, qui n'attend rien de plus.
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

        // ⚠️ **Deux perd sa session, et Un n'en sait rien.** C'est exactement ce
        // que fait la fusion d'adresses : elle ferme le canal localement, sans
        // que le pair l'apprenne.
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
