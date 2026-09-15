import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/card.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/rive_send_button.dart';
import '../../connections/friendship.dart';
import '../../connections/tier_avatar.dart';
import '../../proximity/net/crossed_repository.dart';
import 'recipients.dart';
import 'recipients_provider.dart';
import 'send_common.dart';
import 'share_context.dart';
import 'share_defaults.dart';
import 'share_plan.dart';
import 'share_queue.dart';
import 'share_settings_sheets.dart';

/// **« À qui ? » — LE seul écran de destination de l'app** (plan §2,
/// Jay 2026-09-13/14).
///
/// ## Ce qu'il remplace
///
/// Cinq listes qui choisissaient « à qui » chacune à sa façon : l'écran de
/// partage après capture, l'écran réduit depuis un chat, la bibliothèque de
/// groupe, et deux petites listes recopiées dans les visionneuses. Ce qui
/// différait entre elles tient dans [ShareContext] ; ce qui ne différait pas —
/// la liste, l'ordre, la recherche — vit ici, une fois.
///
/// ## Ce qu'il montre, de haut en bas (Jay, 2026-09-14)
///
/// 1. la Vibe en petit (le récap intégré — [header]) ;
/// 2. **le nom de l'événement** où je suis, s'il y en a un ;
/// 3. **« Publier »** ⚙︎ — deux petits boutons alignés : Story · Bibliothèque ;
/// 4. **« Groupes et amis »** ⚙︎ — les **10 plus proches** en tableau 2
///    colonnes, puis **les groupes** par ma participation, puis **tout le
///    monde** par interaction récente, puis les croisés ;
/// 5. la barre « Envoyer · N ».
///
/// « Enregistrer pour moi » est un **signet dans la barre de titre** (Jay,
/// 2026-09-14 : en bas de liste, il était « difficilement accessible »).
///
/// **Aucun réglage sur les lignes.** Les réglages vivent derrière les deux
/// roues ⚙︎ (`share_settings_sheets.dart`) ; les lignes ne portent que la
/// coche — et, pour un groupe ou un DM, **les deux cibles** 💬 / 📚 (§2.7).
///
/// ## Ce qu'il ne fait pas
///
/// Il ne parle ni au réseau ni au disque : la liste vient de
/// `recipientsProvider`, les défauts de `shareDefaultsProvider` et
/// `friendShareDefaultsProvider`, et l'envoi part dans `ShareQueue` — puis
/// l'écran **rend la main tout de suite** ([onSent]).
class RecipientPickerScreen extends ConsumerStatefulWidget {
  const RecipientPickerScreen({
    super.key,
    required this.shareContext,
    this.header,
    this.onSent,
  });

  final ShareContext shareContext;

  /// La Vibe en petit, avec ses gestes (modifier / original / refaire).
  /// Construit par l'écran de capture, qui seul sait refaire une face.
  final Widget? header;

  /// Appelé **dès que l'envoi est déposé** dans la file — c'est le « retour
  /// caméra immédiat ». En mode repartage, l'écran rend son plan par
  /// `Navigator.pop` à la place.
  final VoidCallback? onSent;

  @override
  ConsumerState<RecipientPickerScreen> createState() =>
      _RecipientPickerScreenState();
}

class _RecipientPickerScreenState extends ConsumerState<RecipientPickerScreen> {
  var _plan = const SharePlan();
  var _recherche = '';

  /// Ce que pilote la grille des plus proches : le 💬 ou le Drop de chaque
  /// ami. **Même grille, deux cibles** (Jay, 2026-09-14) : la case cochée
  /// en mode Chat est le bouton 💬 de la ligne dans « Tout le monde », la
  /// case cochée en mode Drop est son bouton Drop. Rien de plus sur les cases.
  var _modeProches = _CibleProche.chat;
  var _preselectionFaite = false;
  final _rechercheCtrl = TextEditingController();

  ShareContext get _ctx => widget.shareContext;
  VibeShareContext? get _vibe =>
      _ctx is VibeShareContext ? _ctx as VibeShareContext : null;

