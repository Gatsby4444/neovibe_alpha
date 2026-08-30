import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/card.dart';
import '../../../core/models/message.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../../core/widgets/avatar.dart';
import '../../connections/friendship.dart';
import '../../connections/friendships_repository.dart';
import '../../connections/tier_avatar.dart';
import '../../conversations/conversations_repository.dart';
import '../../proximity/net/crossed_repository.dart';
import 'send_common.dart';
import 'share_plan.dart';
import 'share_publisher.dart';
import 'vibe_draft.dart';

/// **« Partager ma Vibe » — un seul écran, plusieurs destinations.**
///
/// ## 🔴 Ce que ça remplace, et pourquoi c'était un problème
///
/// Demande de Jay, 2026-08-30 : *« sur Snap on peut partager à la fois en story
/// et à des amis […] il faudrait rendre le partage aussi simple et aussi
/// polyvalent »*.
///
/// Avant : **deux écrans successifs**. On choisissait d'abord UN format, puis
/// on le paramétrait. Envoyer la même prise en story ET à deux amis demandait
/// de refaire tout le parcours — capture comprise, puisque chaque envoi
/// ramenait à l'accueil.
///
/// ⚠️ **Ça ne casse PAS la séparation des contextes du 2026-08-11.** Cette
/// règle parle des OBJETS, pas des écrans : chaque destination cochée crée son
/// propre objet, avec ses octets et sa clé. Voir [SharePlan].
///
/// ## L'ordre de l'écran — maquette A, tranchée par Jay
///
/// *« maquette A car les options de publication prennent moins de place que le
/// partage par groupe ou par personne »* (2026-08-30). Publier d'abord, parce
/// que c'est court ; les gens ensuite, parce que c'est long.
///
/// ## ⚠️ Les réglages n'apparaissent QUE sur les lignes cochées
///
/// C'est le seul écart assumé avec la maquette, et Jay l'a ouvert lui-même
/// (*« mes maquettes ne sont pas parfaites ergonomiquement »*). Les afficher
/// partout remplirait l'écran d'interrupteurs éteints qui ne commandent rien —
/// et la maquette montre déjà six lignes de réglages pour zéro destination
/// choisie. Une option qui n'a pas encore de sens n'est pas une option, c'est
/// du bruit.
class ShareScreen extends ConsumerStatefulWidget {
  const ShareScreen({super.key, required this.draft});

  final VibeDraft draft;

  @override
  ConsumerState<ShareScreen> createState() => _ShareScreenState();
}

/// Les trois filtres du haut.
enum _Filtre {
  tout('Tout'),
  gens('Ami(e)s'),
  groupes('Groupes');

  const _Filtre(this.label);
  final String label;
}

class _ShareScreenState extends ConsumerState<ShareScreen> {
  var _plan = const SharePlan();
  var _filtre = _Filtre.tout;
  var _recherche = '';
  var _envoiEnCours = false;

