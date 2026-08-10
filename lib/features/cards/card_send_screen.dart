import 'dart:io';

import 'package:flutter/material.dart';
import '../../core/widgets/avatar.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/card.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import '../stories/stories_repository.dart';
import 'cards_repository.dart';

/// Destination et paramètres d'une Card.
/// - vues (1-5, défaut selon réglages) et durée de lecture (1-20 s ou
///   illimitée, défaut selon réglages) choisies par le créateur pour CETTE
///   card ;
/// - bibliothèque : lecture toujours illimitée (limites appliquées en chat
///   uniquement).
///
/// **One of One automatique** (demande de Jay 2026-08-10) : le type ne se
/// choisit plus à la capture. Si la Card part à **un seul destinataire** et
/// n'est **ni publiée en bibliothèque ni mise en story**, elle devient une
/// One of One — mention et style or appliqués tout seuls. Jay a confirmé que
/// la règle vaut **partout**, y compris pour une Card envoyée directement
/// depuis un chat en tête-à-tête.
class CardSendScreen extends ConsumerStatefulWidget {
  const CardSendScreen({
    super.key,
    required this.front,
    required this.back,
    required this.type,
    this.imported = false,
    this.frontIsVideo = false,
    this.backIsVideo = false,
    this.directRecipientIds,
    this.directRecipientLabel,
  });

  /// **Envoi direct depuis un chat** (consigne Jay 2026-08-01). Quand elle est
  /// fournie, la destination est imposée : plus de liste de connexions, plus de
  /// publication en bibliothèque. Ne restent que les réglages de la Card
  /// elle-même et l'enregistrement dans MES Enregistrements.
  ///
  /// Liste et non identifiant unique : dans un groupe, « le destinataire du
  /// chat » désigne tous les autres membres.
  final List<String>? directRecipientIds;
  final String? directRecipientLabel;

  final File front;

  /// Null = Card à face unique (verso passé à la prise).
  final File? back;

  /// Type issu de la capture (`standard`, `oneshot` ou `bereal`). Le type
  /// réellement enregistré peut devenir `oneOfOne` — voir [_effectiveType].
  final CardType type;

  /// Au moins une face vient de la galerie (logo galerie sur le container).
  final bool imported;

  /// Faces vidéo : la durée de visionnage ne s'applique qu'aux faces photo ;
  /// une face vidéo se lit en entier (consigne Jay 2026-07-12).
  final bool frontIsVideo;
  final bool backIsVideo;

  @override
  ConsumerState<CardSendScreen> createState() => _CardSendScreenState();
}

class _CardSendScreenState extends ConsumerState<CardSendScreen> {
  final _selected = <String>{};
  var _publish = false;

  /// Envoi direct : le destinataire vient du chat d'où la capture a été
  /// ouverte, il n'y a rien à choisir.
  bool get _direct => widget.directRecipientIds != null;

  /// Publication PUBLIQUE : un rang au-dessus de « connexions » — visible par
  /// toute personne accédant au profil par un moyen légitime (jamais Hot).
  var _publishPublic = false;
  var _loading = false;

  /// Les destinataires pourront l'enregistrer dans leurs Enregistrements.
  var _saveable = false;

  /// Copie privée dans MES Enregistrements (bibliothèque privée).
  var _saveForMe = false;

  /// Publication en story, 24 h (consigne Jay 2026-08-02). Indépendante de la
  /// bibliothèque : on peut mettre en story sans publier, et l'inverse.
  var _publishStory = false;

  /// Vues par card (1-5). Initialisé depuis les réglages.
  late int _maxViews = ref.read(defaultMaxViewsProvider);

  /// Durée de lecture : 1-20 s ; 21 = illimitée. Initialisé depuis les réglages.
  late int _durationSlider = _fromPref(ref.read(defaultViewDurationProvider));

  static int _fromPref(int pref) =>
      pref == DefaultViewDuration.unlimited ? 21 : pref;