  @override
  void initState() {
    super.initState();
    // L'explicateur des Vibes suit le premier écran d'envoi, quel qu'il soit.
    if (_vibe != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => maybeShowVibesExplainer(context, ref),
      );
    }
    // Publication seulement : la bibliothèque est cochée d'office, avec les
    // réglages par défaut — c'est la destination, pas une proposition.
    if (_ctx.libraryOnly) {
      _plan = _plan.copyWith(library: ref.read(shareDefaultsProvider).library);
    }
  }

  @override
  void dispose() {
    _rechercheCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Le plan
  // ------------------------------------------------------------------

  ConversationShare? _shareOf(String key) =>
      _plan.conversations.where((c) => c.key == key).firstOrNull;

  void _setShare(String key, ConversationShare? neuve) {
    final reste = [
      for (final c in _plan.conversations)
        if (c.key != key) c,
    ];
    setState(() {
      _plan = _plan.copyWith(
        conversations: neuve == null || neuve.vide ? reste : [...reste, neuve],
      );
    });
  }

  /// Le « Sauvegardable » d'une ligne qu'on vient de cocher : son défaut à
  /// lui, sinon mon défaut général (`share_defaults.dart`).
  bool _saveableParDefaut(String? friendId) {
    final general = ref.read(shareDefaultsProvider).peopleSaveable;
    if (friendId == null) return general;
    return resolveSaveable(
      friendId: friendId,
      perFriend: ref.read(friendShareDefaultsProvider).value ?? const {},
      general: general,
    );
  }

  ConversationShare _nouvelle(
    Recipient r, {
    required bool chat,
    required bool lib,
  }) => switch (r) {
    FriendRecipient() => ConversationShare(
      conversationId: r.conversationId,
      peerId: r.userId,
      memberIds: [r.userId],
      label: r.profile.chatName,
      saveable: _saveableParDefaut(r.userId),
      dansLeChat: chat,
      aussiDansLaBibliotheque: lib,
    ),
    GroupRecipient() => ConversationShare(
      conversationId: r.conversationId,
      memberIds: r.memberIds,
      label: r.label,
      saveable: _saveableParDefaut(null),
      dansLeChat: chat,
      aussiDansLaBibliotheque: lib,
    ),
  };

  String _keyOf(Recipient r) => switch (r) {
    FriendRecipient() => r.conversationId ?? 'peer:${r.userId}',
    GroupRecipient() => r.conversationId,
  };

  /// Une cible de la ligne : 💬 ou 📚.
  void _toggleCible(Recipient r, {required bool chat}) {
    final key = _keyOf(r);
    final courant = _shareOf(key);
    if (courant == null) {
      _setShare(key, _nouvelle(r, chat: chat, lib: !chat));
      return;
    }
    _setShare(
      key,
      chat
          ? courant.copyWith(dansLeChat: !courant.dansLeChat)
          : courant.copyWith(
              aussiDansLaBibliotheque: !courant.aussiDansLaBibliotheque,
            ),
    );
  }

  /// La coche simple (repartage, sans Drop) : 💬 seulement. Avec un Drop
  /// possible, la grille passe par [_toggleCible] selon son mode.
  void _toggleSimple(Recipient r) {
    final key = _keyOf(r);
    _setShare(
      key,
      _shareOf(key) == null ? _nouvelle(r, chat: true, lib: false) : null,
    );
  }

  void _toggleCroise(CrossedPerson g) {
    final reste = [
      for (final c in _plan.crossed)
        if (c.userId != g.userId) c,
    ];
    final deja = reste.length != _plan.crossed.length;
    setState(() {
      _plan = _plan.copyWith(
        crossed: deja
            ? reste
            : [...reste, CrossedShare(userId: g.userId, label: g.displayName)],
      );
    });
  }

  // Cocher une publication prend le réglage posé dans la feuille s'il y en a
  // un, sinon mon défaut.
  void _toggleStory() => setState(() {
    _plan = _plan.story == null
        ? _plan.copyWith(
            story: _storyReglee ?? ref.read(shareDefaultsProvider).story,
          )
        : _plan.copyWith(effacerStory: true);
  });

  void _toggleLibrary() => setState(() {
    _plan = _plan.library == null
        ? _plan.copyWith(
            library: _libraryReglee ?? ref.read(shareDefaultsProvider).library,
          )
        : _plan.copyWith(effacerLibrary: true);
  });

  /// Le chat d'où la capture a été ouverte : coché à l'arrivée, modifiable.
  void _preselectionne(RecipientCatalog catalog) {
    final id = _ctx.presetConversationId;
    if (_preselectionFaite || id == null) return;
    _preselectionFaite = true;
    Recipient? cible;
    for (final r in catalog.everyone) {
      if (_keyOf(r) == id) cible = r;
    }
    if (cible == null) return;
    final r = cible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _setShare(id, _nouvelle(r, chat: true, lib: false));
    });
  }

  /// La Vibe est-elle, EN L'ÉTAT, une One of One ? Condition arrêtée par Jay
  /// le 2026-08-10 : un seul destinataire et aucune publication. Le BeReal en
  /// est exclu (format à identité propre) ; un croisé aussi (pas encore un
  /// ami).
  CardType get _typeEffectif {
    final draft = _vibe?.draft;
    if (draft == null) return CardType.standard;
    final unSeul =
        _plan.story == null &&
        _plan.library == null &&
        _plan.crossed.isEmpty &&
        !_plan.conversations.any((c) => c.aussiDansLaBibliotheque) &&
        _plan.destinataires == 1;
    return unSeul && draft.type != CardType.bereal
        ? CardType.oneOfOne
        : draft.type;
  }

  // ------------------------------------------------------------------
  // Les roues ⚙︎
  // ------------------------------------------------------------------

  Future<void> _ouvrirReglagesPublication() async {
    final draft = _vibe?.draft;
    if (draft == null) return;
    final defauts = ref.read(shareDefaultsProvider);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PublicationSettingsSheet(
        story: _plan.story ?? _storyReglee ?? defauts.story,
        library: _plan.library ?? _libraryReglee ?? defauts.library,
        typeAccepteSauvegarde: draft.type.canBeSaveable,
        libraryOnly: _ctx.libraryOnly,
        // La feuille règle sans cocher : une ligne décochée garde son
        // réglage pour le jour où on la coche.
        onChanged: (s) => setState(() {
          _plan = _plan.copyWith(
            story: _plan.story == null ? null : s.story,
            library: _plan.library == null ? null : s.library,
          );
          _storyReglee = s.story;
          _libraryReglee = s.library;
        }),
      ),
    );
  }

  /// Réglages posés dans la feuille avant que la ligne soit cochée.
  StoryShare? _storyReglee;
  LibraryShare? _libraryReglee;

  Future<void> _ouvrirReglagesDestinataires() async {
    final draft = _vibe?.draft;
    if (draft == null) return;
    final selection = [
      for (final c in _plan.conversations)
        SelectedRecipient(
          conversationShare: c,
          friendId: c.peerId,
          isGroup: c.peerId == null,
        ),
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => RecipientSettingsSheet(
        draft: draft,
        regles: _plan.regles,
        selection: selection,
        typeAccepteSauvegarde: draft.type.canBeSaveable,
        onChanged: (s) => setState(() {
          _plan = _plan.copyWith(
            regles: s.regles,
            conversations: s.conversations,
          );
        }),
      ),
    );
  }

  // ------------------------------------------------------------------
  // L'envoi
  // ------------------------------------------------------------------

  void _envoyer() {
    final ctx = _ctx;
    switch (ctx) {
      case RepostShareContext():
        if (_plan.conversations.isEmpty) {
          _dire('Choisis au moins une conversation.');
          return;
        }
        Navigator.of(context).pop(_plan);
      case VibeShareContext(:final draft):
        final type = _typeEffectif;
        final soucis = _plan.problemes(type, importe: draft.imported);
        if (soucis.isNotEmpty) {
          _dire(soucis.first);
          return;
        }
        // Le geste part en arrière-plan ; on est déjà revenu à la caméra.
        ref
            .read(shareQueueProvider.notifier)
            .enqueue(draft.withType(type), _plan);
        widget.onSent?.call();
    }
  }

  void _dire(String texte) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(texte)));

  // ------------------------------------------------------------------
  // Le rendu
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(recipientsProvider);
    if (catalogue != null) _preselectionne(catalogue);
    final visible = catalogue?.filter(_recherche) ?? RecipientCatalog.empty;
    final p = context.palette;
    final vibe = _vibe;
    final typeEffectif = _typeEffectif;
    final enRecherche = _recherche.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${_ctx.title} '),
            if (vibe != null) VibeTypeChip(type: typeEffectif),
          ],
        ),
        // 5. « Enregistrer pour moi » n'est PAS une destination : c'est le
        // cinquième contexte (Jay, 2026-08-14). Il agit maintenant, d'où sa
        // place hors du plan — et hors de la liste : un signet toujours sous
        // le pouce, au lieu d'un bouton tout en bas (Jay, 2026-09-14).
        actions: [
          if (vibe != null)
            Padding(
              padding: const EdgeInsets.only(right: NeoSpace.sm),
              child: SaveForMeButton(draft: vibe.draft),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: catalogue == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.only(bottom: NeoSpace.xxl),
                    children: [
                      if (widget.header != null) widget.header!,
                      // Le basculement 1/1 se lit sur la pastille du titre,
                      // et nulle part ailleurs : l'encadré doré qui vivait ici
                      // décalait toute la page (Jay, 2026-09-14).
                      if (!_ctx.libraryOnly)
                        _BarreDeRecherche(
                          controller: _rechercheCtrl,
                          onChanged: (v) => setState(() => _recherche = v),
                        ),

                      // 2. L'événement où je suis — tout en haut.
                      if (visible.currentEvent != null && !_ctx.libraryOnly)
                        _EventRow(
                          group: visible.currentEvent!,
                          share: _shareOf(visible.currentEvent!.conversationId),
                          dualTargets: _ctx.allowsConversationLibrary,
                          onChat: () =>
                              _toggleCible(visible.currentEvent!, chat: true),
                          onLibrary: () =>
                              _toggleCible(visible.currentEvent!, chat: false),
                        ),

                      // 3. Publier — deux petits boutons alignés.
                      if (_ctx.allowsPublish && !enRecherche) ...[
                        _TitreSection(
                          'Publier',
                          onGear: _ouvrirReglagesPublication,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: NeoSpace.lg,
                          ),
                          child: Row(
                            children: [
                              // Publication seulement : pas de story — la
                              // destination est la bibliothèque, et elle ne
                              // se décoche pas.
                              if (!_ctx.libraryOnly) ...[
                                Expanded(
                                  child: _PublishChip(
                                    icone: Icons.auto_awesome,
                                    label: 'Story',
                                    sousTitre: _sousTitreStory(),
                                    coche: _plan.story != null,
                                    onTap: _toggleStory,
                                  ),
                                ),
                                const SizedBox(width: NeoSpace.sm),
                              ],
                              Expanded(
                                child: _PublishChip(
                                  icone: Icons.grid_view,
                                  label: 'Bibliothèque',
                                  sousTitre: 'Permanente',
                                  coche: _plan.library != null,
                                  onTap: _ctx.libraryOnly
                                      ? null
                                      : _toggleLibrary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // 4. Groupes et amis — absents en publication seule.
                      if (!_ctx.libraryOnly) ...[
                        _TitreSection(
                          'Groupes et amis',
                          onGear: vibe == null
                              ? null
                              : _ouvrirReglagesDestinataires,
                        ),
                        if (visible.closest.isNotEmpty) ...[
                          _SousTitre(
                            'Les plus proches',
                            // Chat · Drop, textuel et discret (Jay). Absent
                            // quand le contexte n'a pas de Drop (repartage).
                            trailing: _ctx.allowsConversationLibrary
                                ? _SelecteurCible(
                                    mode: _modeProches,
                                    onChanged: (m) =>
                                        setState(() => _modeProches = m),
                                  )
                                : null,
                          ),
                          _ClosestGrid(
                            amis: visible.closest,
                            mode: _ctx.allowsConversationLibrary
                                ? _modeProches
                                : _CibleProche.chat,
                            estCoche: (f) {
                              final s = _shareOf(_keyOf(f));
                              if (s == null) return false;
                              return _ctx.allowsConversationLibrary &&
                                      _modeProches == _CibleProche.drop
                                  ? s.aussiDansLaBibliotheque
                                  : s.dansLeChat;
                            },
                            onTap: (f) => _ctx.allowsConversationLibrary
                                ? _toggleCible(
                                    f,
                                    chat: _modeProches == _CibleProche.chat,
                                  )
                                : _toggleSimple(f),
                          ),
                        ],
                        // L'événement en cours est déjà tout en haut : il ne
                        // figure pas une seconde fois dans les listes.
                        if (visible.groups.any(
                          (g) => g != visible.currentEvent,
                        )) ...[
                          const _SousTitre('Groupes'),
                          for (final g in visible.groups)
                            if (g != visible.currentEvent)
                              _RecipientRow(
                                recipient: g,
                                share: _shareOf(_keyOf(g)),
                                dualTargets: _ctx.allowsConversationLibrary,
                                onChat: () => _toggleCible(g, chat: true),
                                onLibrary: () => _toggleCible(g, chat: false),
                              ),
                        ],
                        if (visible.everyone.isNotEmpty) ...[
                          _SousTitre(
                            enRecherche ? 'Résultats' : 'Tout le monde',
                          ),
                          for (final r in visible.everyone)
                            if (r != visible.currentEvent)
                              _RecipientRow(
                                recipient: r,
                                share: _shareOf(_keyOf(r)),
                                dualTargets: _ctx.allowsConversationLibrary,
                                onChat: () => _toggleCible(r, chat: true),
                                onLibrary: () => _toggleCible(r, chat: false),
                              ),
                        ],
                        if (catalogue.everyone.isEmpty &&
                            catalogue.crossed.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(NeoSpace.xl),
                            child: Text(
                              'Personne à qui envoyer pour l\'instant. Les amis '
                              'se font en se croisant.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: context.muted),
                            ),
                          ),

                        if (_ctx.allowsCrossed && visible.crossed.isNotEmpty)
                          _Croises(
                            gens: visible.crossed,
                            plan: _plan,
                            onToggle: _toggleCroise,
                          ),
                      ],
                    ],
                  ),
          ),

          // 6. La barre d'envoi, collée en bas.
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
                label: _ctx.sendLabel,
                montreLeCout: vibe != null,
                onEnvoyer: _envoyer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _sousTitreStory() {
    final s = _plan.story;
    if (s == null) return '24 h';
    return switch (s.tier) {
      FriendshipTier.friend => 'Tous tes amis · 24 h',
      FriendshipTier.close => 'Tes proches · 24 h',
      FriendshipTier.inner => 'Tes inséparables · 24 h',
    };
  }
}

// ---------------------------------------------------------------------------
// Les pièces
// ---------------------------------------------------------------------------

class _BarreDeRecherche extends StatelessWidget {
  const _BarreDeRecherche({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NeoSpace.lg,
      NeoSpace.sm,
      NeoSpace.lg,
      NeoSpace.xs,
    ),
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 20),
        hintText: 'Chercher un(e) ami(e) ou un groupe…',
        filled: true,
        fillColor: context.palette.field,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NeoRadius.pill),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      ),
    ),
  );
}

