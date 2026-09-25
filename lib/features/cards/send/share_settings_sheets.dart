import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/prefs.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../../core/widgets/top_banner.dart';
import '../../connections/friendship.dart';
import 'send_common.dart';
import 'share_defaults.dart';
import 'share_plan.dart';
import 'vibe_draft.dart';

/// **Les deux sur-écrans de réglage de l'écran de partage** (Jay, 2026-09-14).
///
/// > *« On centralise les réglages : ⚙︎ "Publier" affiche les paramètres des
/// > stories et des publications ; ⚙︎ "Groupes et amis" affiche tous les
/// > utilisateurs sélectionnés (uniquement eux) avec l'option Sauvegardable
/// > pour chacun, un bouton "Tout sélectionner", et un bouton "Défauts". Cela
/// > ne rajoute pas une étape, seulement une branche : c'est optionnel. »*
///
/// Chaque feuille reçoit un morceau de plan, le rend modifié. Elle ne parle au
/// réseau que pour **« Défauts »** — et par un dépôt.

// ---------------------------------------------------------------------------
// Une puce de réglage : petite, cliquable, allumée ou éteinte
// ---------------------------------------------------------------------------

/// ⚠️ **Pas un `Switch`.** Six interrupteurs Material dans une ligne la font
/// doubler de hauteur ; la demande de Jay était *« des boutons et containers à
/// taille réduite pour bien proposer toutes les options »*.
class SettingChip extends StatelessWidget {
  const SettingChip({
    super.key,
    required this.label,
    required this.actif,
    required this.onTap,
    this.desactivee = false,
  });

  final String label;
  final bool actif;
  final VoidCallback onTap;
  final bool desactivee;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Opacity(
      opacity: desactivee ? 0.4 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(NeoRadius.pill),
        onTap: desactivee ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: NeoSpace.md,
            vertical: NeoSpace.xs + 2,
          ),
          decoration: BoxDecoration(
            color: actif ? accent.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(NeoRadius.pill),
            border: Border.all(color: actif ? accent : context.palette.line),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: actif ? accent : context.muted,
              fontWeight: actif ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.texte, {this.aide});
  final String texte;
  final String? aide;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(texte, style: Theme.of(context).textTheme.titleMedium),
      if (aide != null) ...[
        const SizedBox(height: 2),
        Text(
          aide!,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: context.muted),
        ),
      ],
      const SizedBox(height: NeoSpace.md),
    ],
  );
}

class _Bloc extends StatelessWidget {
  const _Bloc(this.titre, {required this.child});
  final String titre;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NeoSpace.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(titre, style: context.sectionTitle),
        const SizedBox(height: NeoSpace.sm),
        child,
      ],
    ),
  );
}

