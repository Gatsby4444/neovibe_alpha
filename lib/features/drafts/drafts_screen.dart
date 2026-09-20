import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/drafts/draft_store.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/formats.dart';
import '../../core/motion.dart';
import '../cards/card_capture_screen.dart';
import '../cards/vibe_draft_keeper.dart';
import '../library/album_editor/album_flow.dart';

/// **Le casier des brouillons** (Réglages › Brouillons — Jay, 2026-09-20 :
/// *« comme sur les mails »*) : tout ce qui a été commencé et pas publié,
/// repris **à l'étape et à la retouche près** où il a été laissé. Trois
/// jours, puis purgé.
class DraftsScreen extends ConsumerWidget {
  const DraftsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drafts = ref.watch(draftsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Brouillons')),
      body: drafts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (list) => list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(NeoSpace.xl),
                  child: Text(
                    'Aucun brouillon.\nUne publication ou un Flow commencé '
                    'sans être publié se retrouve ici 3 jours. Une Vibe, '
                    'seulement si tu le demandes en la quittant.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.muted),
                  ),
                ),
              )
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => _DraftTile(draft: list[i]),
              ),
      ),
    );
  }
}

class _DraftTile extends ConsumerWidget {
  const _DraftTile({required this.draft});

  final Draft draft;

  String get _kind => switch (draft.kind) {
    DraftKind.publication => 'Publication',
    DraftKind.flow => 'Flow',
    DraftKind.vibe => 'Vibe',
  };

  String get _step => switch (draft.step) {
    'caption' => 'à la légende',
    'share' => 'au partage',
    'capture' => 'à la prise',
    _ => 'à l\'édition',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cover = draft.cover;
    final reste = draft.expiresAt.difference(DateTime.now());
    final expire = reste.inHours < 1
        ? 'expire dans moins d\'une heure'
        : reste.inHours < 24
        ? 'expire dans ${reste.inHours} h'
        : 'expire dans ${reste.inDays} j';
    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 60,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(NeoRadius.sm),
          child: cover != null && File(cover).existsSync()
              ? Image.file(File(cover), fit: BoxFit.cover, cacheWidth: 160)
              : ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.edit_note, size: 22),
                ),
        ),
      ),
      title: Text('$_kind · ${draft.summary}'),
      subtitle: Text(
        'Laissée $_step · ${timeAgo(draft.updatedAt)} · $expire',
        style: TextStyle(color: context.muted, fontSize: 12),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Supprimer',
        onPressed: () => _supprimer(context, ref),
      ),
      onTap: () => _reprendre(context),
    );
  }

  Future<void> _reprendre(BuildContext context) async {
    switch (draft.kind) {
      case DraftKind.publication || DraftKind.flow:
        await AlbumFlow.resume(context, draft);
      case DraftKind.vibe:
        await Navigator.of(context).push(
          NeoFadeRoute(
            builder: (_) =>
                CardCaptureScreen(resume: VibeResume.fromDraft(draft)),
          ),
        );
    }
  }

  Future<void> _supprimer(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer ce brouillon ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(draftStoreProvider).delete(draft.id);
  }
}