/// Un titre de section avec, à droite, la roue ⚙︎ de ses réglages.
class _TitreSection extends StatelessWidget {
  const _TitreSection(this.texte, {this.onGear});
  final String texte;
  final VoidCallback? onGear;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NeoSpace.lg,
      NeoSpace.lg,
      NeoSpace.sm,
      NeoSpace.xs,
    ),
    child: Row(
      children: [
        Expanded(child: Text(texte, style: context.sectionTitle)),
        if (onGear != null)
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: 'Réglages',
            color: context.muted,
            visualDensity: VisualDensity.compact,
            onPressed: onGear,
          ),
      ],
    ),
  );
}

class _SousTitre extends StatelessWidget {
  const _SousTitre(this.texte, {this.trailing});
  final String texte;

  /// À droite du sous-titre, même ligne, même hauteur.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NeoSpace.lg,
      NeoSpace.md,
      NeoSpace.lg,
      NeoSpace.xs,
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            texte,
            style: context.sectionMeta.copyWith(
              color: context.faint,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Ce que la grille des plus proches pilote.
enum _CibleProche { chat, drop }

/// **Chat · Drop** — deux mots, pas d'icône, pas de fond (Jay, 2026-09-14 :
/// « discrets, pas encombrants, collant à l'UI »). Le mot actif prend la
/// couleur de sa cible : rose pour le chat, ambre pour le Drop — c'est le
/// premier des signes distinctifs entre les deux modes.
class _SelecteurCible extends StatelessWidget {
  const _SelecteurCible({required this.mode, required this.onChanged});
  final _CibleProche mode;
  final ValueChanged<_CibleProche> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _MotCible(
        'Chat',
        actif: mode == _CibleProche.chat,
        accent: Theme.of(context).colorScheme.primary,
        carre: false,
        onTap: () => onChanged(_CibleProche.chat),
      ),
      const SizedBox(width: NeoSpace.xs),
      _MotCible(
        'Drop',
        actif: mode == _CibleProche.drop,
        accent: dropAccent,
        carre: true,
        onTap: () => onChanged(_CibleProche.drop),
      ),
    ],
  );
}