/// Le bouton « Défauts » : enregistre ce que la feuille montre comme mes
/// défauts, et le dit.
class _DefaultsButton extends StatelessWidget {
  const _DefaultsButton({required this.onPressed, required this.aide});
  final Future<void> Function() onPressed;
  final String aide;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(aide, style: TextStyle(color: context.faint, fontSize: 11)),
      ),
      const SizedBox(width: NeoSpace.md),
      // ⚠️ **Borné, et ce n'est pas décoratif.** Le thème donne aux boutons
      // contour une largeur minimale INFINIE (`Size.fromHeight(52)`, voir
      // `_outlinedStyle` dans `core/theme.dart`). Nu dans une `Row`, ce
      // bouton réclamait tout, partait hors de l'écran, et le texte d'aide à
      // sa gauche recevait 0 px : **une lettre par ligne**, sans une erreur
      // en release. Vu par Jay le 2026-09-14 (captures). Même piège que le
      // 2026-08-17 (`test/filled_button_row_test.dart`, qui le garde
      // désormais aussi pour `OutlinedButton`).
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 150),
        child: OutlinedButton.icon(
          onPressed: () async {
            await onPressed();
            if (context.mounted) {
              TopBanner.show(context, 'Défauts enregistrés');
            }
          },
          icon: const Icon(Icons.push_pin_outlined, size: 16),
          label: const Text('Défauts'),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// ⚙︎ Publier
// ---------------------------------------------------------------------------

/// Ce que la feuille « Publier » rend : la story et la bibliothèque telles
/// que réglées (nulles si la ligne n'est pas cochée — la feuille règle sans
/// cocher).
class PublicationSettings {
  const PublicationSettings({required this.story, required this.library});
  final StoryShare story;
  final LibraryShare library;
}

class PublicationSettingsSheet extends ConsumerStatefulWidget {
  const PublicationSettingsSheet({
    super.key,
    required this.story,
    required this.library,
    required this.typeAccepteSauvegarde,
    required this.onChanged,
    this.libraryOnly = false,
    this.anchorAvailable = false,
  });

  final StoryShare story;
  final LibraryShare library;
  final bool typeAccepteSauvegarde;

  /// La prise a une position : « Localisée » peut être cochée.
  final bool anchorAvailable;
  final ValueChanged<PublicationSettings> onChanged;

  /// Publication seulement (« Publier » depuis le profil, 2026-09-15) : la
  /// story n'est pas proposée sur l'écran, ses réglages ne le sont pas non
  /// plus (retour de Jay du 2026-09-15).
  final bool libraryOnly;

  @override
  ConsumerState<PublicationSettingsSheet> createState() =>
      _PublicationSettingsSheetState();
}

class _PublicationSettingsSheetState
    extends ConsumerState<PublicationSettingsSheet> {
  late StoryShare _story = widget.story;
  late LibraryShare _library = widget.library;

  void _push() =>
      widget.onChanged(PublicationSettings(story: _story, library: _library));

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NeoSpace.lg,
          0,
          NeoSpace.lg,
          NeoSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetTitle(
              'Réglages de publication',
              aide:
                  'Ils valent pour cet envoi. « Défauts » les garde pour les '
                  'prochains.',
            ),
            if (!widget.libraryOnly)
              _Bloc(
                'Ma story · 24 h',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Visible par',
                      style: TextStyle(color: context.muted, fontSize: 11),
                    ),
                    const SizedBox(height: NeoSpace.xs),
                    // 🔴 **LE PALIER — ce que Snapchat ne sait pas faire.**
                    Wrap(
                      spacing: NeoSpace.sm,
                      runSpacing: NeoSpace.xs,
                      children: [
                        for (final t in FriendshipTier.values)
                          SettingChip(
                            label: switch (t) {
                              FriendshipTier.friend => 'Tous mes amis',
                              FriendshipTier.close => 'Mes proches',
                              FriendshipTier.inner => 'Mes inséparables',
                            },
                            actif: _story.tier == t,
                            onTap: () {
                              setState(() => _story = _story.copyWith(tier: t));
                              _push();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: NeoSpace.sm),
                    Wrap(
                      spacing: NeoSpace.sm,
                      runSpacing: NeoSpace.xs,
                      children: [
                        SettingChip(
                          label: 'Partageable',
                          actif: _story.shareable,
                          onTap: () {
                            setState(
                              () => _story = _story.copyWith(
                                shareable: !_story.shareable,
                              ),
                            );
                            _push();
                          },
                        ),
                        SettingChip(
                          label: 'Sauvegardable',
                          actif: _story.saveable,
                          desactivee: !widget.typeAccepteSauvegarde,
                          onTap: () {
                            setState(
                              () => _story = _story.copyWith(
                                saveable: !_story.saveable,
                              ),
                            );
                            _push();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            _Bloc(
              'Ma bibliothèque · permanente',
              child: Wrap(
                spacing: NeoSpace.sm,
                runSpacing: NeoSpace.xs,
                children: [
                  SettingChip(
                    label: 'Visible par les gens que tu croises',
                    actif: _library.isPublic,
                    onTap: () {
                      setState(
                        () => _library = _library.copyWith(
                          isPublic: !_library.isPublic,
                        ),
                      );
                      _push();
                    },
                  ),
                  // Un consentement à part de « Visible » (Jay, 2026-09-20) :
                  // l'ancre, gommée à 100 m, jamais l'adresse. Grisée sans
                  // position.
                  SettingChip(
                    label: widget.anchorAvailable
                        ? 'Localisée (à 100 m près)'
                        : 'Localisée — position indisponible',
                    actif: _library.anchored && widget.anchorAvailable,
                    desactivee: !widget.anchorAvailable,
                    onTap: () {
                      if (!widget.anchorAvailable) return;
                      setState(
                        () => _library = _library.copyWith(
                          anchored: !_library.anchored,
                        ),
                      );
                      _push();
                    },
                  ),
                  SettingChip(
                    label: 'Partageable',
                    actif: _library.shareable,
                    onTap: () {
                      setState(
                        () => _library = _library.copyWith(
                          shareable: !_library.shareable,
                        ),
                      );
                      _push();
                    },
                  ),
                  SettingChip(
                    label: 'Sauvegardable',
                    actif: _library.saveable,
                    desactivee: !widget.typeAccepteSauvegarde,
                    onTap: () {
                      setState(
                        () => _library = _library.copyWith(
                          saveable: !_library.saveable,
                        ),
                      );
                      _push();
                    },
                  ),
                ],
              ),
            ),
            _DefaultsButton(
              aide: 'Garder ces réglages pour mes prochaines publications',
              onPressed: () => ref
                  .read(shareDefaultsProvider.notifier)
                  .set(
                    ref
                        .read(shareDefaultsProvider)
                        .copyWith(story: _story, library: _library),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ⚙︎ Groupes et amis
// ---------------------------------------------------------------------------

/// Une ligne du sur-écran : un ami ou un groupe **coché**, avec son
/// « Sauvegardable ».
class SelectedRecipient {
  const SelectedRecipient({
    required this.conversationShare,
    required this.friendId,
    required this.isGroup,
  });

  final ConversationShare conversationShare;

  /// L'ami d'en face pour un DM (c'est lui qui peut avoir un défaut) ; nul
  /// pour un groupe.
  final String? friendId;
  final bool isGroup;
}

class RecipientSettings {
  const RecipientSettings({required this.regles, required this.conversations});
  final ViewingRules regles;
  final List<ConversationShare> conversations;
}

class RecipientSettingsSheet extends ConsumerStatefulWidget {
  const RecipientSettingsSheet({
    super.key,
    required this.draft,
    required this.regles,
    required this.selection,
    required this.typeAccepteSauvegarde,
    required this.onChanged,
  });

  final VibeDraft draft;
  final ViewingRules regles;

  /// **Les sélectionnés, et eux seuls** (Jay).
  final List<SelectedRecipient> selection;
  final bool typeAccepteSauvegarde;
  final ValueChanged<RecipientSettings> onChanged;

  @override
  ConsumerState<RecipientSettingsSheet> createState() =>
      _RecipientSettingsSheetState();
}

class _RecipientSettingsSheetState
    extends ConsumerState<RecipientSettingsSheet> {
  late ViewingRules _regles = widget.regles;
  late List<ConversationShare> _conversations = [
    for (final s in widget.selection) s.conversationShare,
  ];

  void _push() => widget.onChanged(
    RecipientSettings(regles: _regles, conversations: _conversations),
  );

  void _setSaveable(ConversationShare c, bool v) {
    setState(() {
      _conversations = [
        for (final x in _conversations)
          if (x.key == c.key) x.copyWith(saveable: v) else x,
      ];
    });
    _push();
  }

  bool get _tousSauvegardables =>
      _conversations.isNotEmpty && _conversations.every((c) => c.saveable);

  Future<void> _enregistrerDefauts() async {
    // Par ami : le serveur, propriétaire seul. Les groupes n'ont pas de
    // défaut propre (Jay : « pour chaque utilisateur »).
    final parAmi = <String, bool>{};
    for (final s in widget.selection) {
      final id = s.friendId;
      if (id == null) continue;
      final courant = _conversations
          .where((c) => c.key == s.conversationShare.key)
          .firstOrNull;
      if (courant != null) parAmi[id] = courant.saveable;
    }
    await ref.read(friendShareDefaultsRepositoryProvider).setMany(parAmi);
    // Les limites : leur propriétaire historique, dans les Réglages.
    await ref
        .read(defaultMaxViewsProvider.notifier)
        .set(_regles.maxViews ?? DefaultMaxViews.unlimited);
    await ref
        .read(defaultViewDurationProvider.notifier)
        .set(_regles.viewDurationSeconds ?? DefaultViewDuration.unlimited);
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NeoSpace.lg,
          0,
          NeoSpace.lg,
          NeoSpace.lg,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            const _SheetTitle(
              'Réglages pour les groupes et amis',
              aide:
                  'Les limites valent pour tout l\'envoi. « Sauvegardable » se '
                  'règle par personne.',
            ),
            _Bloc(
              'Règles de visionnage',
              child: ViewingRulesEditor(
                acceptsDuration: widget.draft.acceptsDuration,
                hasVideo: widget.draft.hasVideo,
                maxViews: _regles.maxViews,
                viewDuration: _regles.viewDurationSeconds,
                scrubbable: _regles.scrubbable,
                onChanged: (views, duree, scrub) {
                  setState(
                    () => _regles = ViewingRules(
                      maxViews: views,
                      viewDurationSeconds: duree,
                      scrubbable: scrub,
                    ),
                  );
                  _push();
                },
              ),
            ),
            if (selection.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: NeoSpace.lg),
                child: Text(
                  'Coche des amis ou des groupes pour régler « Sauvegardable » '
                  'pour chacun.',
                  style: TextStyle(color: context.muted, fontSize: 12),
                ),
              )
            else
              _Bloc(
                'Sauvegardable, pour chacun',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!widget.typeAccepteSauvegarde)
                      Padding(
                        padding: const EdgeInsets.only(bottom: NeoSpace.sm),
                        child: Text(
                          'Ce type de Vibe ne se sauvegarde pas.',
                          style: TextStyle(color: context.muted, fontSize: 12),
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: !widget.typeAccepteSauvegarde
                            ? null
                            : () {
                                final v = !_tousSauvegardables;
                                setState(() {
                                  _conversations = [
                                    for (final c in _conversations)
                                      c.copyWith(saveable: v),
                                  ];
                                });
                                _push();
                              },
                        icon: Icon(
                          _tousSauvegardables
                              ? Icons.remove_done
                              : Icons.done_all,
                          size: 18,
                        ),
                        label: Text(
                          _tousSauvegardables
                              ? 'Tout désélectionner'
                              : 'Tout sélectionner',
                        ),
                      ),
                    ),
                    for (final c in _conversations)
                      SwitchListTile.adaptive(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(c.label),
                        subtitle: c.aussiDansLaBibliotheque && !c.dansLeChat
                            ? const Text('Drop seulement')
                            : null,
                        value: c.saveable,
                        onChanged: widget.typeAccepteSauvegarde
                            ? (v) => _setSaveable(c, v)
                            : null,
                      ),
                  ],
                ),
              ),
            _DefaultsButton(
              aide:
                  'Garder « Sauvegardable » comme défaut pour chaque ami '
                  'affiché, et ces limites pour mes prochains envois',
              onPressed: _enregistrerDefauts,
            ),
          ],
        ),
      ),
    );
  }
}
