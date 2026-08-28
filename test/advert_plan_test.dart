import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/advert_plan.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// Ce que ces tests protègent : **le point H**.
///
/// Le jeton diffusé dépend du créneau de 15 min. Tant que c'était un minuteur
/// Dart qui poussait le suivant, l'identifiant se figeait dès qu'Android
/// détruisait l'activité — et l'appareil devenait invisible pour tous ses amis
/// sans qu'aucune erreur ne soit levée.
///
/// La correction est de calculer des heures d'avance et de les remettre au
/// natif. Ce qui doit donc être vrai, et ce qui se teste ici :
///
/// 1. le plan couvre réellement l'horizon annoncé (sinon le trou revient, avec
///    juste un délai plus long) ;
/// 2. chaque créneau porte le même nombre de jetons — c'est ce qui autorise le
///    tampon à plat envoyé au natif ;
/// 3. le mode ping ajoute l'identifiant public, et **rien d'autre** ;
/// 4. un jeton n'est lisible que par son destinataire.
void main() {
  Uint8List secret(int graine) =>
      Uint8List.fromList(List.generate(32, (i) => (i * 7 + graine) % 256));

  const planner = AdvertPlanner();
  final slot = ProximityIdentity.slotIndex(DateTime.now());

  /// Mon identifiant de compte. **Le jeton d'ami porte le nom de celui qui
  /// l'émet** depuis le 2026-08-26 : sans lui, les deux sens seraient de
  /// nouveau confondus (voir [ProximityIdentity.pairToken]).
  const moi = 'u-moi';

  group('le plan d\'émission', () {
    /// ## 🔴 Deux horizons dans un seul plan (2026-08-28)
    ///
    /// Consigne de Jay : *« les 12 heures, on s'en fout pour le ping inconnus,
    /// c'est uniquement utile pour le ping entre amis »*.
    ///
    /// Un jeton d'ami reste **utile** douze heures : l'ami d'en face le
    /// reconnaît tout seul, sans réseau, app fermée. Un identifiant public ne
    /// vaut **rien** sans la balise qui le nomme au serveur — et cette balise
    /// meurt cinq minutes après la dernière fois que l'app était à l'écran.
    ///
    /// ⚠️ **Le défaut ne levait rien** : le téléphone criait un identifiant
    /// public jusqu'à douze heures alors que plus personne ne pouvait le
    /// nommer. De la batterie et une émission radio pour rien.
    test(
      "l'identifiant public a un horizon BORNÉ, le jeton d'ami non",
      () async {
        final plan = await planner.plan(
          secrets: {'u-a': secret(1)},
          meUserId: moi,
          fromSlot: slot,
          slots: 48, // 12 h
          pingSeed: secret(9),
        );

        final publics = plan.tokens.where((t) => t.audience == null).toList();
        final amis = plan.tokens.where((t) => t.audience != null).toList();

        expect(
          amis.length,
          48,
          reason: "le jeton d'ami couvre toute la nuit — c'est le point H",
        );
        expect(
          publics.length,
          publicHorizon.inMilliseconds ~/
              ProximityIdentity.slotDuration.inMilliseconds,
          reason: "l'identifiant public s'arrête bien avant",
        );
        expect(
          publics.length,
          lessThan(amis.length),
          reason:
              'sinon les deux horizons sont confondus, et le défaut revient',
        );
      },
    );

    test("l'horizon public dépasse la cadence de redépôt du plan", () {
      // ⚠️ Le plan est redéposé toutes les heures (`_rotation`). Un horizon
      // public plus court laisserait quelqu'un en train de se servir de l'app
      // cesser d'être découvrable en attendant le tour suivant.
      expect(publicHorizon, greaterThan(const Duration(hours: 1)));
    });
    test('couvre tout l\'horizon annoncé', () async {
      final plan = await planner.plan(
        secrets: {'u-a': secret(1), 'u-b': secret(2)},
        meUserId: moi,
        fromSlot: slot,
        slots: 48,
      );

      expect(plan.fromSlot, slot);
      expect(plan.toSlot, slot + 47);
      expect(plan.forSlot(slot), isNotEmpty);
      expect(plan.forSlot(slot + 47), isNotEmpty);
      expect(
        plan.forSlot(slot + 48),
        isEmpty,
        reason:
            'un plan qui prétend couvrir plus qu\'il ne porte est le '
            'point H avec un délai plus long',
      );
      expect(plan.tokens.length, 48 * 2);
    });

    test('porte le MÊME nombre de jetons à chaque créneau', () async {
      // ⚠️ C'est l'invariant sur lequel repose le tampon à plat envoyé au natif.
      // S'il tombait, le natif lirait les jetons décalés — sans erreur, et sans
      // que personne ne le reconnaisse.
      final plan = await planner.plan(
        secrets: {'u-a': secret(1), 'u-b': secret(2), 'u-c': secret(3)},
        meUserId: moi,
        fromSlot: slot,
        slots: 5,
        pingSeed: secret(9),
      );
      for (var s = slot; s <= plan.toSlot; s++) {
        expect(
          plan.forSlot(s).length,
          4,
          reason: '3 amis + l\'identifiant public',
        );
      }
    });

    test('sans mode ping, aucun identifiant public n\'est émis', () async {
      final plan = await planner.plan(
        secrets: {'u-a': secret(1)},
        meUserId: moi,
        fromSlot: slot,
        slots: 2,
      );
      expect(plan.tokens.every((t) => t.audience != null), isTrue);
    });

    test(
      'le mode ping AJOUTE l\'identifiant public sans retirer les amis',
      () async {
        // Consigne de Jay (2026-08-20) : le ping et le croisement entre amis sont
        // deux choses distinctes qui partagent la même radio. Activer l'un ne doit
        // jamais éteindre l'autre.
        final avec = await planner.plan(
          secrets: {'u-a': secret(1)},
          meUserId: moi,
          fromSlot: slot,
          slots: 1,
          pingSeed: secret(9),
        );
        expect(avec.forSlot(slot).where((t) => t.audience == null).length, 1);
        expect(avec.forSlot(slot).where((t) => t.audience == 'u-a').length, 1);
      },
    );

    test('sans ami ni ping, le plan est vide plutôt que faux', () async {
      final plan = await planner.plan(
        secrets: const {},
        meUserId: moi,
        fromSlot: slot,
        slots: 4,
      );
      expect(plan.isEmpty, isTrue);
    });

    test('chaque créneau produit des jetons différents', () async {
      final plan = await planner.plan(
        secrets: {'u-a': secret(1)},
        meUserId: moi,
        fromSlot: slot,
        slots: 3,
      );
      final vus = plan.tokens
          .map((t) => ProximityIdentity.hex(t.bytes))
          .toSet();
      expect(
        vus.length,
        3,
        reason:
            'sinon le pistage d\'un créneau à l\'autre '
            'redeviendrait trivial',
      );
    });
  });

  group('le SENS du jeton d\'ami — la panne du 2026-08-26', () {
    // Jusqu'à cette date le jeton valait `HMAC(secret, slot)`, donc la MÊME
    // valeur des deux côtés. Le filtre anti-auto-détection du natif jetait
    // alors toutes les annonces de l'ami, comptées en `selfScans` : le
    // croisement en BLE était structurellement impossible, sans qu'aucune
    // erreur ne soit levée. Ces trois tests sont ce qui l'empêche de revenir.

    test('ce que J\'ÉMETS n\'est PAS ce que J\'ATTENDS', () async {
      final s = secret(1);
      final emis = await ProximityIdentity.pairToken(s, slot, emitter: moi);
      final attendu = await ProximityIdentity.pairToken(
        s,
        slot,
        emitter: 'u-a',
      );
      expect(
        emis,
        isNot(attendu),
        reason:
            'si ces deux valeurs sont égales, le filtre anti-soi du natif '
            'jette l\'ami — c\'est exactement la panne du 2026-08-26',
      );
    });

    test('le plan émet MON sens, la table écoute le SIEN', () async {
      final secrets = {'u-a': secret(1)};
      final plan = await planner.plan(
        secrets: secrets,
        meUserId: moi,
        fromSlot: slot,
        slots: 1,
      );
      final table = await planner.table(secrets: secrets, slot: slot);

      final emis = plan.forSlot(slot).single.bytes;
      expect(
        table.match(emis),
        isNull,
        reason: 'notre propre annonce ne doit jamais être prise pour l\'ami',
      );
      expect(
        table.match(
          await ProximityIdentity.pairToken(
            secrets['u-a']!,
            slot,
            emitter: 'u-a',
          ),
        ),
        'u-a',
        reason: 'et la sienne doit être reconnue',
      );
    });

    test('les deux appareils calculent la même paire de jetons', () async {
      // Le secret est symétrique : chacun peut donc calculer les DEUX sens.
      // C'est ce qui rend la correction possible sans échange supplémentaire.
      final s = secret(1);
      final cheMoi = await ProximityIdentity.pairToken(s, slot, emitter: moi);
      final chezLui = await ProximityIdentity.pairToken(s, slot, emitter: moi);
      expect(cheMoi, chezLui);
    });

    test('sans identifiant, aucun jeton d\'ami n\'est émis', () async {
      // Le silence se constate ; une valeur que plus personne n'écoute, non.
      final plan = await planner.plan(
        secrets: {'u-a': secret(1)},
        meUserId: null,
        fromSlot: slot,
        slots: 2,
        pingSeed: secret(9),
      );
      expect(plan.tokens.every((t) => t.audience == null), isTrue);
      expect(
        plan.tokens.length,
        2,
        reason: 'l\'identifiant public part quand même',
      );
    });
  });

  group('la table de reconnaissance', () {
    test('tolère un créneau d\'écart de part et d\'autre', () async {
      final table = await planner.table(
        secrets: {'u-a': secret(1)},
        slot: slot,
      );
      expect(table.byToken.length, 3, reason: 'slot-1, slot, slot+1');
      // ⚠️ **Les bornes elles-mêmes, et non un accesseur qui les recopie.**
      // `covers()` valait exactement `slot >= fromSlot && slot <= toSlot` :
      // deux façons d'énoncer la même chose, dont une seule pouvait se tromper.
      expect(table.fromSlot, slot - 1);
      expect(table.toSlot, slot + 1);
    });

    test('reconnaît le jeton que l\'ami émet, et lui seul', () async {
      final table = await planner.table(
        secrets: {'u-a': secret(1)},
        slot: slot,
      );

      final sien = await ProximityIdentity.pairToken(
        secret(1),
        slot,
        emitter: 'u-a',
      );
      expect(table.match(sien), 'u-a');

      final autre = await ProximityIdentity.pairToken(
        secret(2),
        slot,
        emitter: 'u-b',
      );
      expect(
        table.match(autre),
        isNull,
        reason: 'un jeton destiné à quelqu\'un d\'autre ne doit rien apprendre',
      );
    });

    test('reste bien plus petite que le plan d\'émission', () async {
      // Le plan regarde loin devant, la table juge l'instant. Préparer douze
      // heures de reconnaissance coûterait douze heures de HMAC pour rien.
      final secrets = {for (var i = 0; i < 10; i++) 'u-$i': secret(i)};
      final plan = await planner.plan(
        secrets: secrets,
        meUserId: moi,
        fromSlot: slot,
        slots: 48,
      );
      final table = await planner.table(secrets: secrets, slot: slot);
      expect(table.byToken.length, 30);
      expect(plan.tokens.length, 480);
    });
  });

  test(
    'un jeton fait exactement la taille prévue dans l\'annonce BLE',
    () async {
      final token = await ProximityIdentity.pairToken(
        secret(1),
        slot,
        emitter: 'u-a',
      );
      expect(token.length, ProximityIdentity.tokenLength);
      expect(ProximityIdentity.tokenLength, 16);
    },
  );

  test(
    'jeton de paire et identifiant public ne se confondent jamais',
    () async {
      // ⚠️ Les deux sortent du même HMAC. Sans texte de domaine distinct, rien
      // n'interdirait qu'une valeur d'un contexte soit acceptée dans l'autre.
      final graine = secret(5);
      expect(
        await ProximityIdentity.pairToken(graine, slot, emitter: 'u-a'),
        isNot(await ProximityIdentity.publicPingId(graine, slot)),
      );
    },
  );

  group('la table remise au NATIF', () {
    test(
      "les jetons sont rangés à plat, créneau par créneau, dans l'ordre",
      () async {
        // ⚠️ L'invariant sur lequel repose toute la lecture côté Kotlin : rang i
        // du créneau s se trouve à la position (s * N + i) * 16.
        final secrets = {'u-a': secret(1), 'u-b': secret(2)};
        final table = await planner.nativeTable(
          secrets: secrets,
          fromSlot: slot,
          slots: 3,
          tableId: 42,
        );

        expect(table.tableId, 42);
        expect(table.perSlot, 2);
        expect(table.tokens.length, 3 * 2 * 16);

        for (var s = 0; s < 3; s++) {
          for (var i = 0; i < 2; i++) {
            final attendu = await ProximityIdentity.pairToken(
              secrets[table.order[i]]!,
              slot + s,
              emitter: table.order[i],
            );
            final debut = (s * 2 + i) * 16;
            expect(table.tokens.sublist(debut, debut + 16), attendu);
          }
        }
      },
    );

    test(
      "le rang se relit en identifiant d'ami, et hors table en null",
      () async {
        final table = await planner.nativeTable(
          secrets: {'u-a': secret(1), 'u-b': secret(2)},
          fromSlot: slot,
          slots: 1,
          tableId: 1,
        );
        expect(table.friendAt(0), table.order.first);
        expect(
          table.friendAt(9),
          isNull,
          reason: 'un rang hors table doit être jeté, jamais deviné',
        );
        expect(table.friendAt(-1), isNull);
      },
    );

    test('sans ami, la table est vide plutôt que fausse', () async {
      final table = await planner.nativeTable(
        secrets: const {},
        fromSlot: slot,
        slots: 4,
        tableId: 1,
      );
      expect(table.order, isEmpty);
    });
  });
}