  final _rechercheCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // ⚠️ **L'explicateur des Vibes suit le PREMIER écran d'envoi**, quel qu'il
    // soit. Il vivait sur `SendFormatScreen`, qui disparaît : le laisser
    // là-bas l'aurait fait disparaître avec, sans que rien ne le signale.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => maybeShowVibesExplainer(context, ref),
    );
  }

  @override
  void dispose() {
    _rechercheCtrl.dispose();
    super.dispose();
  }

  bool _correspond(String texte) =>
      _recherche.isEmpty ||
      texte.toLowerCase().contains(_recherche.toLowerCase());

  // ------------------------------------------------------------------
  // L'envoi
  // ------------------------------------------------------------------

  Future<void> _envoyer() async {
    final soucis = _plan.problemes(
      widget.draft.type,
      importe: widget.draft.imported,
    );
    if (soucis.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(soucis.first)));
      return;
    }

    setState(() => _envoiEnCours = true);
    final resultat = await ref
        .read(sharePublisherProvider)
        .run(widget.draft, _plan);
    if (!mounted) return;

    // ⚠️ **On ne dit JAMAIS « envoyé » quand une destination a échoué.** Un
    // envoi vers quatre destinations peut réussir trois fois : répondre « ça a
    // marché » perdrait la quatrième en silence, et répondre « ça a échoué »
    // ferait renvoyer les trois qui sont déjà parties.
    final messenger = ScaffoldMessenger.of(context);
    if (resultat.toutEstParti) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      messenger.showSnackBar(
        SnackBar(content: Text('Envoyé à ${resultat.reussites.length} ✓')),
      );
      return;
    }

    setState(() => _envoiEnCours = false);
    final echecs = resultat.echecs.map((e) => e.label).join(', ');
    if (resultat.rienNEstParti) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(friendlySendError(resultat.echecs.first.erreur!)),
        ),
      );
    } else {
      // Ce qui est parti est parti : on ne le renvoie pas, on nomme ce qui
      // manque pour que l'utilisateur puisse ne recocher que ça.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${resultat.reussites.length} envoyé(s). Échec : $echecs',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  // ------------------------------------------------------------------
  // Le rendu
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider) ?? '';
    final p = context.palette;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Partager '),
            VibeTypeChip(type: widget.draft.type),
          ],
        ),
      ),
      body: Column(
        children: [
          // ⚠️ **Le bandeau 1/1 en haut, pas en bas.** Ses règles décident de
          // ce qu'on a le droit de cocher : le lire après avoir choisi, c'est
          // le lire trop tard.
          if (widget.draft.type == CardType.oneOfOne) const OneOfOneBanner(),
          _BarreDeRecherche(
            controller: _rechercheCtrl,
            onChanged: (v) => setState(() => _recherche = v),
          ),
          _Filtres(
            actif: _filtre,
            onChange: (f) => setState(() => _filtre = f),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: NeoSpace.xxl),
              children: [
                // ⚠️ **Publier en premier, et compact** — décision de Jay.
                if (_filtre == _Filtre.tout) ...[
                  _TitreSection('Publier sur…'),
                  _LignePublication(
                    titre: 'Ma story',
                    sousTitre: _sousTitreStory(),
                    icone: Icons.auto_awesome,
                    coche: _plan.story != null,
                    onCoche: (v) => setState(
                      () => _plan = v
                          ? _plan.copyWith(story: const StoryShare())
                          : _plan.copyWith(effacerStory: true),
                    ),
                    reglages: _plan.story == null
                        ? null
                        : _ReglagesStory(
                            valeur: _plan.story!,
                            onChange: (s) => setState(
                              () => _plan = _plan.copyWith(story: s),
                            ),
                            typeAccepteSauvegarde:
                                widget.draft.type.canBeSaveable,
                          ),
                  ),
                  _LignePublication(
                    titre: 'Ma bibliothèque',
                    sousTitre:
                        'Ta grille de profil. Permanente, sans limite '
                        'de vues.',
                    icone: Icons.grid_view,
                    coche: _plan.library != null,
                    onCoche: (v) => setState(
                      () => _plan = v
                          ? _plan.copyWith(library: const LibraryShare())
                          : _plan.copyWith(effacerLibrary: true),
                    ),
                    reglages: _plan.library == null
                        ? null
                        : _ReglagesBibliotheque(
                            valeur: _plan.library!,
                            onChange: (l) => setState(
                              () => _plan = _plan.copyWith(library: l),
                            ),
                            typeAccepteSauvegarde:
                                widget.draft.type.canBeSaveable,
                          ),
                  ),
                ],

                _Conversations(
                  me: me,
                  filtre: _filtre,
                  correspond: _correspond,
                  plan: _plan,
                  draft: widget.draft,
                  onChange: (c) => setState(() => _plan = c),
                ),

                if (_filtre != _Filtre.groupes)
                  _Croises(
                    correspond: _correspond,
                    plan: _plan,
                    onChange: (c) => setState(() => _plan = c),
                  ),

                // ⚠️ **Les règles de visionnage n'apparaissent QUE si quelqu'un
                // est coché.** Elles ne s'appliquent qu'aux personnes : une
                // story ou une publication n'a ni compteur d'ouvertures ni
                // durée par face. Les montrer toujours ferait croire qu'elles
                // valent pour tout l'envoi.
                if (_plan.destinataires > 0) ...[
                  const _TitreSection('Pour les personnes'),
                  ViewingRulesSummary(
                    maxViews: _plan.regles.maxViews,
                    viewDuration: _plan.regles.viewDurationSeconds,
                    onTap: _ouvrirReglesDeVisionnage,
                  ),
                ],

                const SizedBox(height: NeoSpace.md),
                // ⚠️ **« Enregistrer pour moi » n'est PAS une destination.**
                // C'est le cinquième contexte de diffusion (Jay, 2026-08-14) :
                // des octets en clair sur l'appareil, aucune clé, aucune ligne
                // serveur. Il agit MAINTENANT, il ne se coche pas pour plus
                // tard — d'où sa place à part, hors du plan.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
                  child: SaveForMeButton(draft: widget.draft),
                ),
              ],
            ),
          ),

          // La barre d'envoi, collée en bas : elle ne défile pas avec la liste.
          Container(
            padding: const EdgeInsets.fromLTRB(
              NeoSpace.lg,
              NeoSpace.md,
              NeoSpace.lg,
              NeoSpace.lg,
            ),
            decoration: BoxDecoration(
              color: p.surface,
              border: Border(top: BorderSide(color: p.line)),
            ),
            child: SafeArea(
              top: false,
              child: _BoutonEnvoyer(
                plan: _plan,
                enCours: _envoiEnCours,
                onEnvoyer: _envoyer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _ouvrirReglesDeVisionnage() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ViewingRulesSheet(
        draft: widget.draft,
        maxViews: _plan.regles.maxViews,
        viewDuration: _plan.regles.viewDurationSeconds,
        // `scrubbable` appartient à la Card et se règle dans la même feuille ;
        // il n'a pas d'équivalent dans le plan, on le laisse à son défaut.
        scrubbable: false,
        onChanged: (maxViews, duree, _) => setState(
          () => _plan = _plan.copyWith(
            regles: ViewingRules(
              maxViews: maxViews,
              viewDurationSeconds: duree,
            ),
          ),
        ),
      ),
    );
  }

  String _sousTitreStory() {
    final tier = _plan.story?.tier ?? FriendshipTier.friend;
    return switch (tier) {
      FriendshipTier.friend => 'Tous tes ami(e)s. 24 h.',
      FriendshipTier.close => 'Tes proches seulement. 24 h.',
      FriendshipTier.inner => 'Tes inséparables seulement. 24 h.',
    };
  }
}

