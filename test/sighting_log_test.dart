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

  test('drain rend tout et vide — une seule vérité à la fois', () {
    final log = SightingLog();
    log.observe('u-b', t, band: ProximityBand.contact);
    log.observe('u-c', t);

    final lot = log.drain();
    expect(lot.length, 2);
    expect(log.length, 0);

    // Après vidage, le même constat repart : c'est ce qui permet de retenter
    // un envoi perdu sans le dédoubler dans la file.
    expect(log.observe('u-b', t, band: ProximityBand.contact), isTrue);
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