class _MotCible extends StatelessWidget {
  const _MotCible(
    this.label, {
    required this.actif,
    required this.accent,
    required this.carre,
    required this.onTap,
  });
  final String label;
  final bool actif;
  final Color accent;

  /// Le mot « Drop » a les coins carrés, comme ses cases : le sélecteur
  /// annonce le style du mode qu'il ouvre.
  final bool carre;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(carre ? 0 : NeoRadius.pill);
    return InkWell(
      borderRadius: radius,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: actif ? accent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: radius,
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
    );
  }
}

/// Story · Bibliothèque : petits, alignés, cochables (Jay : « ils prennent
/// peu d'espace ! »).
class _PublishChip extends StatelessWidget {
  const _PublishChip({
    required this.icone,
    required this.label,
    required this.sousTitre,
    required this.coche,
    required this.onTap,
  });

  final IconData icone;
  final String label;
  final String sousTitre;
  final bool coche;

  /// Nul : la case est imposée (publication seule) — cochée, non cliquable.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(NeoRadius.md),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(
          horizontal: NeoSpace.md,
          vertical: NeoSpace.sm + 2,
        ),
        decoration: BoxDecoration(
          color: coche ? accent.withValues(alpha: 0.14) : context.palette.field,
          borderRadius: BorderRadius.circular(NeoRadius.md),
          border: Border.all(
            color: coche ? accent : context.palette.line,
            width: coche ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icone, size: 18, color: coche ? accent : context.muted),
            const SizedBox(width: NeoSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: coche ? accent : null,
                    ),
                  ),
                  Text(
                    sousTitre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.faint, fontSize: 11),
                  ),
                ],
              ),
            ),
            _Coche(coche: coche),
          ],
        ),
      ),
    );
  }
}

