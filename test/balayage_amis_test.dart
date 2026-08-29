import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/supabase_providers.dart';
import 'package:neovibe/features/proximity/net/ble_radio.dart';
import 'package:neovibe/features/proximity/net/proximity_controller.dart';
import 'package:neovibe/features/proximity/net/proximity_supervisor.dart';
import 'package:neovibe/features/proximity/net/proximity_sync.dart';
import 'package:neovibe/features/proximity/ping_store.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/proximity_doubles.dart';

/// **Ce que ces tests protègent : le balayage des constats suit « Croiser mes
/// amis », et rien d'autre.**
///
/// ## 🔴 Le défaut qu'ils rendent impossible — relevé sur l'appareil le 2026-08-28
///
/// Le minuteur de constats démarrait dès qu'un compte était connecté, et ne
/// s'arrêtait jamais. Chacun de ses tours traverse la frontière native
/// (`takeSightings`) : **trente appels par minute, toute la nuit, y compris les
/// deux interrupteurs éteints** — c'est-à-dire quand il n'y a, par
/// construction, rien à constater.
///
/// ## ⚠️ Ce défaut ne lève rien, ne se voit pas, et ne se compte qu'ici
///
/// L'app affichait la bonne chose, la radio disait ce qu'il fallait, aucun test
/// d'écran n'aurait pu tomber dessus : le seul symptôme était de la batterie
/// consommée. **Un test qui compte vaut mieux qu'un commentaire qui promet.**
///
/// ## ⚠️ Et la bonne condition n'est PAS « la radio tourne »
///
/// La radio s'allume si l'un **ou** l'autre interrupteur est posé. Le second
/// test ci-dessous est celui qui compte vraiment : quelqu'un qui ne veut
/// qu'être visible d'inconnus fait tourner la radio — et ne doit produire
/// **aucun** appel de constat, puisqu'aucune table d'amis n'est déposée.
class _SyncMuette extends ProximitySync {
  _SyncMuette(super.ref);

  @override
  Future<void> run() async {}

  @override
  Future<void> pushOutbox() async {}
}

/// ⚠️ **Le vrai magasin écrit sur le disque** (`path_provider`), indisponible
/// en test JVM. On ne remplace que le stockage : rien de ce qui est testé ici
/// ne dépend de ce qu'il en fait.
class _MagasinMuet extends PingStore {
  @override
  Future<void> wipe() async {}

  @override
  Future<void> enqueue(Map<String, dynamic> item) async {}
}

Future<({ProviderContainer container, RadioFactice radio})> _harnais({
  required bool amis,
  required bool inconnus,
}) async {
  SharedPreferences.setMockInitialValues({
    ProximitySupervisor.prefsKey: inconnus,
    ProximitySupervisor.prefsKeyFriends: amis,
  });
  final radio = RadioFactice();
  final container = ProviderContainer(
    overrides: [
      bleRadioProvider.overrideWithValue(radio),
      friendBookProvider.overrideWithValue(CarnetMemoire()),
      proximityIdentityProvider.overrideWithValue(
        await IdentiteMemoire.creer(userId: 'u-moi'),
      ),
      currentUserIdProvider.overrideWithValue('u-moi'),
      pingStoreProvider.overrideWithValue(_MagasinMuet()),
      proximitySyncProvider.overrideWith(_SyncMuette.new),
    ],
  );
  container.listen(proximitySupervisorProvider, (_, _) {});
  container.listen(proximityControllerProvider, (_, _) {});
  return (container: container, radio: radio);
}

/// Deux tours de balayage, plus une marge. La cadence est lue sur la classe
/// testée : un jour où elle changera, ce test suivra au lieu de mentir.
Future<void> _deuxTours() => Future<void>.delayed(
  ProximityController.sweepEvery * 2 + const Duration(milliseconds: 300),
);

void main() {
  test(
    'les deux interrupteurs éteints : AUCUN appel natif de constat',
    () async {
      final h = await _harnais(amis: false, inconnus: false);
      addTearDown(h.container.dispose);
      addTearDown(h.radio.fermer);

      await _deuxTours();

      expect(
        h.radio.sightingsLues,
        0,
        reason:
            'Rien à constater, personne à constater : chaque appel est une '
            'traversée de la frontière native payée pour une réponse vide.',
      );
    },
  );

  test(
    'seuls les INCONNUS demandés : la radio tourne, le balayage des amis non',
    () async {
      final h = await _harnais(amis: false, inconnus: true);
      addTearDown(h.container.dispose);
      addTearDown(h.radio.fermer);

      await _deuxTours();

      expect(
        h.radio.demarrages,
        greaterThan(0),
        reason:
            'La radio DOIT tourner : être visible des inconnus la demande. '
            "C'est ce qui rend le test suivant intéressant.",
      );
      expect(
        h.radio.sightingsLues,
        0,
        reason:
            "Le piège exact : la radio a une raison de tourner, mais aucune "
            "table d'amis n'a été déposée. Attacher le balayage à « la radio "
            'tourne » (radioNeeded) aurait laissé ce cas en place.',
      );
    },
  );

  test('« Croiser mes amis » allumé : le balayage tourne', () async {
    final h = await _harnais(amis: true, inconnus: false);
    addTearDown(h.container.dispose);
    addTearDown(h.radio.fermer);

    await _deuxTours();

    expect(
      h.radio.sightingsLues,
      greaterThan(0),
      reason:
          "Sans ce tour-là, le natif garderait pour lui tout ce qu'il a "
          "constaté pendant que le Dart dormait — c'est-à-dire tout le "
          'croisement app fermée.',
    );
  });

  test(
    'éteindre « Croiser mes amis » arrête le balayage, après un dernier tour',
    () async {
      final h = await _harnais(amis: true, inconnus: false);
      addTearDown(h.container.dispose);
      addTearDown(h.radio.fermer);

      await _deuxTours();
      expect(h.radio.sightingsLues, greaterThan(0));

      await h.container
          .read(proximitySupervisorProvider.notifier)
          .setFriendCrossing(false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final apresExtinction = h.radio.sightingsLues;

      await _deuxTours();

      expect(
        h.radio.sightingsLues,
        apresExtinction,
        reason:
            "Plus un seul appel après l'extinction. Le dernier tour a déjà eu "
            'lieu : un constat pris pendant que l\'utilisateur le voulait doit '
            'partir, sinon on fait échouer en silence le croisement d\'un ami '
            'qui, lui, a tout fait correctement.',
      );
    },
  );
}
