import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/send_wave.dart';
import '../../conversations/conversations_repository.dart';
import '../../library_vibes/library_vibes_repository.dart';
import 'send_common.dart';
import 'vibe_draft.dart';

/// **Étape 2 — la bibliothèque de conversation.** Quatrième contexte, autonome
/// depuis le 2026-08-10 (coffre `library_vault`, aucun original en clair).
///
/// ⚠️ **Pas de bouton « Enregistrer pour moi » ici, et c'est une règle produit,
/// pas un oubli** : le principe même de la bibliothèque éphémère est que
/// l'auteur ne revoie pas son ajout avant le reveal. L'écran unique portait
/// cette règle sous la forme d'un `if (id != null)` silencieux — la case était
/// cochable, elle ne faisait simplement rien. Ici la règle se lit : le bouton
/// n'existe pas.
class ConversationLibrarySettingsScreen extends ConsumerStatefulWidget {
  const ConversationLibrarySettingsScreen({super.key, required this.draft});

  final VibeDraft draft;

  @override
  ConsumerState<ConversationLibrarySettingsScreen> createState() =>
      _ConversationLibrarySettingsScreenState();
}

class _ConversationLibrarySettingsScreenState
    extends ConsumerState<ConversationLibrarySettingsScreen> {
  var _loading = false;
  var _saveable = false;
  String? _conversationId;

  Future<void> _send() async {
    if (_conversationId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Choisis la conversation dont tu veux garnir la bibliothèque.',
          ),
        ),
      );
      return;
    }
    setState(() => _loading = true);
    final draft = widget.draft;
    try {
      await ref
          .read(libraryVibesRepositoryProvider)
          .addVibe(
            conversationId: _conversationId!,
            type: draft.type,
            source: draft.front,
            isVideo: draft.frontIsVideo,
            back: draft.back,
            backIsVideo: draft.backIsVideo,
            saveableByOthers: _saveable,
          );
      if (!mounted) return;
      // La vague part AVANT le depilage : elle vit dans l'Overlay racine, donc
      // elle survit a la navigation, mais il lui faut un contexte encore monte.
      SendWave.play(context);
      Navigator.of(context).popUntil((r) => r.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ajoutée à la bibliothèque ✓')),
      );
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
    final me = ref.watch(currentUserIdProvider) ?? '';
    final conversations = ref.watch(conversationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Bibliothèque de conv. '),
            VibeTypeChip(type: draft.type),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              'Masquée pour tous, toi compris, jusqu\'au reveal de 18h30. '
              'Tu ne pourras pas la revoir avant.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: context.muted),
            ),
          ),
          conversations.when(
            loading: () => const ListTile(
              dense: true,
              title: Text('Chargement des conversations…'),
            ),
            error: (e, _) => ListTile(dense: true, title: Text('Erreur : $e')),
            data: (list) => list.isEmpty
                ? const ListTile(
                    dense: true,
                    title: Text('Aucune conversation.'),
                    subtitle: Text(
                      'Une bibliothèque appartient à une conversation '
                      'existante.',
                    ),
                  )
                : ListTile(
                    dense: true,
                    leading: const Icon(Icons.forum_outlined),
                    title: DropdownButton<String>(
                      isExpanded: true,
                      value: _conversationId,
                      hint: const Text('Choisir la conversation'),
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final conv in list)
                          DropdownMenuItem(
                            value: conv.id,
                            child: Text(
                              conv.displayName(me),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (id) => setState(() => _conversationId = id),
                    ),
                  ),
          ),
          SaveableSwitch(
            type: draft.type,
            value: _saveable,
            onChanged: (v) => setState(() => _saveable = v),
          ),
          const Spacer(),
          SendActionBar(
            label: 'Ajouter à la bibliothèque',
            loading: _loading,
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}