/// La coche ronde — la même partout.
class _Coche extends StatelessWidget {
  const _Coche({required this.coche, this.size = 22, this.drop = false});
  final bool coche;
  final double size;

  /// En mode Drop : carrée, ambre, et l'icône du Drop à la place de la coche
  /// — la case dit *où* ça part sans un mot (Jay, 2026-09-14).
  final bool drop;

  @override
  Widget build(BuildContext context) {
    final accent = drop ? dropAccent : Theme.of(context).colorScheme.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: drop ? BoxShape.rectangle : BoxShape.circle,
        color: coche ? accent : Colors.transparent,
        border: Border.all(
          color: coche ? accent : context.palette.line,
          width: 1.5,
        ),
      ),
      child: coche
          ? Icon(
              drop ? dropIcon : Icons.check,
              size: size * 0.65,
              color: Colors.white,
            )
          : null,
    );
  }
}

/// Une cible d'une ligne : 💬 ou Drop, allumée ou non (§2.7). Le Drop
/// s'allume en ambre, le chat en rose : la même couleur que dans la grille.
class _Cible extends StatelessWidget {
  const _Cible({
    required this.icone,
    required this.actif,
    required this.onTap,
    required this.tooltip,
    this.drop = false,
  });

  final IconData icone;
  final bool actif;
  final VoidCallback onTap;
  final String tooltip;
  final bool drop;

