import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/advert_plan.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// **Le point de contact entre le Dart qui ÉCRIT et le Kotlin qui LIT.**
///
/// ## 🔴 Le trou que ces vecteurs bouchent — relevé le 2026-08-29
///
/// Le plan d'émission et la table de reconnaissance sont écrits en Dart et lus
/// en Kotlin. Les deux côtés avaient leurs tests — `advert_plan_test.dart` ici,
/// `AdvertScheduleTest` et `SightingBookTest` là-bas — **mais chacun avec ses
/// propres fixtures**. Rien ne vérifiait qu'ils rangent les octets de la même
/// façon.
///
/// ⚠️ **Une transposition y serait parfaitement silencieuse.** Si Kotlin lisait
/// la table « ami par ami » là où Dart l'écrit « créneau par créneau », tout
/// compilerait, les tests des deux côtés resteraient verts, et le seul symptôme
/// serait : *l'appareil est entendu dix fois par seconde et reconnu zéro fois*.
/// C'est le symptôme exact qu'on a passé la journée du 2026-08-29 à
/// diagnostiquer — il avait cette fois une autre cause, mais rien n'aurait
/// permis de distinguer les deux.
///
/// Même dispositif que pour le format scellé (`tool/gen_seal_vectors.dart` +
/// `SealedChunkReaderTest`), et pour la même raison : **deux implémentations
/// d'un même accord ont besoin d'un point de contact.**
///
/// ## ⚠️ Pourquoi c'est un TEST et pas un `tool/gen_*.dart`
///
/// `ProximityIdentity` importe `flutter_secure_storage` et `path_provider` :
/// `dart run` ne sait pas le compiler. Il faut le moteur Flutter, donc
/// `flutter test`.
///
/// **Et c'est mieux ainsi** : un générateur ne vérifie rien après le jour où on
/// l'a lancé. Ici le côté Dart est **contrôlé à chaque exécution de la suite** —
/// si quelqu'un change l'ordre d'aplatissement ou la formule d'un jeton, ce
/// test tombe *avant* que l'appareil ne devienne muet.
///
/// ## Régénérer — délibérément, jamais « pour faire passer le test »
///
/// ```
/// NEOVIBE_REGEN=1 flutter test test/recognition_vectors_test.dart
/// ```
///
/// ⚠️ **Régénérer pour faire taire un échec annule tout le dispositif** : les
/// deux implémentations resteraient fausses ensemble. Un échec ici veut dire
/// *« le format a changé »* — et la question suivante est *« le Kotlin a-t-il
/// changé avec ? »*.
const _fichier =
    'android/app/src/test/resources/recognition-vectors/manifest.json';

/// Un créneau fixe : des vecteurs qui changent à chaque exécution ne prouvent
/// rien, et leur diff devient illisible.
const _depart = 1986600;

/// ⚠️ **Trois créneaux au moins, et DEUX amis au moins.** Avec un seul de l'un
/// ou de l'autre, une table transposée donnerait exactement les mêmes octets :
/// le vecteur ne prouverait rien.
const _creneaux = 3;

const _moi = 'u-charles';

final _amis = <String, Uint8List>{
  'u-mimi': Uint8List.fromList(List.generate(32, (i) => i)),
  'u-lea': Uint8List.fromList(List.generate(32, (i) => 255 - i)),
};

final _grainePing = Uint8List.fromList(
  List.generate(32, (i) => (i * 7) & 0xFF),
);

