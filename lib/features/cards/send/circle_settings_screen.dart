import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/saved_store.dart';
import '../../../core/models/card.dart';
import '../../../core/prefs.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/send_wave.dart';
import '../../connections/connections_repository.dart';
import '../cards_repository.dart';
import 'send_common.dart';
import 'send_format_screen.dart';
import 'vibe_draft.dart';

/// **Étape 2 — le cercle.** Partage direct en DM et en groupe : le seul
/// contexte où les limites d'ouvertures et de durée s'appliquent, et le seul
/// jamais repartageable.
///
/// Refonte du 2026-08-14, consigne de Jay : « déplacer les curseurs et
/// paramètres de visionnage dans un bouton réglage en haut à droite ». L'écran
/// ne montre plus que ce qui se décide vraiment ici — **à qui** — et range les
/// règles derrière un bouton. Elles ont des défauts justes ; les mettre au
/// premier plan disait le contraire.
class CircleSettingsScreen extends ConsumerStatefulWidget {
  const CircleSettingsScreen({super.key, required this.draft});

  final VibeDraft draft;

  @override
  ConsumerState<CircleSettingsScreen> createState() =>
      _CircleSettingsScreenState();
}

class _CircleSettingsScreenState extends ConsumerState<CircleSettingsScreen> {
  final _selected = <String>{};
  var _loading = false;

  /// Les destinataires pourront l'enregistrer dans leurs Enregistrements.
  var _saveable = false;

  /// Nombre d'**ouvertures**. Null = illimité. Initialisé depuis les réglages.
  late int? _maxViews = _viewsFromPref(ref.read(defaultMaxViewsProvider));

  /// Durée de lecture par face, en secondes. Null = illimitée. Défaut depuis le
  /// 2026-08-14 : illimitée.
  late int? _viewDuration = _durationFromPref(
    ref.read(defaultViewDurationProvider),
  );

  /// Le destinataire peut contrôler la barre de lecture des vidéos
  /// (défaut : intouchable — consigne Jay).
  var _scrubbable = false;

  static int? _viewsFromPref(int pref) =>
      pref == DefaultMaxViews.unlimited ? null : pref;

  static int? _durationFromPref(int pref) =>
      pref == DefaultViewDuration.unlimited ? null : pref;

  VibeDraft get _draft => widget.draft;

  /// La Vibe est-elle, EN L'ÉTAT, une One of One ?
  ///
  /// Condition arrêtée par Jay le 2026-08-10 : un seul destinataire et aucune
  /// publication. Depuis que les formats sont **exclusifs**, la seconde moitié
  /// de la condition est acquise du seul fait d'être sur cet écran — il ne
  /// reste qu'à compter les destinataires. « Enregistrer pour moi » ne compte
  /// pas : c'est une copie privée, elle ne diffuse rien.
  ///
  /// Le **BeReal en est exclu** : c'est un format à identité propre (l'instant
  /// imposé du jour), le repeindre en or effacerait ce qu'il raconte.
  bool get _isOneOfOne =>
      _draft.type != CardType.bereal && _selected.length == 1;

  /// Type réellement enregistré en base.
  CardType get _effectiveType => _isOneOfOne ? CardType.oneOfOne : _draft.type;

