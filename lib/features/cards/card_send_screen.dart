import 'dart:io';

import 'package:flutter/material.dart';
import '../../core/widgets/avatar.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/card.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import '../conversations/conversations_repository.dart';
import '../library_vibes/library_vibes_repository.dart';
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

/// Les contextes de diffusion, **mutuellement exclusifs** depuis la refonte du
/// 2026-08-11.
///
/// C'est LA décision de fond du chantier : un contenu part dans **un seul**
/// contexte, et n'en change jamais. Avant, une même Vibe pouvait être envoyée
/// en DM, publiée en bibliothèque ET mise en story — trois régimes d'accès
/// contradictoires sur un seul fichier, d'où un compteur de vues partagé entre
/// le chat et la story, et une suppression qui en emportait deux autres.
///
/// Cela n'empêche pas un contenu de circuler : une story publiée peut ensuite
/// être **repartagée** dans une conversation. Mais un repartage est un
/// raccourci vers la source, jamais une copie.
enum _Destination {
  story,
  publication,
  circle,
  conversationLibrary;

  String get label => switch (this) {
    _Destination.story => 'Story',
    _Destination.publication => 'Bibliothèque',
    _Destination.circle => 'Cercle',
    _Destination.conversationLibrary => 'Bibliothèque de conv.',
  };

  IconData get icon => switch (this) {
    _Destination.story => Icons.auto_awesome,
    _Destination.publication => Icons.grid_view,
    _Destination.circle => Icons.send,
    _Destination.conversationLibrary => Icons.lock_clock,
  };
}

class _CardSendScreenState extends ConsumerState<CardSendScreen> {
  final _selected = <String>{};

  /// Destination unique. Par défaut le cercle : c'est le geste le plus courant
  /// et le seul disponible en envoi direct.
  var _destination = _Destination.circle;

  /// Envoi direct : le destinataire vient du chat d'où la capture a été
  /// ouverte, il n'y a rien à choisir.
  bool get _direct => widget.directRecipientIds != null;

  /// Publication PUBLIQUE : un rang au-dessus de « connexions » — visible par
  /// toute personne accédant au profil par un moyen légitime.
  var _publishPublic = false;
  var _loading = false;

  /// Les destinataires pourront l'enregistrer dans leurs Enregistrements.
  var _saveable = false;

  /// Copie privée dans MES Enregistrements (bibliothèque privée).
  var _saveForMe = false;

  /// Story : l'auteur autorise la propagation de cercle en cercle, sans limite
  /// de sauts (décision de Jay 2026-08-11). **Faux par défaut** — le partage
  /// hors cercle est un acte délibéré, repris à chaque publication ; il n'y a
  /// volontairement pas de réglage global « compte public ».
  var _shareable = false;

  /// Bibliothèque de conversation : laquelle.
  String? _libraryConversationId;

  /// Vues par card (1-5). Initialisé depuis les réglages.
  late int _maxViews = ref.read(defaultMaxViewsProvider);

  /// Durée de lecture : 1-20 s ; 21 = illimitée. Initialisé depuis les réglages.
  late int _durationSlider = _fromPref(ref.read(defaultViewDurationProvider));

  static int _fromPref(int pref) =>
      pref == DefaultViewDuration.unlimited ? 21 : pref;

  /// Le destinataire peut contrôler la barre de lecture des vidéos
  /// (défaut : intouchable — consigne Jay).
  var _scrubbable = false;

  /// La Card est-elle, EN L'ÉTAT, une One of One ?
  ///
  /// Condition arrêtée par Jay le 2026-08-10 : un seul destinataire et aucune
  /// publication. Depuis que les destinations sont **exclusives**
  /// (2026-08-11), la seconde moitié de la condition est acquise dès qu'on est
  /// sur le cercle — il ne reste qu'à compter les destinataires. « Enregistrer
  /// pour moi » ne compte pas : c'est une copie privée, elle ne diffuse rien.
  ///
  /// Le **BeReal en est exclu** : c'est un format à identité propre (l'instant
  /// imposé du jour), le repeindre en or effacerait ce qu'il raconte.
  bool get _isOneOfOne =>
      widget.type != CardType.bereal &&
      _destination == _Destination.circle &&
      _selected.length == 1;

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

  /// Ce qui manque pour pouvoir envoyer, ou null si tout est prêt.
  String? get _blocker => switch (_destination) {
    _Destination.circle when _selected.isEmpty =>
      'Choisis au moins un destinataire.',
    _Destination.conversationLibrary when _libraryConversationId == null =>
      'Choisis la conversation dont tu veux garnir la bibliothèque.',
    _ => null,
  };

