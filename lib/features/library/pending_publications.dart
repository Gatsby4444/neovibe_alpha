import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/content_face.dart';
import '../../core/content/content_media_cache.dart';
import '../../core/content/own_keys.dart';
import '../../core/publish/publish_bridge.dart';
import '../../core/supabase_providers.dart';
import 'library_repository.dart';

/// **Les publications en cours, telles que la grille du profil les montre.**
///
/// Une vue dérivée des instantanés du service natif ([PublishBridge.events]) :
/// seules celles que l'utilisateur a **publiées** (« Publier » pressé) y
/// figurent. Une Vibe est libérée dès son dépôt (2026-09-21) : elle apparaît
/// dans la grille à l'instant où on envoie, avec son avancement — comme
/// Instagram.
///
/// Quand une publication est **finie**, c'est ici que la liste de la
/// bibliothèque est invalidée (l'invalidation appartient à l'écriture — et
/// l'écriture, c'est le service qui l'a faite). La case reste jusqu'à ce que
/// la grille ait vu la vraie publication ([seen]) ; alors le natif est
/// acquitté et efface son dossier.
class PendingPublications extends Notifier<List<PendingPublication>> {
  StreamSubscription<Object>? _sub;
  final _acked = <String>{};

  /// Les publications dont la fin a déjà été annoncée : la liste ne
  /// s'invalide et le cache ne se balaie qu'UNE fois par publication. Avant
  /// (2026-09-20), l'annonce se décidait sur l'état affiché — vide à chaque
  /// ouverture de l'écran — et repartait donc à chaque instantané.
  final _announced = <String>{};

  @override
  List<PendingPublication> build() {
    _sub = PublishBridge.instance.events.listen(_onEvent);
    ref.onDispose(() => _sub?.cancel());
    // L'état au moment où l'écran s'ouvre : le service a pu finir pendant
    // que l'app était fermée.
    unawaited(PublishBridge.instance.pending().then(_apply));
    return const [];
  }

  void _onEvent(Object e) {
    if (e is List<PendingPublication>) _apply(e);
  }

  void _apply(List<PendingPublication> all) {
    final shown =
        all
            .where((p) => p.released && p.phase != 'cancelled')
            .where((p) => !_acked.contains(p.id))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final p in shown) {
      if (p.isDone && _announced.add(p.id)) _publiee();
    }
    if (!listEquals(shown, state)) state = shown;
  }

  /// Une publication vient d'être inscrite : la bibliothèque a changé.
  void _publiee() {
    final me = ref.read(currentUserIdProvider);
    if (me != null) {
      ref.invalidate(libraryItemsProvider(me));
      ref.invalidate(libraryKeysProvider(me));
    }
    // Le service a déposé les scellés dans le cache de mes contenus : on
    // le ramène sous son plafond.
    unawaited(ref.read(contentMediaCacheProvider).enforceOwnLimit());
  }

  /// La grille affiche ces publications : celles qui étaient en attente et
  /// qui sont maintenant dans la liste sont acquittées.
  void seen(Iterable<String> itemIds) {
    final ids = itemIds.toSet();
    for (final p in state) {
      if (p.isDone && ids.contains(p.id) && _acked.add(p.id)) {
        unawaited(PublishBridge.instance.ack(p.id));
      }
    }
    final rest = state.where((p) => !_acked.contains(p.id)).toList();
    if (rest.length != state.length) state = rest;
  }

  Future<void> retry(String id) => PublishBridge.instance.retry(id);

  /// Abandonner une publication échouée : le natif efface son dossier et ce
  /// qui était au coffre ; la clé locale, qui ne déchiffre plus rien, part.
  Future<void> abandon(String id) async {
    await PublishBridge.instance.cancel(id);
    await ref.read(ownKeyStoreProvider).remove(id);
  }
}

final pendingPublicationsProvider =
    NotifierProvider<PendingPublications, List<PendingPublication>>(
      PendingPublications.new,
    );
