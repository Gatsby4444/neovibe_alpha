import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/moderation.dart';
import '../../core/models/card.dart';
import '../../core/models/message.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/widgets/content_overflow_menu.dart';
import '../connections/connections_repository.dart';
import 'cards_repository.dart';
import 'send/send_common.dart';

/// **Les options d'une Vibe envoyée** (Jay, 2026-09-25) — le même menu « … »
/// que partout ([ContentOverflowMenu]) :
///
/// | Qui | Options |
/// |---|---|
/// | son auteur | Modifier · Supprimer (pour tout le monde) |
/// | celui qui l'a reçue | Supprimer pour moi · Signaler · Bloquer |
///
/// « Supprimer pour moi » vise le **container** de ce chat ([message]) : la
/// même Vibe envoyée ailleurs n'est pas touchée. Sans [message] (ouverte
/// hors d'un chat), l'option n'est pas proposée.
class SentVibeMenu extends ConsumerWidget {
  const SentVibeMenu({
    super.key,
    required this.card,
    this.message,
    this.color = Colors.white,
    this.onGone,
  });

  final CardModel card;
  final Message? message;
  final Color color;

  /// Appelé quand la Vibe a disparu pour moi — le visionneur se ferme.
  final VoidCallback? onGone;

  ContentOverflowMenu _menu(BuildContext context, WidgetRef ref) {
    final mine = card.ownerId == ref.read(currentUserIdProvider);
    final auteur = ref.read(profileByIdProvider(card.ownerId)).value;
    final repo = ref.read(cardsRepositoryProvider);
    final msg = message;

    Future<void> agir(Future<void> Function() geste, String fait) async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await geste();
        messenger.showSnackBar(SnackBar(content: Text(fait)));
        onGone?.call();
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(messageServeur(e))));
      }
    }

    return ContentOverflowMenu(
      reportTarget: SentVibeReportTarget(card.id),
      authorId: card.ownerId,
      authorName: auteur?.displayName,
      color: color,
      mine: mine,
      onEdit: mine ? () => showSentVibeEditSheet(context, card) : null,
      onRemove: mine
          ? () async {
              if (await _confirmer(context) != true) return;
              await agir(() => repo.deleteSent(card), 'Vibe supprimée');
            }
          : null,
      removeLabel: 'Supprimer',
      removeDetail: 'Elle disparaît de tous les chats où tu l\'as envoyée.',
      onHide: !mine && msg != null
          ? () => agir(
              () => repo.hideMessage(msg.id, msg.conversationId),
              'Vibe retirée pour toi',
            )
          : null,
    );
  }

  /// L'appui long sur un container ouvre la même feuille que le « … ».
  static Future<void> open(
    BuildContext context,
    WidgetRef ref,
    CardModel card, {
    Message? message,
  }) => SentVibeMenu(
    card: card,
    message: message,
  )._menu(context, ref).open(context, ref);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(profileByIdProvider(card.ownerId));
    return _menu(context, ref);
  }

  static Future<bool?> _confirmer(BuildContext context) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer cette Vibe ?'),
      content: const Text(
        'Elle disparaît de tous les chats où tu l\'as envoyée, même pour ceux '
        'qui ne l\'ont pas encore ouverte. Ça ne s\'annule pas.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
}

/// **Modifier MA Vibe envoyée** : les règles de l'envoi — ouvertures, durée,
/// barre de lecture, « sauvegardable » — avec le même éditeur que la roue ⚙︎
/// de l'écran d'envoi. La prise ne se retouche pas.
Future<void> showSentVibeEditSheet(BuildContext context, CardModel card) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SentVibeEditSheet(card: card),
    );

class _SentVibeEditSheet extends ConsumerStatefulWidget {
  const _SentVibeEditSheet({required this.card});
  final CardModel card;

  @override
  ConsumerState<_SentVibeEditSheet> createState() => _SentVibeEditSheetState();
}

class _SentVibeEditSheetState extends ConsumerState<_SentVibeEditSheet> {
  late int? _maxViews = widget.card.maxViews;
  late int? _duration = widget.card.viewDurationSeconds;
  late bool _scrubbable = widget.card.scrubbable;
  late bool _saveable = widget.card.saveable;
  var _busy = false;
  String? _error;

  Future<void> _enregistrer() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(cardsRepositoryProvider)
          .updateSent(
            widget.card,
            maxViews: _maxViews,
            viewDurationSeconds: widget.card.acceptsDuration ? _duration : null,
            scrubbable: _scrubbable,
            saveable: _saveable,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = messageServeur(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(
          NeoSpace.lg,
          0,
          NeoSpace.lg,
          NeoSpace.lg,
        ),
        children: [
          Text(
            'Modifier ta Vibe',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            'Vaut pour tous ceux qui l\'ont reçue, dès leur prochaine '
            'ouverture.',
            style: TextStyle(color: context.muted, fontSize: 12),
          ),
          const SizedBox(height: NeoSpace.md),
          ViewingRulesEditor(
            acceptsDuration: card.acceptsDuration,
            hasVideo: card.hasVideo,
            maxViews: _maxViews,
            viewDuration: _duration,
            scrubbable: _scrubbable,
            onChanged: (views, duree, scrub) => setState(() {
              _maxViews = views;
              _duration = duree;
              _scrubbable = scrub;
            }),
          ),
          if (card.type.canBeSaveable)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sauvegardable'),
              subtitle: Text(
                'Ceux qui l\'ont reçue pourront la garder.',
                style: TextStyle(color: context.muted),
              ),
              value: _saveable,
              onChanged: _busy ? null : (v) => setState(() => _saveable = v),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: NeoSpace.sm),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: NeoSpace.md),
          FilledButton(
            onPressed: _busy ? null : _enregistrer,
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }
}