  Future<void> _send() async {
    final blocker = _blocker;
    if (blocker != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(blocker)));
      return;
    }
    setState(() => _loading = true);
    try {
      // Un contexte, un chemin. Aucune branche ne peut en déclencher une
      // autre : c'est ce qui garantit qu'un média n'existe que dans un seul
      // bucket, avec un seul cycle de vie.
      switch (_destination) {
        case _Destination.story:
          await _publishStory();
        case _Destination.publication:
          await _publishToLibrary();
        case _Destination.circle:
          await _sendToCircle();
        case _Destination.conversationLibrary:
          await _addToConversationLibrary();
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
        ).showSnackBar(SnackBar(content: Text(_successMessage)));
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

  String get _successMessage => switch (_destination) {
    _Destination.story => 'Story publiée ✓',
    _Destination.publication => 'Publiée dans ta bibliothèque ✓',
    _Destination.circle => 'Vibe envoyée ✓',
    _Destination.conversationLibrary => 'Ajoutée à la bibliothèque ✓',
  };

  /// Story : aucune Card n'est créée. Le média part **directement** dans le
  /// bucket `stories`, avec son propre Content ID et sa propre règle d'accès.
  /// Ni limite de vues, ni durée de lecture : elles n'ont pas de sens ici, et
  /// c'est précisément ce que la séparation des formats a permis de supprimer.
  Future<void> _publishStory() async {
    await ref
        .read(storiesRepositoryProvider)
        .publish(
          front: widget.front,
          back: widget.back,
          type: widget.type,
          frontIsVideo: widget.frontIsVideo,
          backIsVideo: widget.backIsVideo,
          shareable: _shareable,
        );
  }

  /// Publication en bibliothèque de profil. Permanente — décision de Jay
  /// (2026-08-11) : « c'est ce qui a toujours été décidé ».
  ///
  /// ⚠️ Passe encore par `cards` + `library_items` : l'autonomisation de la
  /// publication est l'étape 2 de la refonte. La destination est déjà
  /// EXCLUSIVE côté produit — seul le stockage reste à séparer.
  Future<void> _publishToLibrary() async {
    final repo = ref.read(cardsRepositoryProvider);
    final card = await repo.create(
      front: widget.front,
      back: widget.back,
      type: widget.type,
      // En bibliothèque, la lecture est illimitée : ni budget de vues, ni
      // durée. Les passer serait écrire une règle que personne n'applique.
      viewDurationSeconds: null,
      maxViews: null,
      saveable: _saveable,
      imported: widget.imported,
      frontIsVideo: widget.frontIsVideo,
      backIsVideo: widget.backIsVideo,
      scrubbable: _hasVideo && _scrubbable,
    );
    await repo.publishToLibrary(card, isPublic: _publishPublic);
    if (_saveForMe) await repo.saveCard(card.id);
  }

  /// Partage direct dans le cercle (DM et groupes) : le seul contexte où les
  /// limites de vues et de durée s'appliquent, et le seul jamais repartageable.
  Future<void> _sendToCircle() async {
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
    await repo.send(card, _selected.toList());
    if (_saveForMe) await repo.saveCard(card.id);
  }

  /// Bibliothèque éphémère de conversation — quatrième contexte, déjà autonome
  /// depuis le 2026-08-10 (bucket `library_vault`, aucun original en clair).
  Future<void> _addToConversationLibrary() async {
    await ref
        .read(libraryVibesRepositoryProvider)
        .addVibe(
          conversationId: _libraryConversationId!,
          type: widget.type,
          source: widget.front,
          isVideo: widget.frontIsVideo,
          back: widget.back,
          backIsVideo: widget.backIsVideo,
          saveableByOthers: _saveable,
        );
  }

  /// Cette destination est-elle ouverte à CETTE capture ?
  ///
  /// Seule la bibliothèque de conversation refuse quelque chose, et pour deux
  /// règles déjà arrêtées par Jay le 2026-08-10 : **pas d'import galerie**
  /// (« de vraies photos ou vidéos ») et **pas de BeReal**. Les faire respecter
  /// ici plutôt que d'ouvrir la porte puis d'échouer à l'envoi.
  bool _allows(_Destination destination) {
    if (destination != _Destination.conversationLibrary) return true;
    return !widget.imported && widget.type != CardType.bereal;
  }

  /// Ce que la destination choisie implique, en une phrase. Sans elle, le choix
  /// exclusif serait une contrainte sans explication.
  String get _destinationHint {
    final storiesPublic =
        ref.watch(myProfileProvider).value?.storiesPublic ?? false;
    return switch (_destination) {
      _Destination.story =>
        storiesPublic
            ? '24 h, sans limite de vues. Visible par tes amis ET par les '
                  'personnes que tu croises — tes stories sont publiques.'
            : '24 h, sans limite de vues, visible par tes amis.',
      _Destination.publication =>
        'Elle reste dans ta bibliothèque, sans limite de vues ni de durée.',
      _Destination.circle =>
        'Le seul envoi où les limites de vues et de durée s\'appliquent. '
            'Jamais repartageable.',
      _Destination.conversationLibrary =>
        _allows(_Destination.conversationLibrary)
            ? 'Masquée pour tous, toi compris, jusqu\'au reveal de 18h30.'
            : 'Indisponible ici : une bibliothèque n\'accepte ni import '
                  'galerie ni BeReal.',
    };
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
    // Le type suit la destination : passer du cercle à une publication fait
    // retomber la Vibe du One of One vers son type de capture, en direct.
    final type = _effectiveType;

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

          // ─── LE CHOIX EXCLUSIF ────────────────────────────────────────
          // Un contenu, un format. C'est la décision de fond du chantier du
          // 2026-08-11 : ces options ne se cumulent plus. Chacune a ses
          // propres règles d'accès, son propre stockage et son propre cycle
          // de vie — les mélanger revenait à écrire trois règles
          // contradictoires sur un seul fichier.
          //
          // En envoi direct il n'y a rien à choisir : la capture vient d'un
          // chat, elle y retourne.
          if (!_direct)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: SegmentedButton<_Destination>(
                segments: [
                  for (final d in _Destination.values)
                    ButtonSegment(
                      value: d,
                      icon: Icon(d.icon, size: 18),
                      label: Text(
                        d.label,
                        style: const TextStyle(fontSize: 11),
                      ),
                      enabled: _allows(d),
                    ),
                ],
                selected: {_destination},
                showSelectedIcon: false,
                onSelectionChanged: (values) =>
                    setState(() => _destination = values.first),
              ),
            ),
          if (!_direct)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                _destinationHint,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: context.muted),
              ),
            ),

          // ─── Options du CERCLE : les seules limites de l'app ───────────
          // Vues et durée n'existent que dans le partage direct. Une story ou
          // une publication n'en a pas : c'est la séparation des formats qui
          // a rendu cette phrase possible.
          if (_destination == _Destination.circle) ...[
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
          ],

          if (_hasVideo && _destination != _Destination.story)
            SwitchListTile(
              title: const Text('Barre de lecture contrôlable'),
              subtitle: const Text(
                'Désactivé : le destinataire voit la progression mais ne '
                'peut pas se déplacer dans la vidéo',
              ),
              value: _scrubbable,
              onChanged: (v) => setState(() => _scrubbable = v),
            ),

          // ─── Options de la STORY ───────────────────────────────────────
          if (_destination == _Destination.story)
            SwitchListTile(
              title: const Text('Partageable'),
              subtitle: Text(
                _shareable
                    ? 'Ceux qui la voient pourront la relayer à leurs amis, '
                          'qui pourront la relayer à leur tour — elle peut '
                          'sortir de ton cercle.'
                    : 'Elle reste dans ton cercle : personne ne peut la '
                          'relayer ailleurs.',
              ),
              value: _shareable,
              onChanged: (v) => setState(() => _shareable = v),
            ),

          // ─── Options de la PUBLICATION ─────────────────────────────────
          if (_destination == _Destination.publication)
            SwitchListTile(
              title: const Text('Publication publique'),
              subtitle: const Text(
                'Visible par toute personne qui accède à ton profil '
                '(croisements ping compris) — tag « Public » affiché',
              ),
              value: _publishPublic,
              onChanged: (v) => setState(() => _publishPublic = v),
            ),

          // ─── Options de la BIBLIOTHÈQUE DE CONVERSATION ────────────────
          if (_destination == _Destination.conversationLibrary)
            _ConversationTarget(
              selected: _libraryConversationId,
              onChanged: (id) => setState(() => _libraryConversationId = id),
            ),

          // Une One of One n'est jamais enregistrable par son destinataire :
          // l'interrupteur reste visible mais inerte, pour que la règle se
          // lise au lieu de disparaître sans explication.
          if (_destination != _Destination.story)
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
          //
          // Absent de la story et de la bibliothèque de conversation : les
          // Enregistrements référencent la table `cards`, et ces deux
          // contextes n'en créent aucune. La sauvegarde locale de l'étape 5
          // lèvera cette restriction.
          if (_destination == _Destination.circle ||
              _destination == _Destination.publication)
            SwitchListTile(
              title: const Text('Enregistrer pour moi'),
              subtitle: const Text(
                'Copie privée dans mes Enregistrements, visible de moi seul',
              ),
              value: _saveForMe,
              onChanged: (v) => setState(() => _saveForMe = v),
            ),

          const Divider(),
          // Les destinataires ne se choisissent que pour le cercle : une story
          // s'adresse à une audience, pas à des personnes nommées.
          if (_direct || _destination != _Destination.circle)
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

/// Choix de la conversation dont on garnit la bibliothèque éphémère.
class _ConversationTarget extends ConsumerWidget {
  const _ConversationTarget({required this.selected, required this.onChanged});

  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider) ?? '';
    final conversations = ref.watch(conversationsProvider);
    return conversations.when(
      loading: () => const ListTile(
        dense: true,
        title: Text('Chargement des conversations…'),
      ),
      error: (e, _) => ListTile(dense: true, title: Text('Erreur : $e')),
      data: (list) => list.isEmpty
          ? const ListTile(
              dense: true,
              title: Text('Aucune conversation.'),
              subtitle: Text(
                'Une bibliothèque appartient à une conversation existante.',
              ),
            )
          : ListTile(
              dense: true,
              leading: const Icon(Icons.forum_outlined),
              title: DropdownButton<String>(
                isExpanded: true,
                value: selected,
                hint: const Text('Choisir la conversation'),
                underline: const SizedBox.shrink(),
                items: [
                  for (final conv in list)
                    DropdownMenuItem(
                      value: conv.id,
                      child: Text(
                        conv.displayName(me),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: onChanged,
              ),
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