  @override
  Widget build(BuildContext context) {
    final accent = drop ? dropAccent : Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(NeoRadius.sm),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 36,
          height: 32,
          decoration: BoxDecoration(
            color: actif ? accent.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(NeoRadius.sm),
            border: Border.all(color: actif ? accent : context.palette.line),
          ),
          child: Icon(icone, size: 18, color: actif ? accent : context.muted),
        ),
      ),
    );
  }
}

/// Le tableau des 10 plus proches, 2 colonnes, pseudo tronqué, coche.
///
/// Une seule grille pour deux cibles ([mode]) : ce qui change est la coche,
/// la couleur et la forme des cases cochées — jamais leur contenu.
class _ClosestGrid extends StatelessWidget {
  const _ClosestGrid({
    required this.amis,
    required this.mode,
    required this.estCoche,
    required this.onTap,
  });

  final List<FriendRecipient> amis;
  final _CibleProche mode;
  final bool Function(FriendRecipient) estCoche;
  final void Function(FriendRecipient) onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
    child: GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: NeoSpace.sm,
      crossAxisSpacing: NeoSpace.sm,
      childAspectRatio: 3.1,
      children: [
        for (final f in amis)
          _FriendCell(
            ami: f,
            coche: estCoche(f),
            drop: mode == _CibleProche.drop,
            onTap: () => onTap(f),
          ),
      ],
    ),
  );
}

class _FriendCell extends StatelessWidget {
  const _FriendCell({
    required this.ami,
    required this.coche,
    required this.drop,
    required this.onTap,
  });

  final FriendRecipient ami;
  final bool coche;

