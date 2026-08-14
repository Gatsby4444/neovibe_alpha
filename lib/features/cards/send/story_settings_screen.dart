import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/saved_store.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/send_wave.dart';
import '../../stories/stories_repository.dart';
import 'send_common.dart';
import 'vibe_draft.dart';

/// **Étape 2 — la story.** 24 h, aucune limite de vues, aucune durée de
/// lecture.
///
/// Ces règles-là n'existent pas ici, elles ne sont pas « neutralisées » : le
/// média part directement dans le coffre `stories`, avec son propre Content ID
/// et sa propre règle d'accès. Aucune Card n'est créée. C'est précisément ce
/// que la séparation des formats a permis de supprimer, et c'est pour ça que
/// cet écran est court — il n'a rien à désactiver.
class StorySettingsScreen extends ConsumerStatefulWidget {
  const StorySettingsScreen({super.key, required this.draft});

  final VibeDraft draft;

  @override
  ConsumerState<StorySettingsScreen> createState() =>
      _StorySettingsScreenState();
}

class _StorySettingsScreenState extends ConsumerState<StorySettingsScreen> {
  var _loading = false;

  /// L'auteur autorise la propagation de cercle en cercle, sans limite de sauts
  /// (décision de Jay 2026-08-11). **Faux par défaut** — le partage hors cercle
  /// est un acte délibéré, repris à chaque publication ; il n'y a
  /// volontairement pas de réglage global « compte public ».
  var _shareable = false;

  /// Ceux qui la voient pourront la garder dans leurs Enregistrements.
  var _saveable = false;

  Future<void> _send() async {
    setState(() => _loading = true);
    final draft = widget.draft;
    try {
      final id = await ref
          .read(storiesRepositoryProvider)
          .publish(
            front: draft.front,
            back: draft.back,
            type: draft.type,
            frontIsVideo: draft.frontIsVideo,
            backIsVideo: draft.backIsVideo,
            shareable: _shareable,
            saveable: _saveable,
          );
      await ref.read(savedStoreProvider).rekey(draft.localId, id);
      ref.invalidate(savedItemsProvider);
      if (!mounted) return;
      // La vague part AVANT le depilage : elle vit dans l'Overlay racine, donc
      // elle survit a la navigation, mais il lui faut un contexte encore monte.
      SendWave.play(context);
      Navigator.of(context).popUntil((r) => r.isFirst);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Story publiée ✓')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlySendError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final storiesPublic =
        ref.watch(myProfileProvider).value?.storiesPublic ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Story '),
            VibeTypeChip(type: draft.type),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              storiesPublic
                  ? '24 h, sans limite de vues. Visible par tes amis ET par les '
                        'personnes que tu croises — tes stories sont publiques.'
                  : '24 h, sans limite de vues, visible par tes amis.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: context.muted),
            ),
          ),
          ShareableSwitch(
            value: _shareable,
            onChanged: (v) => setState(() => _shareable = v),
          ),
          SaveableSwitch(
            type: draft.type,
            value: _saveable,
            onChanged: (v) => setState(() => _saveable = v),
          ),
          SaveForMeButton(draft: draft),
          const Spacer(),
          SendActionBar(
            label: 'Publier ma story',
            loading: _loading,
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}
