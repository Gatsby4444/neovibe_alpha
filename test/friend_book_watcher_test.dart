import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/connection.dart';
import 'package:neovibe/core/models/profile.dart';
import 'package:neovibe/core/supabase_providers.dart';
import 'package:neovibe/features/connections/connections_repository.dart';
import 'package:neovibe/features/proximity/net/friend_book_watcher.dart';
import 'package:neovibe/features/proximity/net/proximity_sync.dart';

/// **Ce que ces tests mesurent : que le carnet suive le GRAPHE, pas l'écriture.**
///
/// ## Le défaut du 2026-08-28, en une phrase
///
/// Le carnet local porte les clés sans lesquelles un ami n'est ni reconnu ni
/// émis en Bluetooth. Les sept appels qui le remplissaient étaient tous
/// accrochés à une **écriture locale** — or une amitié change sur **deux**
/// appareils et ne s'écrit que sur **un**.
///
/// Relevé en base : mimi envoie la demande à 12:21:43, Charles accepte à
/// 12:21:47, et à 12:36 le compteur `synchros du carnet réussies` de mimi vaut
/// toujours **0**. Zéro constat de son côté, **aucune ligne dans `encounters`**.
///
/// ⚠️ **Aucun test d'écran n'aurait pu tomber** : l'app affichait la bonne liste
/// d'amis. Ce qui manquait était invisible — des octets qu'on ne criait pas.
/// D'où des tests qui **comptent les synchronisations**, et rien d'autre.

/// Une synchro qui ne parle à personne et qui se laisse compter.
class _SyncEspion extends ProximitySync {
  _SyncEspion(super.ref);

  int carnets = 0;
  int files = 0;

  @override
  Future<void> pullFriendBook() async => carnets++;

  @override
  Future<void> pushOutbox() async => files++;

  @override
  Future<void> publishMyKey() async {}
}

Connection _conn({required String id, Profile? peer}) => Connection(
  id: id,
  userLow: 'moi',
  userHigh: 'pair-$id',
  status: ConnectionStatus.full,
  peer: peer,
);

/// ⚠️ **L'abonnement s'ouvre AVANT la première émission.** Un flux `broadcast`
/// ne rejoue rien : sans ça, le premier `add` part dans le vide et le test
/// compte quelque chose d'autre que ce qu'il annonce.
({
  ProviderContainer container,
  StreamController<List<Connection>> source,
  _SyncEspion sync,
})
_harnais() {
  final source = StreamController<List<Connection>>.broadcast();
  final container = ProviderContainer(
    overrides: [
      currentUserIdProvider.overrideWithValue('moi'),
      connectionsStreamProvider.overrideWith((ref) => source.stream),
      proximitySyncProvider.overrideWith(_SyncEspion.new),
    ],
  );
  container.listen(connectionsStreamProvider, (_, _) {});
  // Ce que fait `app.dart` : tenir la règle vivante pour toute la session.
  container.listen(friendBookWatcherProvider, (_, _) {});
  addTearDown(container.dispose);
  return (
    container: container,
    source: source,
    sync: container.read(proximitySyncProvider) as _SyncEspion,
  );
}

/// ⚠️ **20 ms, pas `Duration.zero`.** La chaîne flux → vue dérivée → règle
/// traverse plusieurs microtâches : avec zéro, on lit un état à moitié
/// propagé et le compteur semble juste pour la mauvaise raison. Piège déjà
/// documenté dans `dissociation_connections_test.dart`, retombé dedans ici.
Future<void> _propage() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('le premier passage remplit le carnet', () async {
    final h = _harnais();
    h.source.add([_conn(id: 'a')]);
    await _propage();

    expect(h.container.read(friendIdsProvider), {'pair-a'});
    expect(h.sync.carnets, greaterThanOrEqualTo(1));
  });

  /// 🔴 **LE test de ce correctif.**
  ///
  /// Rien n'est écrit ici : le graphe arrive tout seul, comme sur l'appareil de
  /// celui qui a *envoyé* la demande d'ami et attend qu'elle soit acceptée.
  test(
    'un ami qui apparaît SANS écriture locale remplit quand même le carnet',
    () async {
      final h = _harnais();
      h.source.add([_conn(id: 'a')]);
      await _propage();
      final avant = h.sync.carnets;

      // Personne n'a touché à cet appareil. C'est l'autre qui a accepté.
      h.source.add([_conn(id: 'a'), _conn(id: 'b')]);
      await _propage();

      expect(h.container.read(friendIdsProvider), {'pair-a', 'pair-b'});
      expect(
        h.sync.carnets,
        avant + 1,
        reason:
            'sans ça, le nouvel ami n\'a pas de clé : aucun jeton émis, '
            'aucun constat, aucun croisement — et aucune erreur nulle part',
      );
    },
  );

  test('un ami qui disparaît déclenche aussi la mise à jour', () async {
    final h = _harnais();
    h.source.add([_conn(id: 'a'), _conn(id: 'b')]);
    await _propage();
    final avant = h.sync.carnets;

    h.source.add([_conn(id: 'a')]);
    await _propage();

    expect(h.sync.carnets, avant + 1);
  });

  /// ⚠️ Le contre-test : sans lui, « ça se synchronise » serait vrai en
  /// resynchronisant à chaque battement — c'est-à-dire le défaut de coût qu'on
  /// vient de supprimer ailleurs.
  test('un ami qui change de pseudo ne resynchronise RIEN', () async {
    final h = _harnais();
    const avantNom = Profile(id: 'pair-a', displayName: 'Mimi');
    const apresNom = Profile(id: 'pair-a', displayName: 'mimi ✨');

    h.source.add([_conn(id: 'a', peer: avantNom)]);
    await _propage();
    final avant = h.sync.carnets;

    h.source.add([_conn(id: 'a', peer: apresNom)]);
    await _propage();

    expect(
      h.sync.carnets,
      avant,
      reason:
          'l\'ENSEMBLE des amis n\'a pas changé : il n\'y a rien à réapprendre',
    );
  });

  test('la même composition émise deux fois ne compte qu\'une fois', () async {
    final h = _harnais();
    h.source.add([_conn(id: 'a')]);
    await _propage();
    final avant = h.sync.carnets;

    h.source.add([_conn(id: 'a')]);
    await _propage();

    expect(h.sync.carnets, avant);
  });
}
