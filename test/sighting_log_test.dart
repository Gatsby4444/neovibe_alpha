import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/distance_estimate.dart';
import 'package:neovibe/features/proximity/net/sighting_log.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// Ce que ces tests protègent : **le coût du constat**, pas sa justesse.
///
/// La règle de réciprocité, elle, est tenue en base et vérifiée en base (voir le
/// rapport de session : constat unilatéral → 0 croisement, constat mutuel →
/// croisement, non-ami et antidatage refusés). Un test Dart ne pourrait que
/// répéter ce que le client croit, pas ce que le serveur impose.
///
/// Ce qui se teste ici est ce que le client, lui, peut casser tout seul :
/// envoyer neuf mille fois le même constat, ou grossir sans fin.
void main() {
  final t = DateTime.utc(2026, 8, 20, 14, 7);
  final creneau = ProximityIdentity.slotIndex(t);

  test('un ami immobile ne produit qu\'UN constat par créneau', () {
    final log = SightingLog();

    // ~10 annonces par seconde pendant tout le créneau : c'est le régime réel.
    var nouveaux = 0;
    for (var i = 0; i < 9000; i++) {
      if (log.observe('u-b', t, band: ProximityBand.close)) nouveaux++;
    }

    expect(nouveaux, 1);
    expect(log.length, 1);
  });

  test('le créneau suivant en produit un nouveau', () {
    final log = SightingLog();
    expect(log.observe('u-b', t), isTrue);
    expect(
      log.observe('u-b', t.add(ProximityIdentity.slotDuration)),
      isTrue,
      reason:
          'sinon un ami croisé toute la journée ne produirait qu\'un '
          'seul croisement, le premier',
    );
    expect(log.length, 2);
  });

  test('deux amis au même créneau font deux constats', () {
    final log = SightingLog();
    log.observe('u-b', t);
    log.observe('u-c', t);
    expect(log.length, 2);
  });

  test('le journal est borné : il ne grossit pas sans fin', () {
    // ⚠️ Une mémoire non bornée dans un objet qui vit des jours est une fuite,
    // et elle ne se voit qu'au bout de longtemps.
    final log = SightingLog(maxPending: 3);
    for (var i = 0; i < 50; i++) {
      log.observe('u-$i', t);
    }
    expect(log.length, 3);
  });

  test('drain rend tout et vide la file d\'attente', () {
    final log = SightingLog();
    log.observe('u-b', t, band: ProximityBand.contact);
    log.observe('u-c', t);

    final lot = log.drain();
    expect(lot.length, 2);
    expect(log.length, 0);
  });

  /// ## 🔴 Ce test AFFIRMAIT le défaut, avec un motif crédible
  ///
  /// Il disait : *« après vidage, le même constat repart : c'est ce qui permet
  /// de retenter un envoi perdu sans le dédoubler dans la file »*, et il
  /// attendait `isTrue`.
  ///
  /// **Le motif était faux.** Retenter est le travail de la file d'envoi, qui
  /// compte ses tentatives (`ProximitySync.maxAttempts`) ; ré-observer
  /// n'entraîne aucune nouvelle tentative — ça ajoute une **seconde** entrée
  /// pour le même couple (personne, créneau), que le serveur déduplique de
  /// toute façon.
  ///
  /// Conséquence mesurée sur l'appareil de Jay le 2026-08-28 : le balayage
  /// tourne toutes les 2 s, donc le constat redevenait « nouveau » 2 s plus
  /// tard — **50 synchronisations pour 92 secondes** de présence d'un ami, soit
  /// ~200 appels serveur pour **2 lignes** écrites en base.
  ///
  /// ⚠️ **La leçon** : un test qui affirme un comportement le rend intouchable.
  /// Celui-ci a fait passer le défaut pour une intention pendant tout un
  /// chantier d'audit — et sa justification était plus convaincante que le code.
  test(
    'un constat déjà confié à la file ne repart pas au balayage suivant',
    () {
      final log = SightingLog();
      log.observe('u-b', t, band: ProximityBand.contact);
      log.drain();

      expect(
        log.observe('u-b', t, band: ProximityBand.contact),
        isFalse,
        reason: 'il est dans la file, pas oublié',
      );
      expect(log.length, 0);
    },
  );

  test('le balayage toutes les 2 s ne produit QU\'UN envoi par créneau', () {
    final log = SightingLog();

    // ⚠️ **On part du DÉBUT du créneau, et ce n'est pas cosmétique.** Partir de
    // `t` (14 h 07) faisait franchir la frontière de 14 h 15 à la 240e
    // itération : le test attendait 1 et mesurait 2, en ayant raison. Un test
    // qui chevauche la borne qu'il teste mesure la borne, pas la règle.
    final debutDuCreneau = DateTime.fromMillisecondsSinceEpoch(
      creneau * ProximityIdentity.slotDuration.inMilliseconds,
      isUtc: true,
    );

    // Le régime réel : un ami immobile, un balayage toutes les 2 secondes
    // pendant tout le créneau de 15 minutes.
    var envois = 0;
    for (var i = 0; i < 450; i++) {
      final maintenant = debutDuCreneau.add(Duration(seconds: i * 2));
      log.observe('u-b', maintenant, band: ProximityBand.close);
      if (log.length > 0) {
        log.drain();
        envois++;
      }
    }

    expect(
      envois,
      1,
      reason:
          'chaque envoi coûtait un élément de file + un appel serveur ; '
          '450 balayages ne doivent en produire qu\'un',
    );
  });

  test('le souvenir des envois se purge, il ne grossit pas sans fin', () {
    final log = SightingLog();
    // Cinquante créneaux d'affilée avec le même ami : sans purge, la table des
    // clés déjà parties garderait cinquante entrées pour une personne.
    for (var i = 0; i < 50; i++) {
      final quand = t.add(ProximityIdentity.slotDuration * i);
      expect(log.observe('u-b', quand), isTrue);
      log.drain();
    }
    // Un créneau très ancien redevient possible : la preuve que rien n'est
    // conservé au-delà de la marge d'un créneau.
    expect(log.observe('u-b', t), isTrue);
  });

  test('ce qui part au serveur ne contient QUE le créneau et la bande', () {
    final json = Sighting(
      peerId: 'u-b',
      slot: creneau,
      band: ProximityBand.close,
    ).toJson();

    expect(json.keys.toSet(), {'peer', 'slot', 'band'});
    expect(json['slot'], creneau);
    expect(
      json.values.any((v) => v.toString().contains('.')),
      isFalse,
      reason: 'aucune distance en mètres ne doit fuiter vers le serveur',
    );
  });

  test('un constat sans bande reste valide', () {
    final json = Sighting(peerId: 'u-b', slot: creneau).toJson();
    expect(json.containsKey('band'), isFalse);
    expect(Sighting.fromJson(json).band, isNull);
  });

  test('aller-retour JSON sans perte', () {
    final avant = Sighting(
      peerId: 'u-b',
      slot: creneau,
      band: ProximityBand.room,
    );
    final apres = Sighting.fromJson(avant.toJson());
    expect(apres.peerId, avant.peerId);
    expect(apres.slot, avant.slot);
    expect(apres.band, avant.band);
    expect(apres.key, avant.key);
  });
}
