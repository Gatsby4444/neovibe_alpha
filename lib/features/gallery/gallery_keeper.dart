import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/saved_store.dart';
import '../../core/diagnostics/app_log.dart';
import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import '../events/events_providers.dart';
import '../events/events_repository.dart';
import '../library_vibes/library_vibes_repository.dart';
import 'moment_store.dart';

/// **Le gardien de ma galerie** — il copie sur le téléphone ce que le
/// serveur va oublier.
///
/// Il observe mes événements (`my_events`) et, pour chacun où j'ai été :
///
/// 1. **tient l'album à jour** ([Moment]) : titre, quand, où, mes amis qui
///    y étaient, les nombres du récap — tant que l'événement vit, puis
///    figé à sa fermeture ;
/// 2. **garde les Vibes du Drop** à la fermeture, dans mes Enregistrements
///    (`SavedStore`, le cinquième contexte : en clair sur l'appareil,
///    permanent) — **celles que leur auteur a laissées sauvegardables, et
///    les miennes**. Les autres se regardent dans le Drop tant qu'il vit
///    (cinq jours), puis disparaissent : c'est la règle de sauvegarde qui
///    existe déjà, appliquée telle quelle. Jay, 2026-09-21 : *« le serveur
///    dépose les Vibes partagées avec les amis dessus »* — c'est ce dépôt.
///
/// ⚠️ Il ne décide rien de la galerie : il écrit ce que le serveur dit, et
/// la galerie lit le magasin. Rien ne remonte au serveur.
class GalleryKeeper extends Notifier<int> {
  final _busy = <String>{};

  @override
  int build() {
    final events = ref.watch(myEventsProvider).value;
    final me = ref.watch(currentUserIdProvider);
    if (events != null && me != null) {
      unawaited(_sync(events, me));
    }
    return 0;
  }

  Future<void> _sync(List<NeoEvent> events, String me) async {
    final store = ref.read(momentStoreProvider);
    for (final e in events) {
      // Pas encore commencé, ou jamais ouvert : rien à garder.
      if (e.openedAt == null) continue;
      if (_busy.contains(e.id)) continue;
      _busy.add(e.id);
      try {
        final existing = await store.get(e.id);
        // Y ai-je été ? Un événement privé où j'étais invité sans venir
        // n'est pas un moment vécu.
        if (existing == null &&
            !e.iAmPresent &&
            !await ref.read(eventsRepositoryProvider).wasThere(e.id)) {
          continue;
        }
        // Déjà figé : plus rien à faire.
        if (existing != null && existing.kept) continue;

        EventRecap? recap;
        try {
          recap = await ref.read(eventsRepositoryProvider).recap(e.id);
        } catch (_) {
          // Le serveur peut refuser (événement purgé entre-temps) : on garde
          // ce qu'on a.
        }
        var moment =
            (existing ??
                    Moment(
                      id: e.id,
                      title: e.title,
                      autoCreated: e.autoCreated,
                      kind: e.kind.name,
                      startedAt: e.openedAt ?? e.startsAt,
                      lat: e.lat,
                      lon: e.lon,
                      venueName: e.venueName,
                    ))
                .copyWith(
                  title: e.title,
                  closedAt: e.closedAt,
                  friends: recap?.friendsPresent,
                  presentCount: recap?.presentCount,
                  vibeCount: recap?.vibeCount,
                  metCount: recap?.metCount,
                  newFriendCount: recap?.newFriendCount,
                );

        if (e.isClosed) {
          final kept = await _keepVibes(e, me, moment.keptVibeIds);
          moment = moment.copyWith(keptVibeIds: kept, kept: true);
        }
        await store.upsert(moment);
      } catch (err) {
        AppLog.instance.error('galerie', 'moment ${e.id} : $err');
      } finally {
        _busy.remove(e.id);
      }
    }
  }

  /// Copie dans mes Enregistrements les Vibes du Drop que j'ai le droit de
  /// garder. Rend les identifiants gardés (anciens compris).
  Future<List<String>> _keepVibes(
    NeoEvent e,
    String me,
    List<String> already,
  ) async {
    final repo = ref.read(libraryVibesRepositoryProvider);
    final saved = ref.read(savedStoreProvider);
    final kept = [...already];
    final vibes = await repo.vibesOf(e.conversationId);
    for (final v in vibes) {
      if (kept.contains(v.id)) continue;
      final mine = v.authorId == me;
      if (!mine && !v.saveableByOthers) continue;
      if (!v.revealedMaintenant) continue;
      try {
        final front = await repo.openRevealed(v, isVideo: v.frontIsVideo);
        final back = v.hasBack
            ? await repo.openRevealed(v, isVideo: v.backIsVideo, back: true)
            : null;
        await saved.add(
          contentId: v.id,
          cardType: v.type,
          writeFront: front.writeClearTo,
          writeBack: back?.writeClearTo,
          frontIsVideo: v.frontIsVideo,
          backIsVideo: v.backIsVideo,
          mine: mine,
        );
        kept.add(v.id);
      } catch (err) {
        AppLog.instance.error('galerie', 'Vibe ${v.id} non gardée : $err');
      }
    }
    return kept;
  }
}

final galleryKeeperProvider = NotifierProvider<GalleryKeeper, int>(
  GalleryKeeper.new,
);
