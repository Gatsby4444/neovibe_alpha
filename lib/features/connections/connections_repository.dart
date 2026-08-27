import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/clock.dart';
import '../../core/derived_list.dart';
import '../../core/models/connection.dart';
import '../../core/models/connection_request.dart';
import '../../core/models/wave.dart';
import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../proximity/net/proximity_sync.dart';

/// Profil par id, mis en cache (résolu selon les droits RLS).
final profileByIdProvider = FutureProvider.family<Profile?, String>((
  ref,
  id,
) async {
  final data = await ref
      .watch(supabaseProvider)
      .from('profiles')
      .select()
      .eq('id', id)
      .maybeSingle();
  return data == null ? null : Profile.fromJson(data);
});

/// Mes connexions (partielles et complètes), temps réel.
final connectionsStreamProvider = StreamProvider<List<Connection>>((ref) {
  // ⚠️ Fait repartir l'abonnement quand le jeton temps réel est renouvelé.
  // Sans ça, le socket garde le jeton avec lequel il s'est ouvert et tombe
  // au bout d'une heure — sans le moindre symptôme (2026-08-17).
  ref.watch(realtimeEpochProvider);
  final client = ref.watch(supabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const Stream.empty();
  return client
      .from('connections')
      .stream(primaryKey: ['id'])
      .map(
        (rows) =>
            rows.map(Connection.fromJson).toList()
              ..sort((a, b) => a.status.index.compareTo(b.status.index)),
      );
});

// ---------------------------------------------------------------------------
// L'USAGE — trois vues, trois raisons de changer
// ---------------------------------------------------------------------------
//
// ⚠️ **Réécrit le 2026-08-25** (checkup `RAPPELS.md` #52). Ces trois vues
// étaient deux `Provider` qui refabriquaient une `List` à chaque passage. En
// Dart l'égalité d'une liste est l'IDENTITÉ : une connexion *partielle* qui
// changeait réveillait donc la liste des connexions *complètes*, observée par
// **7 écrans de 6 modules**, alors que son contenu était identique champ pour
// champ. Mesuré, jamais visible à l'écran.
//
// Chaque vue est maintenant un `Notifier` avec [DerivedList] : elle recalcule
// librement, et ne notifie que si le RÉSULTAT change.

/// Mes amis. **Ne dépend pas du temps** : une connexion complète n'expire pas.
class _FullConnections extends Notifier<List<Connection>>
    with DerivedList<Connection> {
  @override
  List<Connection> build() {
    final all = ref.watch(connectionsStreamProvider).value ?? const [];
    return all
        .where((c) => c.status == ConnectionStatus.full)
        .toList(growable: false);
  }
}

final fullConnectionsProvider =
    NotifierProvider<_FullConnections, List<Connection>>(_FullConnections.new);

/// Les liens partiels **tels qu'ils sont en base**, sans considération d'heure.
///
/// ⚠️ **Séparé de la vue « encore valide » juste en dessous, et c'est le cœur
/// de la correction.** Mélanger les deux, c'était faire dépendre une liste de
/// deux sources — la base ET l'horloge — dont une seule était observée. La
/// seconde ne l'était pas : un lien partiel expiré restait affiché tant que
/// personne n'écrivait dans la table.
class _PartialConnections extends Notifier<List<Connection>>
    with DerivedList<Connection> {
  @override
  List<Connection> build() {
    final all = ref.watch(connectionsStreamProvider).value ?? const [];
    return all
        .where((c) => c.status == ConnectionStatus.partial)
        .toList(growable: false);
  }
}

final allPartialConnectionsProvider =
    NotifierProvider<_PartialConnections, List<Connection>>(
      _PartialConnections.new,
    );

/// Les liens partiels **encore valides à cet instant**.
///
/// Observe deux sources, chacune à son rythme : la base (rare) et l'horloge de
/// péremption (`core/clock.dart`, 5 s). L'horloge bat sans rien réveiller —
/// [DerivedList] arrête la propagation tant que la liste ne change pas — et
/// c'est exactement à la seconde où un lien expire que l'écran l'apprend.
class _LivePartialConnections extends Notifier<List<Connection>>
    with DerivedList<Connection> {
  @override
  List<Connection> build() {
    final now = ref.watch(expiryClockProvider);
    return ref
        .watch(allPartialConnectionsProvider)
        .where((c) => c.partialExpiresAt?.isAfter(now) ?? false)
        .toList(growable: false);
  }
}

final partialConnectionsProvider =
    NotifierProvider<_LivePartialConnections, List<Connection>>(
      _LivePartialConnections.new,
    );

/// **Qui sont mes amis, vus comme des IDENTIFIANTS.**
///
/// ⚠️ **Ajouté le 2026-08-25 pour couper une chaîne d'amplification entre
/// modules.** Les deux bandeaux de stories observaient
/// [fullConnectionsProvider] *en entier* pour n'en tirer que cet ensemble : le
/// moindre changement dans une connexion — un avatar, une confirmation — faisait
/// recalculer les stories du Cercle **et** celles du Ping.
///
/// Ici, seul ce qui les intéresse vraiment leur parvient : la composition de
/// l'ensemble. Un ami qui change de pseudo ne réveille plus aucune story.
class _FriendIds extends Notifier<Set<String>> with DerivedSet<String> {
  @override
  Set<String> build() {
    final me = ref.watch(currentUserIdProvider);
    if (me == null) return const {};
    return ref
        .watch(fullConnectionsProvider)
        .map((c) => c.peerIdFor(me))
        .toSet();
  }
}

final friendIdsProvider = NotifierProvider<_FriendIds, Set<String>>(
  _FriendIds.new,
);

// ---------------------------------------------------------------------------
// L'ACQUISITION — l'historique de la section « cœur »
// ---------------------------------------------------------------------------
//
// ⚠️ **Déplacés depuis `heart_screen.dart` le 2026-08-25** (checkup #52). Ces
// deux requêtes vivaient dans le fichier de l'écran : ajouter une colonne à
// l'affichage obligeait à toucher au code qui parle au réseau, et aucun autre
// écran ne pouvait s'en servir.

/// Historique des Waves : uniquement les croisements dont l'heure de
/// notification est passée (le différé reste différé), horodatage flou,
/// jamais de position (spec 4.11).
///
/// ⚠️ **Le filtre d'heure est ici volontairement côté SERVEUR** : il borne le
/// volume rapatrié, ce qui est bien le travail de l'acquisition. Contrepartie
/// assumée et connue : un croisement dont l'heure de notification échoit
/// pendant que l'écran est ouvert n'apparaît qu'au prochain rafraîchissement.
/// Le rendre vivant coûterait une requête réseau périodique — arbitrage à poser
/// à Jay, pas à trancher seul (constaté le 2026-08-25).
final wavesProvider = FutureProvider<List<Wave>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('waves')
      .select()
      .eq('user_id', me)
      .lte('notify_after', DateTime.now().toUtc().toIso8601String())
      .order('detected_at', ascending: false)
      .limit(50);
  return rows.map(Wave.fromJson).toList();
});

