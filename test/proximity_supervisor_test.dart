import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/supabase_providers.dart';
import 'package:neovibe/features/proximity/net/ble_radio.dart';
import 'package:neovibe/features/proximity/net/proximity_supervisor.dart';
import 'package:neovibe/features/proximity/net/radio_status.dart';
import 'package:neovibe/features/proximity/ping_store.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/proximity_doubles.dart';

/// **Ce que ces tests protègent : le plan d'émission suit ses sources.**
///
/// ## 🔴 Le défaut qu'ils rendent impossible — audit du 2026-08-28
///
/// `refreshPlan()` n'avait que **deux** déclencheurs : `_engage()` et un
/// minuteur d'une heure. **Rien n'écoutait le carnet d'amis.** Or tous les
/// jetons émis viennent du plan : accepter un ami ne le faisait donc entrer ni
/// dans ce qu'on crie, ni dans la table déposée au natif, **pendant jusqu'à une
/// heure et des deux côtés**. Aucune distance, aucun constat, aucun croisement
/// — et pas une seule erreur levée.
///
/// ⚠️ **Ce défaut ne se voit qu'en COMPTANT les dépôts.** L'écran affichait la
/// bonne chose, la radio tournait, l'état disait « actif ». Le seul symptôme
/// était l'absence de croisement, indiscernable de « on ne s'est pas croisés ».
class _RadioFactice implements BleRadio {
  final _flux = StreamController<RadioEvent>.broadcast();

  /// Combien de fois un plan d'émission a été déposé.
  int plans = 0;

  /// Combien de fois une table de reconnaissance a été déposée.
  int tables = 0;

  int demarrages = 0;

  /// Fait échouer le dépôt du plan, pour éprouver le rétablissement.
  bool refusePlan = false;

  @override
  Stream<RadioEvent> events() => _flux.stream;

  @override
  Future<RadioStatus> probe() async => const RadioIdle();

  @override
  Future<void> start(Uint8List advertId) async => demarrages++;

  @override
  Future<void> stop() async {}

  @override
  Future<void> openLocationSettings() async {}

  @override
  Future<int> setAdvertPlan({
    required Uint8List tokens,
    required Uint8List types,
    required int fromSlot,
    required int slotMillis,
    required int slotCount,
    required int perSlot,
    required int tokenLength,
  }) async {
    if (refusePlan) throw StateError('service absent');
    plans++;
    return 0;
  }

  @override
  Future<void> setRecognitionTable({
    required int tableId,
    required Uint8List tokens,
    required int fromSlot,
    required int slotMillis,
    required int slotCount,
    required int perSlot,
    required int tokenLength,
  }) async => tables++;

  @override
  Future<List<Map<String, dynamic>>> takeSightings() async => const [];

  @override
  Future<Map<String, dynamic>> stats() async => const {};

  Future<void> fermer() => _flux.close();
}

/// Laisse les `Future.microtask` et les `await` du superviseur se dérouler.
Future<void> _propage() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

Future<
  ({ProviderContainer container, _RadioFactice radio, CarnetMemoire carnet})
>
_harnais({bool visible = true, String? me = 'u-moi'}) async {
  SharedPreferences.setMockInitialValues({
    ProximitySupervisor.prefsKey: visible,
  });
  final radio = _RadioFactice();
  final carnet = CarnetMemoire();
  final identite = await IdentiteMemoire.creer(userId: me ?? 'u-moi');
  final container = ProviderContainer(
    overrides: [
      bleRadioProvider.overrideWithValue(radio),
      friendBookProvider.overrideWithValue(carnet),
      proximityIdentityProvider.overrideWithValue(identite),
      currentUserIdProvider.overrideWithValue(me),
    ],
  );
  return (container: container, radio: radio, carnet: carnet);
}

FriendKeys _ami(String id, Uint8List cle) =>
    FriendKeys(userId: id, username: id, x25519PublicKey: cle);