  /// Mode Drop : les cases **cochées** passent en ambre, **coins carrés**,
  /// icône du Drop. Les cases non cochées ne changent pas d'un mode à l'autre.
  /// Les coins carrés sont **à l'essai** (Jay, 2026-09-14 : « si cela ne
  /// convient pas on reviendra sur un style plus basique ») — un seul nombre
  /// à changer ici.
  final bool drop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = drop ? dropAccent : Theme.of(context).colorScheme.primary;
    final radius = BorderRadius.circular(drop && coche ? 0 : NeoRadius.md);
    return InkWell(
      borderRadius: radius,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(
          horizontal: NeoSpace.sm,
          vertical: NeoSpace.xs,
        ),
        decoration: BoxDecoration(
          color: coche ? accent.withValues(alpha: 0.12) : context.palette.field,
          borderRadius: radius,
          border: Border.all(color: coche ? accent : Colors.transparent),
        ),
        child: Row(
          children: [
            TierAvatar(
              peerId: ami.userId,
              storedAvatar: ami.profile.avatarUrl,
              initiale: ami.profile.chatName.characters.first.toUpperCase(),
              size: 34,
            ),
            const SizedBox(width: NeoSpace.sm),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ami.profile.chatName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    ami.serie > 0
                        ? '${ami.tier.label} · ${ami.serie} 🔥'
                        : ami.tier.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.faint, fontSize: 11),
                  ),
                ],
              ),
            ),
            _Coche(coche: coche, size: 20, drop: drop),
          ],
        ),
      ),
    );
  }
}

/// Une ligne de la liste : un ami ou un groupe, avec sa coche — ou ses deux
/// cibles 💬 / Drop quand le Drop est permis.
class _RecipientRow extends StatelessWidget {
  const _RecipientRow({
    required this.recipient,
    required this.share,
    required this.dualTargets,
    required this.onChat,
    required this.onLibrary,
  });

  final Recipient recipient;
  final ConversationShare? share;
  final bool dualTargets;
  final VoidCallback onChat;
  final VoidCallback onLibrary;

  @override
  Widget build(BuildContext context) {
    final r = recipient;
    final Widget avant;
    final String titre;
    final String sousTitre;
    switch (r) {
      case FriendRecipient():
        avant = TierAvatar(
          peerId: r.userId,
          storedAvatar: r.profile.avatarUrl,
          initiale: r.profile.chatName.characters.first.toUpperCase(),
          size: 40,
        );
        titre = r.profile.chatName;
        sousTitre = r.serie > 0
            ? '${r.tier.label} · ${r.serie} 🔥'
            : r.tier.label;
      case GroupRecipient():
        avant = Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: context.palette.field,
            shape: BoxShape.circle,
          ),
          child: Icon(r.isEvent ? Icons.celebration : Icons.group, size: 20),
        );
        titre = r.label;
        sousTitre = r.isEvent
            ? 'Événement · ${r.memberIds.length + 1} présents'
            : '${r.memberIds.length + 1} membres';
    }
    final coche = share != null;
    final chat = share?.dansLeChat ?? false;
    final lib = share?.aussiDansLaBibliotheque ?? false;

    return InkWell(
      onTap: onChat,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NeoSpace.lg,
          vertical: NeoSpace.sm,
        ),
        child: Row(
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
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    sousTitre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.faint, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: NeoSpace.sm),
            if (dualTargets) ...[
              _Cible(
                icone: Icons.chat_bubble_outline,
                actif: chat,
                tooltip: 'Dans le chat',
                onTap: onChat,
              ),
              const SizedBox(width: NeoSpace.xs),
              _Cible(
                icone: dropIcon,
                actif: lib,
                drop: true,
                tooltip: 'Dans le Drop — révélé à 18h30',
                onTap: onLibrary,
              ),
            ] else
              _Coche(coche: coche),
          ],
        ),
      ),
    );
  }
}

/// « Nom de l'événement » — tout en haut, avant « Publier » (Jay). Drop par
/// défaut : celui du groupe d'événement ; 💬 disponible.
class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.group,
    required this.share,
    required this.dualTargets,
    required this.onChat,
    required this.onLibrary,
  });

  final GroupRecipient group;
  final ConversationShare? share;
  final bool dualTargets;
  final VoidCallback onChat;
  final VoidCallback onLibrary;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final coche = share != null;
    final chat = share?.dansLeChat ?? false;
    final lib = share?.aussiDansLaBibliotheque ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.lg,
        NeoSpace.md,
        NeoSpace.lg,
        0,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(NeoRadius.md),
        // Par défaut, le DROP de l'événement (Jay, 2026-09-14).
        onTap: dualTargets ? onLibrary : onChat,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(
            horizontal: NeoSpace.md,
            vertical: NeoSpace.sm + 2,
          ),
          decoration: BoxDecoration(
            gradient: coche ? context.palette.signatureCourte : null,
            color: coche ? null : context.palette.field,
            borderRadius: BorderRadius.circular(NeoRadius.md),
            border: Border.all(color: coche ? accent : context.palette.line),
          ),
          child: Row(
            children: [
              Icon(
                Icons.celebration,
                size: 20,
                color: coche ? Colors.white : accent,
              ),
              const SizedBox(width: NeoSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: coche ? Colors.white : null,
                      ),
                    ),
                    Text(
                      'Événement en cours',
                      style: TextStyle(
                        fontSize: 11,
                        color: coche ? Colors.white70 : context.faint,
                      ),
                    ),
                  ],
                ),
              ),
              if (dualTargets) ...[
                _Cible(
                  icone: Icons.chat_bubble_outline,
                  actif: chat,
                  tooltip: 'Dans le chat de l\'événement',
                  onTap: onChat,
                ),
                const SizedBox(width: NeoSpace.xs),
                _Cible(
                  icone: dropIcon,
                  actif: lib,
                  drop: true,
                  tooltip: 'Dans le Drop de l\'événement',
                  onTap: onLibrary,
                ),
              ] else
                _Coche(coche: coche),
            ],
          ),
        ),
      ),
    );
  }
}