// ---------------------------------------------------------------------------
// Le haut de l'écran
// ---------------------------------------------------------------------------

class _BarreDeRecherche extends StatelessWidget {
  const _BarreDeRecherche({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.lg,
        NeoSpace.sm,
        NeoSpace.lg,
        NeoSpace.sm,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: p.field,
          hintText: 'Chercher un(e) ami(e) ou un groupe…',
          prefixIcon: const Icon(Icons.search, size: 20),
          // ⚠️ **Un `OutlineInputBorder()` nu a un côté noir** — piège relevé
          // le 2026-08-14. La bordure se dit explicitement, ou pas du tout.
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(NeoRadius.pill),
            borderSide: BorderSide(color: p.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(NeoRadius.pill),
            borderSide: BorderSide(color: p.line),
          ),
        ),
      ),
    );
  }
}

class _Filtres extends StatelessWidget {
  const _Filtres({required this.actif, required this.onChange});

  final _Filtre actif;
  final ValueChanged<_Filtre> onChange;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
    child: Row(
      children: [
        for (final f in _Filtre.values)
          Padding(
            padding: const EdgeInsets.only(right: NeoSpace.sm),
            child: ChoiceChip(
              label: Text(f.label),
              selected: f == actif,
              onSelected: (_) => onChange(f),
            ),
          ),
      ],
    ),
  );
}

