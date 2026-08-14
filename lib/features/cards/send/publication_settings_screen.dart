import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/saved_store.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/send_wave.dart';
import '../../library/library_repository.dart';
import 'send_common.dart';
import 'vibe_draft.dart';

/// **Étape 2 — la bibliothèque de profil.** Publication **permanente** —
/// décision de Jay (2026-08-11) : « c'est ce qui a toujours été décidé ».
///
/// Aucune Card n'est créée : la publication porte ses propres faces dans le
/// coffre `library`, avec sa seule règle d'accès. Ni limite de vues ni durée de
/// lecture — comme pour la story, elles n'existent pas ici plutôt que d'être
/// neutralisées au cas par cas.
///
/// 🐛 **Un réglage mort disparaît avec ce découpage** : l'écran unique affichait
/// « Barre de lecture contrôlable » dès qu'une face était vidéo et que la
/// destination n'était pas une story — donc ici. Or `LibraryRepository.publish`
/// n'a **pas** de paramètre `scrubbable` : l'interrupteur se laissait basculer
/// et n'était transmis nulle part. `scrubbable` n'existe que sur `cards`, donc
/// que dans le cercle.
class PublicationSettingsScreen extends ConsumerStatefulWidget {
  const PublicationSettingsScreen({super.key, required this.draft});

  final VibeDraft draft;

  @override
  ConsumerState<PublicationSettingsScreen> createState() =>
      _PublicationSettingsScreenState();
}

class _PublicationSettingsScreenState
    extends ConsumerState<PublicationSettingsScreen> {
  var _loading = false;

  /// Publication PUBLIQUE : un rang au-dessus de « connexions » — visible par
  /// toute personne accédant au profil par un moyen légitime.
  var _public = false;
  var _shareable = false;
  var _saveable = false;

  Future<void> _send() async {
    setState(() => _loading = true);
    final draft = widget.draft;
    try {
      final id = await ref
          .read(libraryRepositoryProvider)
          .publish(
            front: draft.front,
            back: draft.back,
            type: draft.type,
            frontIsVideo: draft.frontIsVideo,
            backIsVideo: draft.backIsVideo,
            isPublic: _public,
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Publiée dans ta bibliothèque ✓')),
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
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Bibliothèque '),
            VibeTypeChip(type: draft.type),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              'Elle reste dans ta bibliothèque, sans limite de vues ni de '
              'durée.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: context.muted),
            ),
          ),
          SwitchListTile(
            title: const Text('Publication publique'),
            subtitle: const Text(
              'Visible par toute personne qui accède à ton profil '
              '(croisements ping compris) — tag « Public » affiché',
            ),
            value: _public,
            onChanged: (v) => setState(() => _public = v),
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
          SendActionBar(label: 'Publier', loading: _loading, onPressed: _send),
        ],
      ),
    );
  }
}