class _Croises extends StatelessWidget {
  const _Croises({
    required this.gens,
    required this.plan,
    required this.onToggle,
  });

  final List<CrossedPerson> gens;
  final SharePlan plan;
  final void Function(CrossedPerson) onToggle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SousTitre('Croisé(e)s récemment'),
      Padding(
        padding: const EdgeInsets.fromLTRB(NeoSpace.lg, 0, NeoSpace.lg, 4),
        child: Text(
          'Vous vous êtes croisés pour de vrai. Ta Vibe part avec une demande '
          'de connexion.',
          style: TextStyle(color: context.faint, fontSize: 11),
        ),
      ),
      for (final g in gens)
        InkWell(
          onTap: () => onToggle(g),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NeoSpace.lg,
              vertical: NeoSpace.sm,
            ),
            child: Row(
              children: [
                Avatar(
                  stored: g.avatarUrl,
                  radius: 20,
                  fallback: Text(g.displayName.characters.first.toUpperCase()),
                ),
                const SizedBox(width: NeoSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        g.alreadyRequested
                            ? 'Demande déjà envoyée — ta Vibe s\'y ajoutera'
                            : (g.tagName == null
                                  ? g.provenance
                                  : '@${g.tagName} · ${g.provenance}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: context.faint, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                _Coche(coche: plan.crossed.any((c) => c.userId == g.userId)),
              ],
            ),
          ),
        ),
    ],
  );
}

class _BoutonEnvoyer extends StatelessWidget {
  const _BoutonEnvoyer({
    required this.plan,
    required this.label,
    required this.montreLeCout,
    required this.onEnvoyer,
  });

  final SharePlan plan;
  final String label;
  final bool montreLeCout;

  /// Ce que dit le bouton tant qu'aucune destination n'est cochée. Court,
  /// parce que la boîte de texte Rive l'est (voir le `build`).
  static const _inerte = 'À qui ?';
  final VoidCallback onEnvoyer;

  @override
  Widget build(BuildContext context) {
    final destinations = plan.destinations;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ⚠️ **Le coût est DIT, pas caché.** Chaque contexte dépose ses propres
        // octets ; deux « Sauvegardable » différents font deux Cards.
        if (montreLeCout && plan.televersements > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: NeoSpace.sm),
            child: Text(
              '${plan.televersements} fichiers — ta Vibe part une fois par '
              'destination',
              style: TextStyle(color: context.faint, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
        // Le bouton d'envoi Rive de Jay (habillage, jamais une dépendance :
        // le `FilledButton` prend le relais si le fichier ne charge pas).
        //
        // ⚠️ **Le libellé est dessiné DANS le fichier Rive**, dans une boîte
        // de texte à largeur fixe (artboard 220 × 110) : un texte plus long
        // que la boîte est **rogné des deux côtés**, sans que le Dart puisse
        // le mesurer. « CHOISIS UNE DESTINATION » ne tenait pas (Jay,
        // 2026-09-14). Règle : un libellé court, de la taille de
        // « PARTAGER · 12 » au plus. L'adaptation à la longueur du texte se
        // règle dans Rive (texte en auto-fit), pas ici.
        RiveSendButton(
          label: (destinations == 0 ? _inerte : '$label · $destinations')
              .toUpperCase(),
          onPressed: destinations == 0 ? null : onEnvoyer,
          height: 72,
          fallback: FilledButton(
            onPressed: destinations == 0 ? null : onEnvoyer,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: Text(destinations == 0 ? _inerte : '$label · $destinations'),
          ),
        ),
      ],
    );
  }
}
