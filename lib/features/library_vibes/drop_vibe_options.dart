import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/moderation.dart';
import '../../core/models/library_vibe.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/widgets/content_overflow_menu.dart';
import '../connections/connections_repository.dart';
import '../events/events_providers.dart';
import 'library_vibes_repository.dart';

/// **Les options d'une Vibe du Drop** (Jay, 2026-09-25) — le même menu « … »
/// que partout ([ContentOverflowMenu]), rempli pour cette Vibe :
///
/// | Qui | Options |
/// |---|---|
/// | son auteur | Modifier · Supprimer |
/// | l'organisateur de la soirée | Supprimer pour moi · Signaler · Bloquer · Supprimer du Drop |
/// | les autres | Supprimer pour moi · Signaler · Bloquer |
///
/// Le serveur tranche les droits ; ce widget ne fait qu'afficher ce qui a un
/// sens. Il sert au « … » du visionneur ET à l'appui long sur une tuile :
/// un seul endroit décide du contenu du menu.
class DropVibeMenu extends ConsumerWidget {
  const DropVibeMenu({
    super.key,
    required this.vibe,
    this.color = Colors.white,
    this.onGone,
  });

  final LibraryVibe vibe;
  final Color color;

  /// Appelé quand la Vibe a disparu pour moi (supprimée ou cachée) — le
  /// visionneur se ferme.
  final VoidCallback? onGone;

  ContentOverflowMenu _menu(BuildContext context, WidgetRef ref) {
    final me = ref.read(currentUserIdProvider);
    final mine = vibe.authorId == me;
    final organisateur =
        ref.read(eventByConversationProvider(vibe.conversationId))?.createdBy ==
        me;
    final auteur = ref.read(profileByIdProvider(vibe.authorId)).value;
    final repo = ref.read(libraryVibesRepositoryProvider);

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
      reportTarget: DropVibeReportTarget(vibe.id),
      authorId: vibe.authorId,
      authorName: auteur?.displayName,
      color: color,
      mine: mine,
      onEdit: mine ? () => showDropVibeEditSheet(context, ref, vibe) : null,
      onRemove: mine
          ? () async {
              if (await _confirmer(context, organisateur: false) != true) {
                return;
              }
              await agir(() => repo.deleteVibe(vibe), 'Vibe supprimée');
            }
          : null,
      removeLabel: 'Supprimer',
      removeDetail: 'Elle disparaît du Drop pour tout le monde.',
      onHide: mine
          ? null
          : () => agir(() => repo.hideVibe(vibe), 'Vibe retirée pour toi'),
      onModeratorRemove: !mine && organisateur
          ? () async {
              if (await _confirmer(context, organisateur: true) != true) {
                return;
              }
              await agir(() => repo.deleteVibe(vibe), 'Vibe supprimée du Drop');
            }
          : null,
    );
  }

  /// L'appui long d'une tuile ouvre la même feuille que le « … ».
  static Future<void> open(
    BuildContext context,
    WidgetRef ref,
    LibraryVibe vibe, {
    VoidCallback? onGone,
  }) => DropVibeMenu(
    vibe: vibe,
    onGone: onGone,
  )._menu(context, ref).open(context, ref);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Le nom de l'auteur, prêt pour « Bloquer … ? ».
    ref.watch(profileByIdProvider(vibe.authorId));
    return _menu(context, ref);
  }

  static Future<bool?> _confirmer(
    BuildContext context, {
    required bool organisateur,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer cette Vibe ?'),
      content: Text(
        organisateur
            ? 'Elle disparaît du Drop de ta soirée, pour tout le monde. Son '
                  'auteur n\'est pas prévenu.'
            : 'Elle disparaît du Drop pour tout le monde. Ça ne s\'annule pas.',
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

/// **Modifier MA Vibe du Drop** : les réglages de l'écran d'ajout, et eux
/// seuls — le titre (Drop d'événement), « sauvegardable par les autres »,
/// « éphémère ». La prise elle-même ne se retouche pas.
Future<void> showDropVibeEditSheet(
  BuildContext context,
  WidgetRef ref,
  LibraryVibe vibe,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _DropVibeEditSheet(vibe: vibe),
);

class _DropVibeEditSheet extends ConsumerStatefulWidget {
  const _DropVibeEditSheet({required this.vibe});
  final LibraryVibe vibe;

  @override
  ConsumerState<_DropVibeEditSheet> createState() => _DropVibeEditSheetState();
}

class _DropVibeEditSheetState extends ConsumerState<_DropVibeEditSheet> {
  late final _title = TextEditingController(text: widget.vibe.title ?? '');
  late bool _saveable = widget.vibe.saveableByOthers;
  late bool _ephemeral = widget.vibe.ephemeral;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _enregistrer() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(libraryVibesRepositoryProvider)
          .updateVibe(
            widget.vibe,
            title: _title.text.trim(),
            saveableByOthers: _saveable,
            ephemeral: _ephemeral,
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
    final evenement =
        ref.watch(eventByConversationProvider(widget.vibe.conversationId)) !=
        null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
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
            const SizedBox(height: NeoSpace.md),
            if (evenement) ...[
              TextField(
                controller: _title,
                maxLength: 60,
                enabled: !_busy,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Un titre (facultatif)',
                ),
              ),
              const SizedBox(height: NeoSpace.sm),
            ],
            // Drop d'événement : suit « éphémère » (2026-09-25).
            if (!evenement)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sauvegardable par les autres'),
                subtitle: Text(
                  'Ils pourront la garder. Toi, tu le peux toujours.',
                  style: TextStyle(color: context.muted),
                ),
                value: _saveable,
                onChanged: _busy ? null : (v) => setState(() => _saveable = v),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Éphémère'),
              subtitle: Text(
                evenement
                    ? (_ephemeral
                          ? 'Personne ne la gardera dans sa galerie.'
                          : 'Chaque participant la garde dans sa galerie.')
                    : _ephemeral
                    ? 'Elle disparaîtra 24 h après le reveal.'
                    : 'Elle restera dans le Drop, en souvenir.',
                style: TextStyle(color: context.muted),
              ),
              value: _ephemeral,
              onChanged: _busy ? null : (v) => setState(() => _ephemeral = v),
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
      ),
    );
  }
}