Future<Map<String, dynamic>> _construire() async {
  const planificateur = AdvertPlanner();

  final table = await planificateur.nativeTable(
    secrets: _amis,
    fromSlot: _depart,
    slots: _creneaux,
    tableId: 42,
  );

  final plan = await planificateur.plan(
    secrets: _amis,
    fromSlot: _depart,
    slots: _creneaux,
    meUserId: _moi,
    pingSeed: _grainePing,
  );

  // ⚠️ **Le même aplatissement que `ProximitySupervisor._deposePlan`.** S'il
  // divergeait, ces vecteurs décriraient un plan que personne ne dépose — un
  // instrument qui mesure autre chose que ce qui tourne.
  final planPlat = Uint8List(
    plan.tokens.length * ProximityIdentity.tokenLength,
  );
  final types = Uint8List(plan.tokens.length);
  for (var i = 0; i < plan.tokens.length; i++) {
    planPlat.setRange(
      i * ProximityIdentity.tokenLength,
      (i + 1) * ProximityIdentity.tokenLength,
      plan.tokens[i].bytes,
    );
    types[i] = plan.tokens[i].audience == null ? 1 : 2;
  }

  String hex(Uint8List b) => ProximityIdentity.hex(b);
  Future<String> jetonDe(String ami, int creneau) async => hex(
    await ProximityIdentity.pairToken(_amis[ami]!, creneau, emitter: ami),
  );

  final sondes = <Map<String, dynamic>>[
    {
      'jeton': await jetonDe('u-mimi', _depart),
      'auCreneau': _depart,
      'rangAttendu': 0,
      'pourquoi': 'le premier ami, a son propre creneau',
    },
    {
      // 🔴 **La sonde qui attrape une transposition.** Le rang 1 au troisieme
      // creneau n'est au bon endroit que si les deux cotes rangent creneau par
      // creneau. Transposee, la table y trouverait quelqu'un d'autre.
      'jeton': await jetonDe('u-lea', _depart + 2),
      'auCreneau': _depart + 2,
      'rangAttendu': 1,
      'pourquoi': 'le SECOND ami au TROISIEME creneau — la transposition',
    },
    {
      'jeton': await jetonDe('u-mimi', _depart + 1),
      'auCreneau': _depart,
      'rangAttendu': 0,
      'pourquoi': 'un creneau d avance : la tolerance d horloge l accepte',
    },
    {
      'jeton': await jetonDe('u-mimi', _depart),
      'auCreneau': _depart + 2,
      'rangAttendu': null,
      'pourquoi': 'deux creneaux de retard : rejoue, donc refuse',
    },
    {
      'jeton': hex(
        await ProximityIdentity.pairToken(
          Uint8List.fromList(List.filled(32, 9)),
          _depart,
          emitter: 'u-inconnu',
        ),
      ),
      'auCreneau': _depart,
      'rangAttendu': null,
      'pourquoi': 'le jeton d une autre paire',
    },
    {
      // ⚠️ Deux formats, deux chemins (consigne de Jay, 2026-08-25) : le jeton
      // public n'entre jamais dans la table de reconnaissance.
      'jeton': hex(await ProximityIdentity.publicPingId(_grainePing, _depart)),
      'auCreneau': _depart,
      'rangAttendu': null,
      'pourquoi': 'l identifiant PUBLIC n est reconnu par personne',
    },
    {
      // ⚠️ **Le SENS du jeton.** Ce que moi j'emets vers mimi n'est pas ce que
      // j'attends d'elle. Une inversion ne leve aucune erreur : elle rend
      // simplement les deux appareils sourds l'un a l'autre.
      'jeton': hex(
        await ProximityIdentity.pairToken(
          _amis['u-mimi']!,
          _depart,
          emitter: _moi,
        ),
      ),
      'auCreneau': _depart,
      'rangAttendu': null,
      'pourquoi': 'mon PROPRE jeton vers mimi : je ne dois pas le reconnaitre',
    },
  ];

  final sondesPlan = <Map<String, dynamic>>[
    for (var c = _depart; c < _depart + _creneaux; c++)
      {
        'auCreneau': c,
        'jetons': [for (final t in plan.forSlot(c)) hex(t.bytes)],
        'types': [for (final t in plan.forSlot(c)) t.audience == null ? 1 : 2],
        'sansPublic': [
          for (final t in plan.forSlot(c))
            if (t.audience != null) hex(t.bytes),
        ],
      },
  ];

  return {
    'slotMillis': ProximityIdentity.slotDuration.inMilliseconds,
    'tokenLength': ProximityIdentity.tokenLength,
    'table': {
      'tableId': table.tableId,
      'fromSlot': table.fromSlot,
      'slotCount': table.slotCount,
      'perSlot': table.perSlot,
      'ordre': table.order,
      'tokens': base64.encode(table.tokens),
    },
    'plan': {
      'fromSlot': plan.fromSlot,
      'slotCount': _creneaux,
      'perSlot': plan.forSlot(_depart).length,
      'tokens': base64.encode(planPlat),
      'types': base64.encode(types),
    },
    'sondes': sondes,
    'sondesPlan': sondesPlan,
  };
}

void main() {
  test('les vecteurs croisés décrivent le format que le Dart produit', () async {
    final attendu =
        '${const JsonEncoder.withIndent('  ').convert(await _construire())}\n';
    final fichier = File(_fichier);

    if (Platform.environment['NEOVIBE_REGEN'] == '1') {
      fichier.parent.createSync(recursive: true);
      fichier.writeAsStringSync(attendu);
      // ignore: avoid_print
      print(
        'VECTEURS RÉGÉNÉRÉS dans $_fichier.\n'
        '⚠️ Vérifie que le Kotlin a changé avec le format, sinon les deux '
        'implémentations sont fausses ensemble.',
      );
      return;
    }

    expect(
      fichier.existsSync(),
      isTrue,
      reason:
          'Vecteurs absents. Générer avec : '
          'NEOVIBE_REGEN=1 flutter test test/recognition_vectors_test.dart',
    );
    expect(
      fichier.readAsStringSync().replaceAll('\r\n', '\n'),
      attendu,
      reason:
          'Le format d\'émission ou de reconnaissance a changé côté Dart. '
          'Le Kotlin a-t-il changé avec ? Régénérer sans vérifier laisserait '
          'les deux implémentations fausses ensemble.',
    );
  });
}