void main() {
  test(
    'un ami ajouté au carnet fait REDÉPOSER le plan et la table, tout de suite',
    () async {
      final h = await _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.radio.fermer);

      h.container.listen(proximitySupervisorProvider, (_, _) {});
      await _propage();

      // Au démarrage : un plan (l'identifiant public), et aucune table — on n'a
      // pas d'ami à reconnaître.
      expect(h.radio.plans, greaterThan(0));
      expect(h.radio.tables, 0);
      final avant = h.radio.plans;

      final bob = await IdentiteMemoire.creer(graine: 7, userId: 'u-b');
      await h.carnet.replace([_ami('u-b', await bob.x25519PublicKey())]);
      await _propage();

      expect(
        h.radio.plans,
        greaterThan(avant),
        reason:
            "Le jeton de paire de Bob n'existe que dans le plan : sans nouveau "
            "dépôt, Bob ne peut PAS reconnaître cet appareil — et l'inverse "
            "non plus. C'est le défaut du 2026-08-28, invisible à l'écran.",
      );
      expect(
        h.radio.tables,
        greaterThan(0),
        reason:
            'Sans table déposée, le natif est vu sans voir : plus aucun '
            'croisement app fermée.',
      );
    },
  );

  test('un ami retiré du carnet fait redéposer le plan, sans attendre une '
      'heure', () async {
    final h = await _harnais();
    addTearDown(h.container.dispose);
    addTearDown(h.radio.fermer);

    h.container.listen(proximitySupervisorProvider, (_, _) {});
    final bob = await IdentiteMemoire.creer(graine: 7, userId: 'u-b');
    await h.carnet.replace([_ami('u-b', await bob.x25519PublicKey())]);
    await _propage();
    final avant = h.radio.plans;

    // ⚠️ La révocation est censée être **immédiate et locale**. Sans ce dépôt,
    // on continuerait de crier le jeton d'un ex-ami — donc à être reconnu par
    // lui — jusqu'au prochain tour horaire.
    await h.carnet.replace(const []);
    await _propage();

    expect(h.radio.plans, greaterThan(avant));
  });

  test(
    'un plan refusé ne boucle pas : une seule reprise, puis on le DIT',
    () async {
      // ⚠️ Le `catch` de `refreshPlan` appelait `_engage()`, qui rappelle
      // `refreshPlan` : un échec reproductible bouclait **sans borne ni délai**,
      // en recalculant à chaque tour 48 créneaux de HMAC par ami. Ce test compte
      // les tentatives ; sans la borne, il ne se termine pas.
      final h = await _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.radio.fermer);

      h.radio.refusePlan = true;
      h.container.listen(proximitySupervisorProvider, (_, _) {});
      await _propage();

      expect(
        h.radio.demarrages,
        lessThanOrEqualTo(2),
        reason:
            'Un démarrage initial, plus AU PLUS une tentative de rétablissement.',
      );
      expect(
        h.container.read(proximitySupervisorProvider).status,
        isA<RadioFailed>(),
        reason:
            "Un échec définitif se DIT. Une boucle silencieuse qui vide la "
            "batterie est le pire des deux mondes.",
      );
    },
  );

  test(
    "le plan ne se dépose pas tant que l'utilisateur n'est pas visible",
    () async {
      final h = await _harnais(visible: false);
      addTearDown(h.container.dispose);
      addTearDown(h.radio.fermer);

      h.container.listen(proximitySupervisorProvider, (_, _) {});
      await _propage();

      final bob = await IdentiteMemoire.creer(graine: 7, userId: 'u-b');
      await h.carnet.replace([_ami('u-b', await bob.x25519PublicKey())]);
      await _propage();

      expect(
        h.radio.plans,
        0,
        reason:
            "Crier alors que l'utilisateur a coupé sa visibilité, c'est faire "
            "l'inverse de ce qu'il vient de demander.",
      );
    },
  );
}