  @override
  void initState() {
    super.initState();
    // Envoi direct : les destinataires du chat sont les seuls, dès l'ouverture.
    if (_draft.directRecipientIds != null) {
      _selected.addAll(_draft.directRecipientIds!);
      // Seul chemin qui saute l'étape 1 : sans cet appel, un utilisateur venu
      // d'un chat n'aurait jamais l'explication des règles de visionnage.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => maybeShowVibesExplainer(context, ref),
      );
    }
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ViewingRulesSheet(
        draft: _draft,
        maxViews: _maxViews,
        viewDuration: _viewDuration,
        scrubbable: _scrubbable,
        onChanged: (views, duration, scrubbable) => setState(() {
          _maxViews = views;
          _viewDuration = duration;
          _scrubbable = scrubbable;
        }),
      ),
    );
  }

  Future<void> _send() async {
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisis au moins un destinataire.')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final repo = ref.read(cardsRepositoryProvider);
      final type = _effectiveType;
      final card = await repo.create(
        front: _draft.front,
        back: _draft.back,
        type: type,
        // Pas de face photo = pas de limite de durée (les vidéos se lisent en
        // entier).
        viewDurationSeconds: _draft.hasPhoto ? _viewDuration : null,
        maxViews: _maxViews,
        // Une One of One n'est jamais enregistrable par son destinataire :
        // l'exclusivité EST le format.
        saveable: _saveable && type.canBeSaveable,
        imported: _draft.imported,
        frontIsVideo: _draft.frontIsVideo,
        backIsVideo: _draft.backIsVideo,
        scrubbable: _draft.hasVideo && _scrubbable,
      );
      await repo.send(card, _selected.toList());
      // La copie locale prend son vrai Content ID : c'est par lui que la
      // révocation de modération la retrouvera.
      await ref.read(savedStoreProvider).rekey(_draft.localId, card.id);
      ref.invalidate(savedItemsProvider);
      if (!mounted) return;
      // La vague part AVANT le dépilage : elle vit dans l'Overlay racine, donc
      // elle survit à la navigation, mais il lui faut un contexte encore monté.
      SendWave.play(context);
      if (_draft.direct) {
        // Retour AU CHAT d'où la capture a été ouverte : on dépile le
        // paramétrage et l'écran de capture (chat → capture → paramétrage). Le
        // `popUntil(isFirst)` du parcours normal ramènerait à la racine et
        // ferait perdre la conversation.
        final nav = Navigator.of(context);
        nav.pop();
        nav.pop();
      } else {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Vibe envoyée ✓')));
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
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);
    // Le type suit le nombre de destinataires : ajouter quelqu'un fait
    // retomber la Vibe du One of One vers son type de capture, en direct.
    final type = _effectiveType;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Cercle '),
            VibeTypeChip(type: type),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.tune),
            tooltip: 'Règles de visionnage',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_draft.direct)
            ListTile(
              dense: true,
              leading: const Icon(Icons.send, size: 18),
              title: Text(
                'Envoi direct à ${_draft.directRecipientLabel ?? 'ce chat'}',
              ),
              subtitle: const Text('Elle partira dans cette conversation.'),
            ),
          if (_isOneOfOne) const OneOfOneBanner(),
          _RulesSummary(
            maxViews: _maxViews,
            viewDuration: _draft.hasPhoto ? _viewDuration : null,
            onTap: _openSettings,
          ),
          SaveableSwitch(
            type: type,
            value: _saveable,
            onChanged: (v) => setState(() => _saveable = v),
          ),
          SaveForMeButton(draft: _draft),
          const Divider(height: 1),
          if (_draft.direct)
            const Spacer()
          else
            Expanded(
              child: connections.isEmpty
                  ? const SendEmptyNote('Aucune connexion à qui envoyer.')
                  : ListView(
                      children: [
                        for (final connection in connections)
                          RecipientTile(
                            peerId: connection.peerIdFor(me),
                            selected: _selected.contains(
                              connection.peerIdFor(me),
                            ),
                            onChanged: (checked) => setState(() {
                              final id = connection.peerIdFor(me);
                              if (checked) {
                                _selected.add(id);
                              } else {
                                _selected.remove(id);
                              }
                            }),
                          ),
                      ],
                    ),
            ),
          SendActionBar(
            label: _draft.direct
                ? 'Envoyer à ${_draft.directRecipientLabel ?? 'ce chat'}'
                : 'Envoyer',
            loading: _loading,
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}

