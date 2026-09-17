import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../library_repository.dart';
import 'album_draft.dart';
import 'album_export.dart';

/// Où en est la publication d'un album : rendu des médias, puis envoi.
///
/// Un seul album à la fois — appuyer sur « Publier » rend la main tout de
/// suite (comme l'envoi d'une Vibe, 2026-09-14), et le profil affiche ce
/// bandeau jusqu'à « Publié ». Le rendu d'une vidéo prend des secondes, l'envoi
/// de onze médias une minute : sans ce retour, on croit que rien ne se passe.
class AlbumPublishState {
  const AlbumPublishState({
    required this.phase,
    this.done = 0,
    this.total = 0,
    this.progress = 0,
    this.error,
    this.itemId,
  });

  static const idle = AlbumPublishState(phase: AlbumPublishPhase.idle);

  final AlbumPublishPhase phase;

  /// Rendu : médias rendus / à rendre. Envoi : fichiers déposés / à déposer.
  final int done;
  final int total;

  /// Rendu : l'avancement du média en cours (0..1), pour les vidéos.
  final double progress;
  final String? error;
  final String? itemId;

  bool get isBusy =>
      phase == AlbumPublishPhase.rendering ||
      phase == AlbumPublishPhase.uploading;

  /// Ce que le bandeau dit.
  String get label => switch (phase) {
    AlbumPublishPhase.idle => '',
    AlbumPublishPhase.rendering =>
      'Préparation… ${done + 1}/$total'
          '${progress > 0 && progress < 1 ? ' (${(progress * 100).round()} %)' : ''}',
    AlbumPublishPhase.uploading => 'Publication… $done/$total',
    AlbumPublishPhase.done => 'Publié',
    AlbumPublishPhase.failed => 'Échec : ${error ?? 'inconnu'}',
  };
}

enum AlbumPublishPhase { idle, rendering, uploading, done, failed }

class AlbumPublishQueue extends Notifier<AlbumPublishState> {
  @override
  AlbumPublishState build() => AlbumPublishState.idle;

  /// Publie [draft] en arrière-plan. Refuse si un album est déjà en cours.
  Future<void> publish(AlbumDraft draft) async {
    if (state.isBusy) return;
    final total = draft.media.length;
    state = AlbumPublishState(
      phase: AlbumPublishPhase.rendering,
      done: 0,
      total: total,
    );
    final temp = await getTemporaryDirectory();
    final dir = Directory(
      '${temp.path}/album_${DateTime.now().millisecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    try {
      final rendered = <AlbumMediaUpload>[];
      for (var i = 0; i < total; i++) {
        state = AlbumPublishState(
          phase: AlbumPublishPhase.rendering,
          done: i,
          total: total,
        );
        rendered.add(
          await AlbumExport.render(
            draft.media[i],
            draft.aspect,
            dir,
            onProgress: (p) => state = AlbumPublishState(
              phase: AlbumPublishPhase.rendering,
              done: i,
              total: total,
              progress: p,
            ),
          ),
        );
      }
      final files =
          rendered.length + rendered.where((m) => m.poster != null).length;
      state = AlbumPublishState(
        phase: AlbumPublishPhase.uploading,
        done: 0,
        total: files,
      );
      final id = await ref
          .read(libraryRepositoryProvider)
          .publishAlbum(
            AlbumUpload(
              media: rendered,
              aspect: draft.aspect,
              caption: draft.caption.trim().isEmpty
                  ? null
                  : draft.caption.trim(),
              captionFont: draft.captionFont?.name,
              isPublic: draft.isPublic,
              shareable: draft.shareable,
              saveable: draft.saveable,
            ),
            onProgress: (done, t) => state = AlbumPublishState(
              phase: AlbumPublishPhase.uploading,
              done: done,
              total: t,
            ),
          );
      state = AlbumPublishState(phase: AlbumPublishPhase.done, itemId: id);
    } catch (e) {
      state = AlbumPublishState(phase: AlbumPublishPhase.failed, error: '$e');
    } finally {
      // Les rendus en clair ne survivent pas à la publication : le scellé est
      // en cache, la source reste dans la galerie de l'utilisateur.
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Efface « Publié » ou l'échec du bandeau.
  void dismiss() {
    if (!state.isBusy) state = AlbumPublishState.idle;
  }
}

final albumPublishQueueProvider =
    NotifierProvider<AlbumPublishQueue, AlbumPublishState>(
      AlbumPublishQueue.new,
    );
