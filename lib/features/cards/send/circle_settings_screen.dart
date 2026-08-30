import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/saved_store.dart';
import '../../../core/models/card.dart';
import '../../../core/prefs.dart';
import '../../../core/supabase_providers.dart';
import '../../connections/connections_repository.dart';
import '../cards_repository.dart';
import 'send_common.dart';
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
      builder: (_) => ViewingRulesSheet(
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
          ViewingRulesSummary(
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
