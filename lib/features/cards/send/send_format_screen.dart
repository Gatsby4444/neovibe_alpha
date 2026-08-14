import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/card.dart';
import '../../../core/prefs.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import 'circle_settings_screen.dart';
import 'conversation_library_settings_screen.dart';
import 'publication_settings_screen.dart';
import 'send_common.dart';
import 'story_settings_screen.dart';
import 'vibe_draft.dart';

/// Les contextes de diffusion, **mutuellement exclusifs** depuis la refonte du
/// 2026-08-11.
///
/// C'est LA décision de fond de ce chantier-là : un contenu part dans **un
/// seul** contexte, et n'en change jamais. Avant, une même Vibe pouvait être
/// envoyée en DM, publiée en bibliothèque ET mise en story — trois régimes
/// d'accès contradictoires sur un seul fichier, d'où un compteur de vues
/// partagé entre le chat et la story, et une suppression qui en emportait deux
/// autres.
///
/// Cela n'empêche pas un contenu de circuler : une story publiée peut ensuite
/// être **repartagée** dans une conversation. Mais un repartage est un
/// raccourci vers la source, jamais une copie.
enum SendFormat {
  story,
  publication,
  circle,
  conversationLibrary;

  String get label => switch (this) {
    SendFormat.story => 'Story',
    SendFormat.publication => 'Bibliothèque',
    SendFormat.circle => 'Cercle',
    SendFormat.conversationLibrary => 'Bibliothèque de conversation',
  };

  IconData get icon => switch (this) {
    SendFormat.story => Icons.auto_awesome,
    SendFormat.publication => Icons.grid_view,
    SendFormat.circle => Icons.send,
    SendFormat.conversationLibrary => Icons.lock_clock,
  };
}

/// **Étape 1 — quel format je crée.**
///
/// Découpage demandé par Jay le 2026-08-14 : « d'abord l'utilisateur choisit
/// quel format il souhaite créer, ensuite il arrive sur l'interface dédiée au
/// paramétrage de ce format ».
///
/// L'écran unique d'avant affichait les réglages des quatre destinations dans
/// un seul `build`, sous une pile de `if (_destination == …)`. Ce n'était pas
/// qu'un problème de longueur : les réglages **survivaient au changement de
/// destination**, donc un `shareable` activé pour une story repartait avec une
/// publication sans que rien ne l'annonce. Ici, chaque paramétrage naît avec
/// son écran et meurt avec lui — un réglage ne peut plus traverser une
/// frontière qu'il n'a pas le droit de franchir.
class SendFormatScreen extends ConsumerStatefulWidget {
  const SendFormatScreen({super.key, required this.draft});

  final VibeDraft draft;

  @override
  ConsumerState<SendFormatScreen> createState() => _SendFormatScreenState();
}

class _SendFormatScreenState extends ConsumerState<SendFormatScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => maybeShowVibesExplainer(context, ref),
    );
  }

  /// Ce format est-il ouvert à CETTE capture ?
  ///
  /// Seule la bibliothèque de conversation refuse quelque chose, et pour deux
  /// règles déjà arrêtées par Jay le 2026-08-10 : **pas d'import galerie**
  /// (« de vraies photos ou vidéos ») et **pas de BeReal**. Les faire respecter
  /// ici plutôt que d'ouvrir la porte puis d'échouer à l'envoi.
  bool _allows(SendFormat format) {
    if (format != SendFormat.conversationLibrary) return true;
    return !widget.draft.imported && widget.draft.type != CardType.bereal;
  }

  /// Ce que le format implique, en une phrase. Sans elle, le choix exclusif
  /// serait une contrainte sans explication.
  String _hint(SendFormat format) {
    final storiesPublic =
        ref.watch(myProfileProvider).value?.storiesPublic ?? false;
    return switch (format) {
      SendFormat.story =>
        storiesPublic
            ? '24 h, sans limite de vues. Visible par tes amis ET par les '
                  'personnes que tu croises — tes stories sont publiques.'
            : '24 h, sans limite de vues, visible par tes amis.',
      SendFormat.publication =>
        'Elle reste dans ta bibliothèque, sans limite de vues ni de durée.',
      SendFormat.circle =>
        'Le seul envoi où les limites d\'ouvertures et de durée s\'appliquent. '
            'Jamais repartageable.',
      SendFormat.conversationLibrary =>
        _allows(SendFormat.conversationLibrary)
            ? 'Masquée pour tous, toi compris, jusqu\'au reveal de 18h30.'
            : 'Indisponible ici : une bibliothèque n\'accepte ni import '
                  'galerie ni BeReal.',
    };
  }

  void _open(SendFormat format) {
    final draft = widget.draft;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => switch (format) {
          SendFormat.story => StorySettingsScreen(draft: draft),
          SendFormat.publication => PublicationSettingsScreen(draft: draft),
          SendFormat.circle => CircleSettingsScreen(draft: draft),
          SendFormat.conversationLibrary => ConversationLibrarySettingsScreen(
            draft: draft,
          ),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Envoyer '),
            VibeTypeChip(type: widget.draft.type),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
            child: Text(
              'Où va cette Vibe ? Un contenu part dans un seul format, et n\'en '
              'change jamais.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: context.muted),
            ),
          ),
          for (final format in SendFormat.values)
            _FormatCard(
              format: format,
              hint: _hint(format),
              enabled: _allows(format),
              onTap: () => _open(format),
            ),
        ],
      ),
    );
  }
}

class _FormatCard extends StatelessWidget {
  const _FormatCard({
    required this.format,
    required this.hint,
    required this.enabled,
    required this.onTap,
  });

  final SendFormat format;
  final String hint;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Card(
        margin: const EdgeInsets.only(bottom: 10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(format.icon, size: 24, color: scheme.primary),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        format.label,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hint,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: context.muted),
                      ),
                    ],
                  ),
                ),
                if (enabled)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, left: 4),
                    child: Icon(
                      Icons.chevron_right,
                      color: context.faint,
                      size: 22,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Popup de première utilisation : comment vivent les Vibes (consigne Jay).
///
/// Appelée depuis l'étape 1 **et** depuis le paramétrage du cercle quand il est
/// atteint directement (envoi depuis un chat) — c'est le seul chemin qui saute
/// l'étape 1, et il ne doit pas être le seul à ne rien expliquer.
Future<void> maybeShowVibesExplainer(
  BuildContext context,
  WidgetRef ref,
) async {
  if (ref.read(cardsExplainerShownProvider)) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Comment vivent tes Vibes'),
      content: const SingleChildScrollView(
        child: Text(
          'Dans les chats, une Vibe s\'ouvre un nombre limité de fois '
          '(2 par défaut). Une ouverture, c\'est une ouverture : tant que la '
          'Vibe est ouverte, tu peux la retourner autant que tu veux sans rien '
          'consommer.\n\n'
          'Le temps de lecture est illimité par défaut ; tu peux le limiter '
          'par Vibe. Tes défauts se règlent dans Réglages > Vibes.\n\n'
          'Chaque Vibe apparaît dans le chat comme un container : on clique '
          'pour l\'ouvrir, jamais d\'aperçu. Le container reste 24 h et le '
          'destinataire peut te demander un replay : rien ne se revoit sans '
          'ton accord.\n\n'
          'Si tu l\'envoies à UNE seule personne sans la publier, elle devient '
          'une One of One : exclusive, pour elle seule, à jamais.\n\n'
          'Dans ta bibliothèque, ce que tu publies se regarde sans limite.',
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Compris'),
        ),
      ],
    ),
  );
  await ref.read(cardsExplainerShownProvider.notifier).markShown();
}
