import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Mes connexions, temps réel.
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
      // ⚠️ **Trié par identifiant, et ce tri n'est pas décoratif.** Il triait
      // par statut, ce qui n'a plus de sens depuis que `partial` a disparu
      // (2026-08-28) — mais le RETIRER aurait été pire que le remplacer : sans
      // ordre imposé, deux émissions du même contenu peuvent arriver dans un
      // ordre différent, et [DerivedList] compare **élément par élément**. La
      // vue se croirait changée et réveillerait ses lecteurs pour rien —
      // exactement le défaut que ce fichier a été écrit pour supprimer.
      .map(
        (rows) =>
            rows.map(Connection.fromJson).toList()
              ..sort((a, b) => a.id.compareTo(b.id)),
      );
});

// ---------------------------------------------------------------------------
// L'USAGE — deux vues, deux raisons de changer
// ---------------------------------------------------------------------------
//
// ⚠️ **Réécrit le 2026-08-25** (checkup `RAPPELS.md` #52). Ces vues étaient des
// `Provider` qui refabriquaient une `List` à chaque passage. En Dart l'égalité
// d'une liste est l'IDENTITÉ : une connexion qui changeait réveillait donc la
// liste entière, observée par **7 écrans de 6 modules**, alors que son contenu
// était identique champ pour champ. Mesuré, jamais visible à l'écran.
//
// Chaque vue est un `Notifier` avec [DerivedList] : elle recalcule librement, et
// ne notifie que si le RÉSULTAT change.
//
// ⚠️ **Il y en avait TROIS jusqu'au 2026-08-28** : les deux vues du lien partiel
// sont parties avec lui. Elles étaient les seules de ce fichier à dépendre de
// l'horloge — une connexion n'expire pas.

/// Mes amis.
///
/// ⚠️ **Ne dépend pas du temps**, et c'est la seule vue de ce fichier dans ce
/// cas depuis que le lien partiel a disparu : une connexion ne périme pas.
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

  /// ⚠️ **Toute écriture qui change le graphe d'amis relance la synchro.** Le
  /// carnet local porte les clés qui permettent de reconnaître un ami par la
  /// radio : sans ce rappel, un ami ajouté reste invisible en BLE, et un ami
  /// retiré reste reconnu — jusqu'au prochain démarrage de l'app. Constaté
  /// pendant la session de test du 2026-08-27.
  ///
  /// ⚠️ **`confirmPartial` a été retirée le 2026-08-28** avec le lien partiel :
  /// l'acceptation d'une demande est désormais le seul chemin vers l'amitié, et
  /// elle relance la synchro depuis `proximity_repository.dart`.
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