/// Historique de MES demandes de connexion (reçues + envoyées, tous statuts).
final requestHistoryProvider = FutureProvider<List<ConnectionRequest>>((
  ref,
) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('connection_requests')
      .select()
      .order('created_at', ascending: false)
      .limit(50);
  return rows.map(ConnectionRequest.fromJson).toList();
});

class ConnectionsRepository {
  ConnectionsRepository(this.ref);
  final Ref ref;

  /// ⚠️ **Les trois écritures qui changent le graphe d'amis relancent la
  /// synchro.** Le carnet local porte les clés qui permettent de reconnaître un
  /// ami par la radio : sans ce rappel, un ami ajouté reste invisible en BLE, et
  /// un ami retiré reste reconnu — jusqu'au prochain démarrage de l'app.
  /// Constaté pendant la session de test du 2026-08-27.
  Future<void> confirmPartial(String connectionId) async {
    await _confirmPartial(connectionId);
    unawaited(ref.read(proximitySyncProvider).run());
  }

  Future<void> _confirmPartial(String connectionId) => ref
      .read(supabaseProvider)
      .rpc('confirm_partial_connection', params: {'conn_id': connectionId});

  Future<void> remove(String connectionId) async {
    await _remove(connectionId);
    unawaited(ref.read(proximitySyncProvider).run());
  }

  Future<void> _remove(String connectionId) => ref
      .read(supabaseProvider)
      .from('connections')
      .delete()
      .eq('id', connectionId);
}

final connectionsRepositoryProvider = Provider(
  (ref) => ConnectionsRepository(ref),
);
