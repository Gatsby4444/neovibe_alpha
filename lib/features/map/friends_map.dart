import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';

/// **La position des amis sur la carte** (Jay, 2026-09-26) — la cuisine :
/// ce qui parle au serveur. Les règles vivent au serveur
/// (`20260926110000_la_position_des_amis.sql`) : partage choisi, amis
/// seulement, masquage, cadence (10 s en direct, 30 min sinon), âge
/// maximal. Ce fichier ne fait que les demander.

/// Un ami sur ma carte : où, depuis quand, qui.
class FriendOnMap {
  const FriendOnMap({
    required this.userId,
    required this.lat,
    required this.lon,
    required this.at,
    required this.displayName,
    this.avatarUrl,
    this.revealed = false,
  });

  factory FriendOnMap.fromJson(Map<String, dynamic> j) => FriendOnMap(
    userId: j['user_id'] as String,
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
    at: DateTime.parse(j['at'] as String).toLocal(),
    displayName: (j['display_name'] as String?) ?? '',
    avatarUrl: j['avatar_url'] as String?,
    revealed: j['revealed'] == true,
  );

  final String userId;
  final double lat;
  final double lon;

  /// Quand cette position a été relevée.
  final DateTime at;
  final String displayName;
  final String? avatarUrl;

  /// Position donnée EN RÉPONSE à ma demande (et non partagée d'ordinaire).
  final bool revealed;

  @override
  bool operator ==(Object other) =>
      other is FriendOnMap &&
      other.userId == userId &&
      other.lat == lat &&
      other.lon == lon &&
      other.at == at &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl &&
      other.revealed == revealed;

  @override
  int get hashCode =>
      Object.hash(userId, lat, lon, at, displayName, avatarUrl, revealed);
}

/// **De quand date une position**, dit en clair (« il y a 45 min »).
String ilYa(DateTime at, DateTime maintenant) {
  final d = maintenant.difference(at);
  if (d.inMinutes < 1) return "à l'instant";
  if (d.inMinutes < 60) return 'il y a ${d.inMinutes} min';
  if (d.inHours < 24) return 'il y a ${d.inHours} h';
  return 'il y a ${d.inDays} j';
}

class FriendsMapRepository {
  FriendsMapRepository(this._client);
  final SupabaseClient _client;

  /// Est-ce que je partage ma position avec mes amis ? (Non par défaut.)
  Future<bool> sharing() async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return false;
    final r = await _client
        .from('location_sharing')
        .select('sharing')
        .eq('user_id', me)
        .maybeSingle();
    return (r?['sharing'] as bool?) ?? false;
  }

  /// Partager, ou arrêter — arrêter EFFACE ma position côté serveur.
  Future<void> setSharing(bool on) =>
      _client.rpc('set_location_sharing', params: {'p_on': on});

  /// Les amis à qui je cache ma position.
  Future<Set<String>> hiddenFrom() async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const {};
    final rows =
        await _client
                .from('location_hidden_from')
                .select('friend_id')
                .eq('owner_id', me)
            as List;
    return {for (final r in rows) (r as Map)['friend_id'] as String};
  }

  Future<void> setHidden(String friendId, bool hidden) => _client.rpc(
    'set_location_hidden',
    params: {'p_friend': friendId, 'p_hidden': hidden},
  );

  /// Déposer ma position « en direct » (carte ouverte). Le serveur l'ignore
  /// si je ne partage pas, ou si la précédente a moins de 10 s : rend
  /// `true` seulement si elle a été écrite.
  Future<bool> shareMyLocation(double lat, double lon, double acc) async {
    final r = await _client.rpc(
      'share_my_location',
      params: {'p_lat': lat, 'p_lon': lon, 'p_acc': acc},
    );
    return r == true;
  }

  /// **Demander sa position à un ami** : une demande dans notre chat, qu'il
  /// doit accepter (`request_location` — amis seulement, pas deux fois en
  /// deux minutes).
  Future<String> requestLocation(String friendId) async {
    final id = await _client.rpc(
      'request_location',
      params: {'p_friend': friendId},
    );
    return id as String;
  }

  /// Répondre à une demande : accepter révèle ma position au seul
  /// demandeur, pour une heure (`answer_location_request`).
  Future<void> answerLocationRequest(
    String requestId, {
    required bool accept,
    double? lat,
    double? lon,
    double acc = 0,
  }) => _client.rpc(
    'answer_location_request',
    params: {
      'p_request': requestId,
      'p_accept': accept,
      'p_lat': lat,
      'p_lon': lon,
      'p_acc': acc,
    },
  );

  /// Où en est une demande (pour la bulle du chat) ; nulle si je n'y suis
  /// pour rien.
  Future<LocationRequestState?> requestState(String requestId) async {
    final rows =
        await _client.rpc(
              'location_request_state',
              params: {'p_request': requestId},
            )
            as List;
    if (rows.isEmpty) return null;
    final r = (rows.first as Map).cast<String, dynamic>();
    return LocationRequestState(
      etat: switch (r['state']) {
        'en_attente' => LocationRequestEtat.enAttente,
        'acceptee' => LocationRequestEtat.acceptee,
        'refusee' => LocationRequestEtat.refusee,
        _ => LocationRequestEtat.expiree,
      },
      requesterId: r['requester_id'] as String,
      targetId: r['target_id'] as String,
    );
  }

  /// Mes amis visibles sur ma carte.
  Future<List<FriendOnMap>> friendsOnMap() async {
    final rows = await _client.rpc('friends_on_map') as List;
    return [
      for (final r in rows)
        FriendOnMap.fromJson((r as Map).cast<String, dynamic>()),
    ];
  }
}