/// Le rappel des règles en vigueur, cliquable.
///
/// Il existe parce que les régler est passé derrière un bouton : sans lui,
/// « 2 ouvertures » deviendrait une règle qui s'applique sans jamais s'annoncer
/// — exactement ce que la refonte cherchait à éviter en les sortant du chemin.
class _RulesSummary extends StatelessWidget {
  const _RulesSummary({
    required this.maxViews,
    required this.viewDuration,
    required this.onTap,
  });

  final int? maxViews;
  final int? viewDuration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final views = maxViews == null
        ? 'ouvertures illimitées'
        : '$maxViews ouverture${maxViews! > 1 ? 's' : ''}';
    final duration = viewDuration == null
        ? 'lecture illimitée'
        : '$viewDuration s par face';
    return ListTile(
      dense: true,
      leading: const Icon(Icons.tune, size: 18),
      title: Text('$views · $duration'),
      subtitle: Text(
        'Retourner la Vibe ne consomme rien',
        style: TextStyle(color: context.muted),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: onTap,
    );
  }
}

/// Les règles de visionnage, derrière le bouton « réglages » de l'AppBar.
class _ViewingRulesSheet extends StatefulWidget {
  const _ViewingRulesSheet({
    required this.draft,
    required this.maxViews,
    required this.viewDuration,
    required this.scrubbable,
    required this.onChanged,
  });

  final VibeDraft draft;
  final int? maxViews;
  final int? viewDuration;
  final bool scrubbable;
  final void Function(int? maxViews, int? viewDuration, bool scrubbable)
  onChanged;

  @override
  State<_ViewingRulesSheet> createState() => _ViewingRulesSheetState();
}

class _ViewingRulesSheetState extends State<_ViewingRulesSheet> {
  /// 1-5 ouvertures ; **6 = illimité**. Le curseur porte le cran « illimité »
  /// au lieu d'un interrupteur à côté : c'est le même réglage, il n'a pas à se
  /// faire en deux gestes à deux endroits.
  late int _views = widget.maxViews ?? 6;

  /// 1-20 s ; **21 = illimitée**.
  late int _duration = widget.viewDuration ?? 21;

  late bool _scrubbable = widget.scrubbable;

  void _push() => widget.onChanged(
    _views == 6 ? null : _views,
    _duration == 21 ? null : _duration,
    _scrubbable,
  );

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Règles de visionnage',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Elles ne s\'appliquent qu\'ici : une story ou une publication '
              'n\'en a pas.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.muted),
            ),
            const SizedBox(height: 14),

            Text(
              _views == 6 ? 'Ouvertures : illimitées' : 'Ouvertures : $_views',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              'Une ouverture, pas un affichage : la Vibe se retourne autant '
              'qu\'on veut tant qu\'elle est ouverte.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.muted),
            ),
            Slider(
              value: _views.toDouble(),
              min: 1,
              max: 6,
              divisions: 5,
              label: _views == 6 ? '∞' : '$_views',
              onChanged: (v) {
                setState(() => _views = v.round());
                _push();
              },
            ),

            // La durée de lecture ne concerne que les faces photo : une face
            // vidéo se lit en entier (consigne Jay 2026-07-12).
            if (draft.hasPhoto) ...[
              const SizedBox(height: 8),
              Text(
                _duration == 21
                    ? 'Durée de lecture${draft.hasVideo ? ' (face photo)' : ''} : illimitée'
                    : 'Durée de lecture${draft.hasVideo ? ' (face photo)' : ''} : $_duration s',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                'Par face, et le compte se met en pause quand on retourne la '
                'Vibe.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: context.muted),
              ),
              Slider(
                value: _duration.toDouble(),
                min: 1,
                max: 21,
                divisions: 20,
                label: _duration == 21 ? '∞' : '$_duration s',
                onChanged: (v) {
                  setState(() => _duration = v.round());
                  _push();
                },
              ),
            ],

            if (draft.hasVideo) ...[
              const SizedBox(height: 4),
              ScrubbableSwitch(
                value: _scrubbable,
                onChanged: (v) {
                  setState(() => _scrubbable = v);
                  _push();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