class _TitreSection extends StatelessWidget {
  const _TitreSection(this.texte, {this.aide});

  final String texte;
  final String? aide;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NeoSpace.lg,
      NeoSpace.xl,
      NeoSpace.lg,
      NeoSpace.sm,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(texte, style: context.sectionTitle),
        if (aide != null)
          Padding(
            padding: const EdgeInsets.only(top: NeoSpace.xs),
            child: Text(aide!, style: TextStyle(color: context.muted)),
          ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Les lignes
// ---------------------------------------------------------------------------

/// Le cadre commun de TOUTES les lignes de cet écran.
///
/// ⚠️ **Un seul cadre, comme pour les tuiles du Ping** (2026-08-30). Des lignes
/// écrites séparément finissent par avoir trois hauteurs et deux alignements —
/// l'écart ne se voit pas ligne par ligne, il se voit une fois la page pleine.
class _LigneCochable extends StatelessWidget {
  const _LigneCochable({
    required this.avant,
    required this.titre,
    required this.sousTitre,
    required this.coche,
    required this.onCoche,
    this.suffixe,
    this.reglages,
  });

  final Widget avant;
  final String titre;
  final String sousTitre;
  final bool coche;
  final ValueChanged<bool> onCoche;

  /// Ce qui se pose à droite du nom : la série, un état.
  final Widget? suffixe;

  /// Visible **uniquement** quand la ligne est cochée.
  final Widget? reglages;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.lg,
        0,
        NeoSpace.lg,
        NeoSpace.sm,
      ),
      child: Material(
        color: coche ? p.field : Colors.transparent,
        borderRadius: BorderRadius.circular(NeoRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(NeoRadius.md),
          onTap: () => onCoche(!coche),
          child: Container(
            padding: const EdgeInsets.all(NeoSpace.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(NeoRadius.md),
              border: Border.all(
                color: coche ? Theme.of(context).colorScheme.primary : p.line,
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    avant,
                    const SizedBox(width: NeoSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            titre,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.pseudo,
                          ),
                          Text(
                            sousTitre,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (suffixe != null) ...[
                      const SizedBox(width: NeoSpace.sm),
                      suffixe!,
                    ],
                    const SizedBox(width: NeoSpace.sm),
                    // ⚠️ **La zone tactile de la coche couvre TOUTE la ligne**
                    // (l'`InkWell` au-dessus). La coche elle-même n'est qu'un
                    // témoin : une cible de 24 px dans une ligne de 64 rate
                    // une fois sur trois.
                    Icon(
                      coche ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: coche
                          ? Theme.of(context).colorScheme.primary
                          : context.faint,
                    ),
                  ],
                ),
                if (coche && reglages != null) ...[
                  const SizedBox(height: NeoSpace.sm),
                  Divider(height: 1, color: p.line),
                  const SizedBox(height: NeoSpace.sm),
                  reglages!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LignePublication extends StatelessWidget {
  const _LignePublication({
    required this.titre,
    required this.sousTitre,
    required this.icone,
    required this.coche,
    required this.onCoche,
    this.reglages,
  });

  final String titre;
  final String sousTitre;
  final IconData icone;
  final bool coche;
  final ValueChanged<bool> onCoche;
  final Widget? reglages;

  @override
  Widget build(BuildContext context) => _LigneCochable(
    avant: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: context.palette.field,
        borderRadius: BorderRadius.circular(NeoRadius.sm),
      ),
      child: Icon(icone, size: 20),
    ),
    titre: titre,
    sousTitre: sousTitre,
    coche: coche,
    onCoche: onCoche,
    reglages: reglages,
  );
}

// ---------------------------------------------------------------------------
// Les réglages, visibles seulement quand la ligne est cochée
// ---------------------------------------------------------------------------

/// Une puce de réglage : petite, cliquable, allumée ou éteinte.
///
/// ⚠️ **Pas un `Switch`.** Six interrupteurs Material dans une ligne la font
/// doubler de hauteur ; la demande de Jay était *« des boutons et containers à
/// taille réduite pour bien proposer toutes les options »*.
class _Puce extends StatelessWidget {
  const _Puce({
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

class _ReglagesStory extends StatelessWidget {
  const _ReglagesStory({
    required this.valeur,
    required this.onChange,
    required this.typeAccepteSauvegarde,
  });

  final StoryShare valeur;
  final ValueChanged<StoryShare> onChange;
  final bool typeAccepteSauvegarde;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // 🔴 **LE PALIER — ce que Snapchat ne sait pas faire.** La colonne
      // `stories.min_tier` existait depuis le 2026-08-30 et personne ne
      // l'écrivait : le filtre s'appliquait à chaque lecture sans jamais rien
      // filtrer. C'est ici qu'il devient utilisable.
      Text('Visible par', style: TextStyle(color: context.muted, fontSize: 11)),
      const SizedBox(height: NeoSpace.xs),
      Wrap(
        spacing: NeoSpace.sm,
        runSpacing: NeoSpace.xs,
        children: [
          for (final t in FriendshipTier.values)
            _Puce(
              label: switch (t) {
                FriendshipTier.friend => 'Tous mes amis',
                FriendshipTier.close => 'Mes proches',
                FriendshipTier.inner => 'Mes inséparables',
              },
              actif: valeur.tier == t,
              onTap: () => onChange(valeur.copyWith(tier: t)),
            ),
        ],
      ),
      const SizedBox(height: NeoSpace.sm),
      Wrap(
        spacing: NeoSpace.sm,
        runSpacing: NeoSpace.xs,
        children: [
          _Puce(
            label: 'Partageable',
            actif: valeur.shareable,
            onTap: () =>
                onChange(valeur.copyWith(shareable: !valeur.shareable)),
          ),
          _Puce(
            label: 'Sauvegardable',
            actif: valeur.saveable,
            desactivee: !typeAccepteSauvegarde,
            onTap: () => onChange(valeur.copyWith(saveable: !valeur.saveable)),
          ),
        ],
      ),
    ],
  );
}

class _ReglagesBibliotheque extends StatelessWidget {
  const _ReglagesBibliotheque({
    required this.valeur,
    required this.onChange,
    required this.typeAccepteSauvegarde,
  });

  final LibraryShare valeur;
  final ValueChanged<LibraryShare> onChange;
  final bool typeAccepteSauvegarde;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: NeoSpace.sm,
    runSpacing: NeoSpace.xs,
    children: [
      _Puce(
        label: 'Visible par les gens que tu croises',
        actif: valeur.isPublic,
        onTap: () => onChange(valeur.copyWith(isPublic: !valeur.isPublic)),
      ),
      _Puce(
        label: 'Partageable',
        actif: valeur.shareable,
        onTap: () => onChange(valeur.copyWith(shareable: !valeur.shareable)),
      ),
      _Puce(
        label: 'Sauvegardable',
        actif: valeur.saveable,
        desactivee: !typeAccepteSauvegarde,
        onTap: () => onChange(valeur.copyWith(saveable: !valeur.saveable)),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Les conversations
// ---------------------------------------------------------------------------

class _Conversations extends ConsumerWidget {
  const _Conversations({
    required this.me,
    required this.filtre,
    required this.correspond,
    required this.plan,
    required this.draft,
    required this.onChange,
  });

  final String me;
  final _Filtre filtre;
  final bool Function(String) correspond;
  final SharePlan plan;
  final VibeDraft draft;
  final ValueChanged<SharePlan> onChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationsProvider);

    return conversations.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(NeoSpace.xl),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(NeoSpace.lg),
        child: Text(
          'Impossible de charger tes conversations.',
          style: TextStyle(color: context.muted),
        ),
      ),
      data: (toutes) {
        // ⚠️ **Les conversations de PROXIMITÉ sont écartées.** Elles se ferment
        // dès qu'on ne s'entend plus (fenêtre de 3 min) : les proposer ici
        // afficherait un bouton dont le seul effet possible est un refus du
        // serveur.
        final visibles = [
          for (final c in toutes)
            if (c.type != ConversationType.proximity &&
                correspond(c.displayName(me)) &&
                switch (filtre) {
                  _Filtre.tout => true,
                  _Filtre.gens => c.type == ConversationType.direct,
                  _Filtre.groupes => c.type == ConversationType.group,
                })
              c,
        ];
        if (visibles.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _TitreSection('Conversations & groupes'),
            for (final c in visibles)
              _LigneConversation(
                conversation: c,
                me: me,
                plan: plan,
                draft: draft,
                onChange: onChange,
              ),
          ],
        );
      },
    );
  }
}

class _LigneConversation extends ConsumerWidget {
  const _LigneConversation({
    required this.conversation,
    required this.me,
    required this.plan,
    required this.draft,
    required this.onChange,
  });

  final Conversation conversation;
  final String me;
  final SharePlan plan;
  final VibeDraft draft;
  final ValueChanged<SharePlan> onChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autres = [
      for (final m in conversation.members)
        if (m.id != me) m.id,
    ];
    final choisie = plan.conversations
        .where((c) => c.conversationId == conversation.id)
        .firstOrNull;
    final estGroupe = conversation.type == ConversationType.group;
    final autre = conversation.otherMember(me);

    // 🔥 **LA SÉRIE — c'est le FOMO, et c'est ici qu'il a le plus de sens.**
    // Juste avant de choisir à qui envoyer, on voit ce qu'on risque de perdre.
    final amitie = autre == null
        ? null
        : ref.watch(friendshipsProvider).value?[autre.id];

    return _LigneCochable(
      avant: estGroupe
          ? _AvatarGroupe(conversation: conversation, me: me)
          : TierAvatar(
              peerId: autre?.id ?? '',
              storedAvatar: autre?.avatarUrl,
              initiale: (autre?.chatName ?? '?').characters.first.toUpperCase(),
              size: 40,
            ),
      titre: conversation.displayName(me),
      sousTitre: estGroupe
          ? '${autres.length + 1} membres'
          : (amitie?.tier.label ?? 'Ami'),
      suffixe: amitie != null && amitie.serie > 0
          ? _Serie(jours: amitie.serie)
          : null,
      coche: choisie != null,
      onCoche: (v) {
        final reste = [
          for (final c in plan.conversations)
            if (c.conversationId != conversation.id) c,
        ];
        onChange(
          plan.copyWith(
            conversations: v
                ? [
                    ...reste,
                    ConversationShare(
                      conversationId: conversation.id,
                      memberIds: autres,
                      label: conversation.displayName(me),
                    ),
                  ]
                : reste,
          ),
        );
      },
      reglages: choisie == null
          ? null
          : Wrap(
              spacing: NeoSpace.sm,
              runSpacing: NeoSpace.xs,
              children: [
                _Puce(
                  label: 'Sauvegardable',
                  actif: choisie.saveable,
                  desactivee: !draft.type.canBeSaveable,
                  onTap: () =>
                      _remplace(choisie.copyWith(saveable: !choisie.saveable)),
                ),
                // ⚠️ **La bibliothèque de conversation refuse deux choses**
                // (Jay, 2026-08-10) : les imports galerie et le BeReal. On
                // grise ici plutôt que d'ouvrir la porte et d'échouer à
                // l'envoi.
                if (estGroupe)
                  _Puce(
                    label: 'Aussi dans la bibliothèque du groupe',
                    actif: choisie.aussiDansLaBibliotheque,
                    desactivee: draft.imported || draft.type == CardType.bereal,
                    onTap: () => _remplace(
                      choisie.copyWith(
                        aussiDansLaBibliotheque:
                            !choisie.aussiDansLaBibliotheque,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  void _remplace(ConversationShare neuve) => onChange(
    plan.copyWith(
      conversations: [
        for (final c in plan.conversations)
          if (c.conversationId == conversation.id) neuve else c,
      ],
    ),
  );
}

class _AvatarGroupe extends StatelessWidget {
  const _AvatarGroupe({required this.conversation, required this.me});

  final Conversation conversation;
  final String me;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 40,
    child: Container(
      decoration: BoxDecoration(
        color: context.palette.field,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.group, size: 20),
    ),
  );
}

/// La série de croisements, en jours.
class _Serie extends StatelessWidget {
  const _Serie({required this.jours});

  final int jours;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '$jours',
        // Chiffres tabulaires : sans ça, passer de 9 à 10 fait bouger la ligne.
        style: context.sectionMeta.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(width: 2),
      const Text('🔥', style: TextStyle(fontSize: 13)),
    ],
  );
}

// ---------------------------------------------------------------------------
// Les croisés
// ---------------------------------------------------------------------------

class _Croises extends ConsumerWidget {
  const _Croises({
    required this.correspond,
    required this.plan,
    required this.onChange,
  });

  final bool Function(String) correspond;
  final SharePlan plan;
  final ValueChanged<SharePlan> onChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final croises = ref.watch(crossedRecentlyProvider);

    return croises.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (gens) {
        final visibles = [
          for (final g in gens)
            if (correspond(g.displayName)) g,
        ];
        if (visibles.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _TitreSection(
              'Croisé(e)s aujourd\'hui',
              aide:
                  'Vous vous êtes croisés pour de vrai. Ta Vibe part avec '
                  'une demande de connexion.',
            ),
            for (final g in visibles)
              _LigneCochable(
                avant: Avatar(
                  stored: g.avatarUrl,
                  radius: 20,
                  fallback: Text(g.displayName.characters.first.toUpperCase()),
                ),
                titre: g.displayName,
                sousTitre: g.alreadyRequested
                    ? 'Demande déjà envoyée — ta Vibe s\'y ajoutera'
                    : (g.tagName == null ? 'Croisé(e)' : '@${g.tagName}'),
                coche: plan.crossed.any((c) => c.userId == g.userId),
                onCoche: (v) {
                  final reste = [
                    for (final c in plan.crossed)
                      if (c.userId != g.userId) c,
                  ];
                  onChange(
                    plan.copyWith(
                      crossed: v
                          ? [
                              ...reste,
                              CrossedShare(
                                userId: g.userId,
                                label: g.displayName,
                              ),
                            ]
                          : reste,
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// La barre du bas
// ---------------------------------------------------------------------------

class _BoutonEnvoyer extends StatelessWidget {
  const _BoutonEnvoyer({
    required this.plan,
    required this.enCours,
    required this.onEnvoyer,
  });

  final SharePlan plan;
  final bool enCours;
  final VoidCallback onEnvoyer;

  @override
  Widget build(BuildContext context) {
    final destinations =
        (plan.story != null ? 1 : 0) +
        (plan.library != null ? 1 : 0) +
        plan.conversations.length +
        plan.crossed.length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ⚠️ **Le coût est DIT, pas caché.** Chaque contexte dépose ses propres
        // octets : cocher quatre destinations, c'est envoyer la vidéo quatre
        // fois. Le taire ferait passer une lenteur pour une panne — et
        // l'utilisateur ne pourrait pas choisir.
        if (plan.televersements > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: NeoSpace.sm),
            child: Text(
              '${plan.televersements} envois — ta Vibe part une fois par '
              'destination',
              style: TextStyle(color: context.faint, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: (destinations == 0 || enCours) ? null : onEnvoyer,
            child: enCours
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    destinations == 0
                        ? 'Choisis une destination'
                        : 'Partager ma Vibe · $destinations',
                  ),
          ),
        ),
      ],
    );
  }
}