  /// Le destinataire peut contrôler la barre de lecture des vidéos
  /// (défaut : intouchable — consigne Jay).
  var _scrubbable = false;

  /// La Card est-elle, EN L'ÉTAT des cases cochées, une One of One ?
  ///
  /// Condition arrêtée par Jay le 2026-08-10 : un seul destinataire, pas de
  /// publication en bibliothèque, pas de story. « Enregistrer pour moi » ne
  /// compte pas — c'est une copie privée, elle ne diffuse rien.
  ///
  /// Le **BeReal en est exclu** : c'est un format à identité propre (l'instant
  /// imposé du jour), le repeindre en or effacerait ce qu'il raconte.
  bool get _isOneOfOne =>
      widget.type != CardType.bereal &&
      _selected.length == 1 &&
      !_publish &&
      !_publishStory;

  /// Type réellement enregistré en base.
  CardType get _effectiveType => _isOneOfOne ? CardType.oneOfOne : widget.type;

  bool get _hasVideo => widget.frontIsVideo || widget.backIsVideo;

  /// Au moins une face photo : la limite de durée de visionnage garde un
  /// sens (les faces vidéo se lisent en entier).
  bool get _hasPhoto =>
      !widget.frontIsVideo || (widget.back != null && !widget.backIsVideo);

  @override
  void initState() {
    super.initState();
    // Envoi direct : les destinataires du chat sont les seuls, dès l'ouverture.
    if (widget.directRecipientIds != null) {
      _selected.addAll(widget.directRecipientIds!);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowExplainer());
  }