final friendsMapRepositoryProvider = Provider<FriendsMapRepository>(
  (ref) => FriendsMapRepository(ref.watch(supabaseProvider)),
);

/// **Est-ce que je partage ma position ?** L'état est au SERVEUR ; ceci n'en
/// est que le reflet, relu après chaque changement.
class LocationSharing extends AsyncNotifier<bool> {
  @override
  Future<bool> build() {
    ref.watch(currentUserIdProvider);
    return ref.read(friendsMapRepositoryProvider).sharing();
  }

  Future<void> set(bool on) async {
    await ref.read(friendsMapRepositoryProvider).setSharing(on);
    state = AsyncData(on);
  }
}

final locationSharingProvider = AsyncNotifierProvider<LocationSharing, bool>(
  LocationSharing.new,
);

/// Les amis à qui je cache ma position (reflet du serveur).
class LocationHiddenFrom extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() {
    ref.watch(currentUserIdProvider);
    return ref.read(friendsMapRepositoryProvider).hiddenFrom();
  }

  Future<void> set(String friendId, bool hidden) async {
    await ref.read(friendsMapRepositoryProvider).setHidden(friendId, hidden);
    final avant = state.value ?? const <String>{};
    state = AsyncData({
      ...avant.where((id) => id != friendId),
      if (hidden) friendId,
    });
  }
}

final locationHiddenFromProvider =
    AsyncNotifierProvider<LocationHiddenFrom, Set<String>>(
      LocationHiddenFrom.new,
    );

/// **Mes amis sur la carte, relus toutes les 10 secondes** tant que la carte
/// est ouverte (`autoDispose` : fermée, plus aucune requête). Jamais plus
/// souvent : le serveur n'écrit pas plus vite (Jay : *« ne pas surcharger
/// les serveurs »*).
final friendsOnMapProvider = StreamProvider.autoDispose<List<FriendOnMap>>((
  ref,
) {
  final depot = ref.watch(friendsMapRepositoryProvider);
  return Stream<List<FriendOnMap>>.multi((controller) {
    var fini = false;
    Future<void> lire() async {
      try {
        final amis = await depot.friendsOnMap();
        if (!fini) controller.add(amis);
      } catch (e, st) {
        if (!fini) controller.addError(e, st);
      }
    }

    unawaited(lire());
    final t = Timer.periodic(friendsRefreshEvery, (_) => unawaited(lire()));
    controller.onCancel = () {
      fini = true;
      t.cancel();
    };
  });
});

/// La cadence de relecture (et d'envoi, carte ouverte) — celle du serveur
/// (`map_rules.friend_live_every`).
const friendsRefreshEvery = Duration(seconds: 10);

enum LocationRequestEtat { enAttente, acceptee, refusee, expiree }

/// L'état d'une demande de position, tel que le serveur le calcule.
class LocationRequestState {
  const LocationRequestState({
    required this.etat,
    required this.requesterId,
    required this.targetId,
  });

  final LocationRequestEtat etat;
  final String requesterId;
  final String targetId;
}

/// L'état d'une demande, relu à la demande (après une réponse, on invalide).
final locationRequestStateProvider = FutureProvider.autoDispose
    .family<LocationRequestState?, String>(
      (ref, id) => ref.watch(friendsMapRepositoryProvider).requestState(id),
    );