  /// Popup de première utilisation : règles de visionnage (consigne Jay).
  Future<void> _maybeShowExplainer() async {
    if (ref.read(cardsExplainerShownProvider)) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Comment vivent tes Vibes'),
        content: const SingleChildScrollView(
          child: Text(
            'Dans les chats, une Vibe se voit un nombre limité de fois '
            '(2 par défaut) et pendant une durée limitée par vue (10 s par '
            'défaut) — tu choisis ces limites pour chaque Vibe, et tes '
            'défauts se règlent dans Réglages > Vibes.\n\n'
            'Chaque Vibe apparaît dans le chat comme un container : on clique '
            'pour l\'ouvrir, jamais d\'aperçu. Le container reste 24 h et le '
            'destinataire peut te demander un replay : rien ne se revoit sans '
            'ton accord.\n\n'
            'Si tu l\'envoies à UNE seule personne sans la publier, elle '
            'devient une One of One : exclusive, pour elle seule, à jamais.\n\n'
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

  Future<void> _send() async {
    if (_selected.isEmpty && !_publish && !_saveForMe && !_publishStory) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Choisis au moins un destinataire, publie ou enregistre pour toi.',
          ),
        ),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final repo = ref.read(cardsRepositoryProvider);
      final type = _effectiveType;
      final card = await repo.create(
        front: widget.front,
        back: widget.back,
        type: type,
        // Pas de face photo = pas de limite de durée (les vidéos se lisent
        // en entier)
        viewDurationSeconds: !_hasPhoto || _durationSlider == 21
            ? null
            : _durationSlider,
        maxViews: _maxViews,
        // Une One of One n'est jamais enregistrable par son destinataire :
        // l'exclusivité EST le format.
        saveable: _saveable && type.canBeSaveable,
        imported: widget.imported,
        frontIsVideo: widget.frontIsVideo,
        backIsVideo: widget.backIsVideo,
        scrubbable: _hasVideo && _scrubbable,
      );
      if (_selected.isNotEmpty) {
        await repo.send(card, _selected.toList());
      }
      if (_publish) {
        await repo.publishToLibrary(card, isPublic: _publishPublic);
      }
      if (_saveForMe) {
        await repo.saveCard(card.id);
      }
      if (_publishStory) {
        await ref.read(storiesRepositoryProvider).publish(card.id);
      }
      if (mounted) {
        if (_direct) {
          // Retour AU CHAT d'où la capture a été ouverte : on dépile l'écran
          // d'envoi et l'écran de capture (chat → capture → envoi). Le
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
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
      }
    }
  }

  /// Le 413 du Storage (« exceeded the maximum allowed size ») est illisible
  /// pour un utilisateur : on dit ce qui s'est passé et quoi faire.
  String _friendlyError(Object e) {
    final text = e.toString();
    if (text.contains('413') || text.contains('maximum allowed size')) {
      return 'Média trop lourd pour l\'envoi (limite serveur). '
          'Refais une vidéo plus courte.';
    }
    return 'Erreur : $text';
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);
    // Le type suit les cases cochées : ajouter un destinataire ou publier
    // fait retomber la Card du One of One vers son type de capture, en direct.
    final type = _effectiveType;
    final storiesPublic =
        ref.watch(myProfileProvider).value?.storiesPublic ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Envoyer '),
            // La pastille se met à jour en direct : c'est elle qui annonce le
            // basculement automatique en One of One.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: Container(
                key: ValueKey(type),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  gradient: type.gradient,
                  border: type.gradient == null
                      ? Border.all(color: type.color)
                      : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  type.tag,
                  style: TextStyle(
                    color: type.gradient == null ? type.color : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_direct)
            ListTile(
              dense: true,
              leading: const Icon(Icons.send, size: 18),
              title: Text(
                'Envoi direct à ${widget.directRecipientLabel ?? 'ce chat'}',
              ),
              subtitle: const Text('Elle partira dans cette conversation.'),
            ),
          // Bandeau du One of One automatique : il dit CE QUI se passe et
          // POURQUOI, sinon le changement de pastille reste inexpliqué.
          if (_isOneOfOne) const _OneOfOneBanner(),
          ListTile(
            dense: true,
            title: Text('Visionnages : $_maxViews'),
            subtitle: Slider(
              value: _maxViews.toDouble(),
              min: 1,
              max: 5,
              divisions: 4,
              label: '$_maxViews',
              onChanged: (v) => setState(() => _maxViews = v.round()),
            ),
          ),
          // La durée de lecture ne concerne que les faces photo : une face
          // vidéo se lit en entier (consigne Jay 2026-07-12).
          if (_hasPhoto)
            ListTile(
              dense: true,
              title: Text(
                _durationSlider == 21
                    ? 'Durée de lecture${_hasVideo ? ' (face photo)' : ''} : illimitée'
                    : 'Durée de lecture${_hasVideo ? ' (face photo)' : ''} : $_durationSlider s',
              ),
              subtitle: Slider(
                value: _durationSlider.toDouble(),
                min: 1,
                max: 21,
                divisions: 20,
                label: _durationSlider == 21 ? '∞' : '$_durationSlider s',
                onChanged: (v) => setState(() => _durationSlider = v.round()),
              ),
            ),
          if (_hasVideo)
            SwitchListTile(
              title: const Text('Barre de lecture contrôlable'),
              subtitle: const Text(
                'Désactivé : le destinataire voit la progression mais ne '
                'peut pas se déplacer dans la vidéo',
              ),
              value: _scrubbable,
              onChanged: (v) => setState(() => _scrubbable = v),
            ),
          // Envoi direct : la publication en bibliothèque n'a pas sa place ici
          // (consigne Jay 2026-08-01 — « interface de sélection d'options
          // simplifiée »). Elle reste accessible par le parcours normal.
          if (!_direct) ...[
            SwitchListTile(
              title: const Text('Publier dans ma bibliothèque'),
              subtitle: const Text(
                'Là-bas, lecture illimitée — visible selon tes règles d\'accès',
              ),
              value: _publish,
              onChanged: (v) => setState(() {
                _publish = v;
                if (!v) _publishPublic = false;
              }),
            ),
            if (_publish)
              SwitchListTile(
                title: const Text('Publication publique'),
                subtitle: const Text(
                  'Visible par toute personne qui accède à ton profil '
                  '(croisements ping compris) — tag « Public » affiché',
                ),
                value: _publishPublic,
                onChanged: (v) => setState(() => _publishPublic = v),
              ),
          ],
          // Une One of One n'est jamais enregistrable par son destinataire :
          // l'interrupteur reste visible mais inerte, pour que la règle se
          // lise au lieu de disparaître sans explication.
          SwitchListTile(
            title: const Text('Sauvegardable'),
            subtitle: Text(
              type.canBeSaveable
                  ? 'Les destinataires pourront la garder dans leurs Enregistrements'
                  : 'Impossible sur une One of One — elle n\'existe que pour '
                        'son destinataire, le temps de sa vue',
            ),
            value: _saveable && type.canBeSaveable,
            onChanged: type.canBeSaveable
                ? (v) => setState(() => _saveable = v)
                : null,
          ),
          // Ouvert AUSSI à la One of One depuis le 2026-08-10 (demande de
          // Jay) : l'exclusivité vaut pour le destinataire, elle n'empêche pas
          // l'auteur de garder sa propre card.
          SwitchListTile(
            title: const Text('Enregistrer pour moi'),
            subtitle: const Text(
              'Copie privée dans mes Enregistrements, visible de moi seul',
            ),
            value: _saveForMe,
            onChanged: (v) => setState(() => _saveForMe = v),
          ),
          // La story reste proposée en envoi direct : mettre sa card en story
          // n'a rien à voir avec le destinataire du chat. La cocher fait
          // retomber la Card du One of One (ce n'est plus exclusif).
          SwitchListTile(
            title: const Text('Mettre en story'),
            subtitle: Text(
              storiesPublic
                  ? 'Visible 24 h par tes amis ET par les personnes que tu '
                        'croises — tes stories sont publiques'
                  : 'Visible 24 h par tes amis. Lecture illimitée.',
            ),
            value: _publishStory,
            onChanged: (v) => setState(() => _publishStory = v),
          ),
          const Divider(),
          // Envoi direct : plus de liste, le destinataire est celui du chat.
          if (_direct)
            const Spacer()
          else
            Expanded(
              child: connections.isEmpty
                  ? Center(
                      child: Text(
                        'Aucune connexion à qui envoyer.',
                        style: TextStyle(color: context.muted),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final connection in connections)
                          _RecipientTile(
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
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: _loading ? null : _send,
                child: _loading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _direct
                            ? 'Envoyer à ${widget.directRecipientLabel ?? 'ce chat'}'
                            : 'Envoyer',
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau du basculement automatique en One of One (2026-08-10).
///
/// L'utilisateur n'a rien choisi : c'est la forme de son envoi qui a décidé.
/// Le bandeau dit donc la conséquence ET la manière d'en sortir — sans quoi
/// le passage de la pastille au doré resterait une surprise.
class _OneOfOneBanner extends StatelessWidget {
  const _OneOfOneBanner();

  static const _gold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: 0.10),
        border: Border.all(color: _gold.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.workspace_premium, color: _gold, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'One of One',
                  style: TextStyle(
                    color: _gold,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Un seul destinataire et aucune publication : cette Vibe '
                  'devient exclusive, pour elle seule et à jamais. Ajoute '
                  'quelqu\'un, publie-la ou mets-la en story pour revenir à '
                  'une Vibe normale.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipientTile extends ConsumerWidget {
  const _RecipientTile({
    required this.peerId,
    required this.selected,
    required this.onChanged,
  });
  final String peerId;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByIdProvider(peerId)).value;
    return CheckboxListTile(
      value: selected,
      onChanged: (v) => onChanged(v ?? false),
      title: Text(profile?.displayName ?? '…'),
      secondary: Avatar(
        stored: profile?.avatarUrl,
        fallback: Text(
          (profile?.displayName ?? '?').characters.first.toUpperCase(),
        ),
      ),
    );
  }
}
