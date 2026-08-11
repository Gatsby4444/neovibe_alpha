import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/widgets/avatar.dart';
import '../../core/models/card.dart';
import '../../core/models/connection.dart';
import '../../core/models/message.dart';
import '../stories/story_viewer_screen.dart';
import '../library/publication_viewer_screen.dart';
import '../library/mini_card.dart';
import '../../core/widgets/card_type_badge.dart';
import '../../core/models/story.dart';
import '../../core/content/shared_content.dart';
import '../../core/content/content_face.dart';
import '../../core/supabase_providers.dart';
import '../../core/prefs.dart';
import '../../core/theme.dart';
import '../../core/utils/formats.dart';
import '../cards/card_capture_screen.dart';
import '../cards/card_viewer_screen.dart';
import '../cards/cards_repository.dart';
import '../library_vibes/conversation_library_screen.dart';
import '../library_vibes/library_target.dart';
import '../connections/connections_repository.dart';
import '../library/user_library_screen.dart';
import 'video_player_screen.dart';
import '../proximity/proximity_service.dart';
import 'conversations_repository.dart';
import 'group_settings_screen.dart';

/// Détail d'une conversation (métadonnées + membres).
final conversationDetailProvider = FutureProvider.family<Conversation, String>((
  ref,
  id,
) async {
  final row = await ref
      .watch(supabaseProvider)
      .from('conversations')
      .select('*, members:conversation_members(profiles(*))')
      .eq('id', id)
      .single();
  return Conversation.fromJson(row);
});

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  RealtimeChannel? _typingChannel;
  Timer? _typingReset;
  String? _typingName;
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _setupTypingChannel();
  }

  void _setupTypingChannel() {
    final client = ref.read(supabaseProvider);
    final me = client.auth.currentUser!.id;
    _typingChannel = client.channel('typing:${widget.conversationId}')
      ..onBroadcast(
        event: 'typing',
        callback: (payload) {
          final sender = payload['user_id'] as String?;
          if (sender == me) return;
          setState(() => _typingName = payload['name'] as String?);
          _typingReset?.cancel();
          _typingReset = Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _typingName = null);
          });
        },
      )
      ..subscribe();
  }

  void _notifyTyping() {
    // Sobriété : un signal toutes les 3 s maximum
    if (DateTime.now().difference(_lastTypingSent).inSeconds < 3) return;
    _lastTypingSent = DateTime.now();
    final me = ref.read(supabaseProvider).auth.currentUser!.id;
    final myProfile = ref.read(myProfileProvider).value;
    _typingChannel?.sendBroadcastMessage(
      event: 'typing',
      payload: {'user_id': me, 'name': myProfile?.chatName ?? ''},
    );
  }

  @override
  void dispose() {
    _typingReset?.cancel();
    _typingChannel?.unsubscribe();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    final body = _input.text.trim();
    if (body.isEmpty) return;
    _input.clear();
    try {
      await ref
          .read(conversationsRepositoryProvider)
          .sendText(widget.conversationId, body);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
      }
    }
  }

  // `_sendMedia` (photo/vidéo brutes via le sélecteur système) a été SUPPRIMÉ
  // le 2026-08-01 avec les deux boutons caméra : dans un chat, on envoie une
  // Card, pas un média nu. Les messages image/vidéo déjà en base continuent de
  // s'afficher (`_MediaPreview`), et le canal reste ouvert côté dépôt
  // (`sendMedia`) — seule l'entrée depuis l'interface a disparu.

  /// Bouton Card du chat (consigne Jay 2026-08-01) : ouvre la vraie interface
  /// de capture, puis un écran d'envoi réduit — destinataires imposés (le pair
  /// en DM, tous les autres membres en groupe), pas de choix de liste, pas de
  /// publication en bibliothèque. Seule option en plus : garder une copie dans
  /// ses Enregistrements.
  void _sendCard(Conversation conversation, String me) {
    final recipients = conversation.members
        .where((m) => m.id != me)
        .map((m) => m.id)
        .toList();
    if (recipients.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CardCaptureScreen(
          directRecipientIds: recipients,
          directRecipientLabel: conversation.displayName(me),
        ),
      ),
    );
  }

  /// Bouton « plus » de la barre de saisie : alimente la **bibliothèque
  /// éphémère** de la conversation au lieu d'envoyer (chantier Jay 2026-08-10).
  /// La capture bascule alors en mode sans aperçu.
  void _addToLibrary(Conversation conversation, String me) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CardCaptureScreen(
          libraryTarget: LibraryTarget(
            conversationId: conversation.id,
            label: conversation.displayName(me),
            isGroup: conversation.type == ConversationType.group,
          ),
        ),
      ),
    );
  }

  void _openLibrary(Conversation conversation, String me) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConversationLibraryScreen(
          conversationId: conversation.id,
          title: conversation.displayName(me),
        ),
      ),
    );
  }

  String _friendlyError(Object e) {
    final text = e.toString();
    if (text.contains('Limite de 3 messages')) {
      return 'Limite anti-spam : 3 messages sans réponse. '
          'Tu pourras réécrire dès que l\'autre te répond.';
    }
    if (text.contains('texte')) {
      return 'Le canal de proximité est limité au texte.';
    }
    return 'Envoi impossible : $text';
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final detail = ref.watch(conversationDetailProvider(widget.conversationId));
    final messages = ref.watch(messagesStreamProvider(widget.conversationId));

    // Marque comme lus les messages reçus dès qu'ils arrivent à l'écran
    ref.listen(messagesStreamProvider(widget.conversationId), (_, next) {
      final list = next.value;
      if (list != null && list.isNotEmpty) {
        ref.read(conversationsRepositoryProvider).markRead(list);
      }
    });

    final conversation = detail.value;
    final isProximity = conversation?.type == ConversationType.proximity;
    final isGroup = conversation?.type == ConversationType.group;
    final peer = conversation?.otherMember(me);

    // Lien partiel éventuel avec ce pair (canal proximité)
    final partials = ref.watch(partialConnectionsProvider);
    final partial = peer == null
        ? null
        : partials.where((c) => c.peerIdFor(me) == peer.id).firstOrNull;

    // Canal proximité : visible uniquement en portée BLE, sauf lien établi.
    // NB : depuis le chantier BLE (2026-07-13), les conversations ping sont
    // 100 % locales (PingChatScreen) — ce canal serveur ne subsiste que pour
    // les conversations prox héritées, il n'en est plus créé de nouvelles.
    final proximity = ref.watch(proximityServiceProvider);
    final outOfRange =
        isProximity &&
        peer != null &&
        partial == null &&
        !proximity.nearby.containsKey(peer.id);

    return Scaffold(
      appBar: AppBar(
        // En-tête façon iMessage (demande de Jay 2026-08-10) : flèche de
        // retour à gauche, **photo de profil CENTRÉE** avec le pseudo dessous,
        // et un bouton d'action à droite. L'ensemble du bloc central reste
        // cliquable et mène au profil (consigne Jay 2026-08-01).
        centerTitle: true,
        toolbarHeight: 74,
        titleSpacing: 0,
        title: isGroup || peer == null
            ? _GroupTitle(name: conversation?.displayName(me) ?? '…')
            : _PeerTitle(peerId: peer.id),
        actions: [
          // Bibliothèque éphémère de la conversation (chantier Jay
          // 2026-08-10). Ajoutée SANS retirer le bouton voisin : le wave et le
          // détail du groupe restent là où Jay les a placés.
          // Exclue du canal de proximité, limité au texte côté serveur.
          if (!isProximity && conversation != null)
            IconButton(
              icon: const Icon(Icons.collections_outlined),
              tooltip: 'Bibliothèque de la conversation',
              onPressed: () => _openLibrary(conversation, me),
            ),
          if (isGroup)
            IconButton(
              icon: const Icon(Icons.group_outlined),
              tooltip: 'Détail du groupe',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupSettingsScreen(
                    conversationId: widget.conversationId,
                  ),
                ),
              ),
            )
          else
            // Pendant du bouton FaceTime d'iMessage. Jay : « si tu ne sais pas
            // quoi mettre pour un bouton, designe le bouton et plus tard on
            // discute de l'action ». Le wave est la mécanique NeoVibe la plus
            // proche d'un geste direct vers quelqu'un — l'action reste À
            // DÉFINIR.
            IconButton(
              icon: const Icon(Icons.waving_hand_outlined),
              tooltip: 'Action à définir',
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Bouton en place — son action reste à définir.',
                  ),
                ),
              ),
            ),
        ],
        bottom: isProximity
            ? PreferredSize(
                preferredSize: const Size.fromHeight(26),
                child: Container(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Canal de proximité — texte uniquement, 3 messages max sans réponse',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              )
            : null,
      ),
      body: Column(
        children: [
          if (partial != null) _PartialBanner(partial: partial, me: me),
          if (outOfRange)
            Container(
              width: double.infinity,
              color: Colors.orange.withValues(alpha: 0.15),
              padding: const EdgeInsets.all(10),
              child: const Text(
                'Hors de portée — ce canal se fermera sans échange mutuel.',
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Erreur : $e')),
              data: (list) => ListView.builder(
                controller: _scroll,
                reverse: true,
                padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final i = list.length - 1 - index;
                  final message = list[i];
                  // Regroupement façon iMessage : les messages consécutifs
                  // d'un même auteur, à moins de 5 min d'écart, forment un
                  // bloc. Seul le DERNIER du bloc porte le coin coupé et
                  // l'heure — c'est ce qui donne le rythme visuel d'iMessage
                  // au lieu d'une liste de pavés identiques.
                  final previous = i > 0 ? list[i - 1] : null;
                  final next = i + 1 < list.length ? list[i + 1] : null;
                  return _MessageBubble(
                    message: message,
                    isMine: message.senderId == me,
                    isFirstOfGroup: !_sameGroup(previous, message),
                    isLastOfGroup: !_sameGroup(message, next),
                    showSenderName: isGroup,
                  );
                },
              ),
            ),
          ),
          if (_typingName != null)
            Padding(
              padding: const EdgeInsets.only(left: 20, bottom: 6),
              child: Row(
                children: [
                  Text(
                    '$_typingName est en train d\'écrire…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          _Composer(
            controller: _input,
            onChanged: _notifyTyping,
            onSend: _sendText,
            // Le canal de proximité est limité au texte : ni Card, ni pièce
            // jointe (règle serveur, pas un choix d'écran).
            onCard: isProximity || conversation == null
                ? null
                : () => _sendCard(conversation, me),
            onLibrary: isProximity || conversation == null
                ? null
                : () => _addToLibrary(conversation, me),
          ),
        ],
      ),
    );
  }
}

/// Deux messages appartiennent-ils au même bloc visuel ? Même auteur et moins
/// de 5 minutes d'écart — la règle de regroupement d'iMessage.
bool _sameGroup(Message? a, Message? b) {
  if (a == null || b == null) return false;
  if (a.senderId != b.senderId) return false;
  return b.createdAt.difference(a.createdAt).inMinutes.abs() < 5;
}

/// Barre de saisie façon iMessage (demande de Jay 2026-08-10) : **deux boutons
/// à gauche**, puis un champ en gélule, et le bouton d'envoi qui apparaît
/// DANS le champ dès qu'il y a du texte.
///
/// La rangée d'icônes visible sous le champ sur la capture d'écran appartient
/// au clavier iOS : elle n'est volontairement pas reproduite.
class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.onChanged,
    required this.onSend,
    required this.onCard,
    required this.onLibrary,
  });

  final TextEditingController controller;
  final VoidCallback onChanged;
  final VoidCallback onSend;

  /// Null = canal texte seul (proximité) : le bouton Vibe disparaît.
  final VoidCallback? onCard;

  /// Ajout à la **bibliothèque éphémère** de la conversation — l'action du
  /// bouton « plus », restée à définir jusqu'au 2026-08-10.
  final VoidCallback? onLibrary;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  /// Le bouton d'envoi n'apparaît qu'avec du texte : il faut donc se
  /// reconstruire à la frappe, pas seulement prévenir le canal « écrit… ».
  void _onText() => setState(() {});

  void _handleChanged() {
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasText = widget.controller.text.trim().isNotEmpty;
    final fieldColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : const Color(0xFFD3D1DB);
    final iconColor = isDark ? Colors.white70 : const Color(0xFF6E6A7A);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 10, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Bouton 1 — la Card. Depuis le 2026-08-01, c'est la SEULE entrée
            // média du chat : on envoie une Card, pas un média nu.
            if (widget.onCard != null)
              IconButton(
                icon: const Icon(Icons.photo_camera_outlined),
                color: iconColor,
                tooltip: 'Envoyer une Vibe',
                onPressed: widget.onCard,
              ),
            // Bouton 2 — pendant du bouton « apps » d'iMessage. Dessiné le
            // 2026-08-01 sans action ; depuis le 2026-08-10 il alimente la
            // **bibliothèque éphémère** de la conversation.
            if (widget.onLibrary != null)
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                color: iconColor,
                tooltip: 'Ajouter à la bibliothèque',
                onPressed: widget.onLibrary,
              ),
            const SizedBox(width: 2),
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 38),
                decoration: BoxDecoration(
                  color: fieldColor,
                  border: Border.all(color: borderColor),
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.only(left: 14, right: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        onChanged: (_) => _handleChanged(),
                        onSubmitted: (_) => widget.onSend(),
                        textInputAction: TextInputAction.send,
                        minLines: 1,
                        maxLines: 5,
                        style: const TextStyle(fontSize: 16),
                        decoration: InputDecoration(
                          hintText: 'Message éphémère (24 h)…',
                          hintStyle: TextStyle(color: iconColor, fontSize: 16),
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 9,
                          ),
                        ),
                      ),
                    ),
                    // Flèche d'envoi DANS la gélule, comme iMessage : elle
                    // n'existe que s'il y a quelque chose à envoyer.
                    AnimatedScale(
                      scale: hasText ? 1 : 0,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutBack,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: _SendButton(onPressed: widget.onSend),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bouton d'envoi rond, au dégradé de marque — l'équivalent NeoVibe de la
/// flèche bleue d'iMessage.
class _SendButton extends StatelessWidget {
  const _SendButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: const BoxDecoration(
            gradient: NeoGradients.brandButton,
            shape: BoxShape.circle,
          ),
          child: InkWell(
            onTap: onPressed,
            child: const Icon(
              Icons.arrow_upward_rounded,
              size: 19,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bandeau de lien partiel : 3 jours pour confirmer des deux côtés (spec 4.4).
class _PartialBanner extends ConsumerWidget {
  const _PartialBanner({required this.partial, required this.me});
  final Connection partial;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final confirmed = partial.confirmedBy(me);
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          Text(
            'Lien partiel — expire dans ${remaining(partial.partialExpiresAt!)}. '
            'Confirmez tous les deux pour devenir de vraies connexions.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          confirmed
              ? const Text('✓ Tu as confirmé — en attente de l\'autre')
              : FilledButton.tonal(
                  onPressed: () => ref
                      .read(connectionsRepositoryProvider)
                      .confirmPartial(partial.id),
                  child: const Text('Confirmer la connexion'),
                ),
        ],
      ),
    );
  }
}

/// Titre d'un DM, façon iMessage (2026-08-10) : photo de profil **au-dessus**
/// du pseudo, le tout centré et cliquable, menant au profil du pair (consigne
/// Jay 2026-08-01 — « on n'affiche pas uniquement le pseudo mais aussi sa
/// photo de profil, et le tout est cliquable »).
class _PeerTitle extends ConsumerWidget {
  const _PeerTitle({required this.peerId});
  final String peerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByIdProvider(peerId)).value;
    final name = profile?.chatName ?? '…';
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: profile == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => UserLibraryScreen(profile: profile),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Avatar(
              radius: 19,
              stored: profile?.avatarUrl,
              fallback: Text(
                name.characters.first.toUpperCase(),
                style: const TextStyle(fontSize: 15),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

/// Même composition pour un groupe : pastille de groupe au-dessus du nom.
class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 19,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.group, size: 20),
        ),
        const SizedBox(height: 3),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

/// Bulle de message façon iMessage (refonte du 2026-08-10).
///
/// - **Mes messages** portent le dégradé de marque et vont à droite ; ceux des
///   autres prennent un gris de surface et vont à gauche.
/// - Le **coin bas côté auteur** n'est coupé que sur le DERNIER message d'un
///   bloc : c'est ce détail qui fait lire une suite de messages comme une
///   seule prise de parole.
/// - L'**heure** ne s'affiche qu'en fin de bloc, sous la bulle et hors d'elle
///   — pas une étiquette sous chaque message.
/// - Une **Card ou un média** n'est jamais mis en bulle : le container de Card
///   porte déjà sa propre couleur de type, l'empiler dans un dégradé de marque
///   rendrait les deux illisibles.
class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.isFirstOfGroup,
    required this.isLastOfGroup,
    required this.showSenderName,
  });

  final Message message;
  final bool isMine;
  final bool isFirstOfGroup;
  final bool isLastOfGroup;

  /// En groupe seulement : le pseudo de l'auteur, au-dessus de son bloc.
  final bool showSenderName;

  static const _radius = Radius.circular(19);
  static const _tightRadius = Radius.circular(6);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Annonce d'ajout à la bibliothèque : ligne système discrète et centrée,
    // jamais une bulle — elle n'appartient à personne dans le fil, elle
    // signale un événement (consigne Jay 2026-08-10 : l'annonce est NOMMÉE).
    if (message.kind == MessageKind.libraryAdd) {
      final author = ref.watch(profileByIdProvider(message.senderId)).value;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_clock_outlined, size: 13, color: context.faint),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${isMine ? 'Tu as' : '${author?.displayName ?? 'Quelqu\'un'} a'} '
                'ajouté une vibe — 18h30',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.faint,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final isAttachment = message.kind != MessageKind.text;
    final senderProfile = isMine || !showSenderName
        ? null
        : ref.watch(profileByIdProvider(message.senderId)).value;

    final Widget content = switch (message.kind) {
      MessageKind.text => Text(
        message.body ?? '',
        style: TextStyle(
          fontSize: 16,
          height: 1.28,
          color: isMine ? Colors.white : theme.colorScheme.onSurface,
        ),
      ),
      MessageKind.image || MessageKind.video => _MediaPreview(message: message),
      MessageKind.card => _CardContainer(message: message),
      MessageKind.contentShare => _SharedContentTile(message: message),
      // Traité en amont par un retour anticipé — jamais atteint.
      MessageKind.libraryAdd => const SizedBox.shrink(),
    };

    return Padding(
      padding: EdgeInsets.only(
        top: isFirstOfGroup ? 8 : 2,
        bottom: isLastOfGroup ? 2 : 0,
      ),
      child: Column(
        crossAxisAlignment: isMine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (senderProfile != null && isFirstOfGroup)
            Padding(
              padding: const EdgeInsets.only(left: 14, bottom: 3),
              child: Text(
                senderProfile.chatName,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.76,
            ),
            child: isAttachment
                ? content
                : DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: isMine ? NeoGradients.brandButton : null,
                      color: isMine
                          ? null
                          : (isDark
                                ? const Color(0xFF26242F)
                                : const Color(0xFFE9E7EF)),
                      borderRadius: BorderRadius.only(
                        topLeft: _radius,
                        topRight: _radius,
                        bottomLeft: !isMine && isLastOfGroup
                            ? _tightRadius
                            : _radius,
                        bottomRight: isMine && isLastOfGroup
                            ? _tightRadius
                            : _radius,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      child: content,
                    ),
                  ),
          ),
          if (isLastOfGroup)
            Padding(
              padding: EdgeInsets.only(
                top: 3,
                left: isMine ? 0 : 12,
                right: isMine ? 6 : 0,
              ),
              child: Text(
                // « disparaît dans … » retiré de l'affichage courant le
                // 2026-08-01 (consigne Jay) : l'éphémère est une règle du
                // produit, pas un chronomètre à surveiller sous chaque
                // message. Conservé derrière l'interrupteur développeur pour
                // vérifier le TTL en test.
                ref.watch(devShowExpiryProvider)
                    ? '${shortTime(message.createdAt)} · disparaît dans ${remaining(message.expiresAt)}'
                    : shortTime(message.createdAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MediaPreview extends ConsumerWidget {
  const _MediaPreview({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (message.mediaPath == null) return const Text('[média]');
    final url = ref.watch(_mediaUrlProvider(message.mediaPath!));
    return url.when(
      loading: () => const SizedBox(
        height: 120,
        width: 120,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => const Text('[média indisponible]'),
      data: (link) => message.kind == MessageKind.image
          ? ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                link,
                height: 220,
                fit: BoxFit.cover,
                width: 220,
              ),
            )
          : _InlineVideo(url: link),
    );
  }
}

final _mediaUrlProvider = FutureProvider.family<String, String>(
  (ref, path) => ref
      .watch(supabaseProvider)
      .storage
      .from('media')
      .createSignedUrl(path, 3600),
);

class _InlineVideo extends StatelessWidget {
  const _InlineVideo({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.play_circle),
      label: const Text('Vidéo'),
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => VideoPlayerScreen(url: url))),
    );
  }
}

/// Ma livraison pour une card (état du container côté destinataire).
final _myDeliveryProvider = FutureProvider.family<CardDelivery?, String>(
  (ref, cardId) => ref.watch(cardsRepositoryProvider).myDelivery(cardId),
);

/// Container de Card dans le chat, façon Snapchat (consigne Jay 2026-07-12) :
/// JAMAIS d'aperçu — un bloc cliquable à la couleur du type, avec son tag et
/// son état (nouvelle / rouvrable / épuisée / détruite). Le container vit 24 h
/// (TTL du message). Le créateur peut rouvrir sa card tant que le container
/// existe.
class _CardContainer extends ConsumerWidget {
  const _CardContainer({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card =
        message.card ??
        (message.cardId == null
            ? null
            : ref.watch(_cardProvider(message.cardId!)).value);
    if (card == null) {
      return Text(
        '[Vibe expirée]',
        style: TextStyle(fontStyle: FontStyle.italic, color: context.faint),
      );
    }
    final isMine = card.ownerId == ref.watch(currentUserIdProvider);
    // Émetteur : demandes de replay en attente sur cette card
    final pendingReplays = isMine
        ? (ref.watch(pendingReplayForCardProvider(card.id)).value ??
              <CardDelivery>[])
        : <CardDelivery>[];
    final delivery = isMine
        ? null
        : ref.watch(_myDeliveryProvider(card.id)).value;

    // État du container
    final String stateLabel;
    var blocked = false;
    var unopened = false;
    if (isMine) {
      stateLabel = 'Ta Vibe — rouvrir';
    } else if (delivery == null) {
      stateLabel = 'Appuie pour ouvrir';
      unopened = true;
    } else if (delivery.destroyedAt != null) {
      stateLabel = 'Détruite';
      blocked = true;
    } else {
      final remaining = delivery.remainingViews(card);
      if (delivery.firstViewedAt == null) {
        stateLabel = 'Nouvelle — appuie pour ouvrir';
        unopened = true;
      } else if (remaining != null && remaining <= 0) {
        stateLabel = 'Épuisée';
      } else {
        stateLabel = remaining == null
            ? 'Rouvrir'
            : 'Rouvrir · $remaining vue${remaining > 1 ? 's' : ''}';
      }
    }

    final baseColor = card.type.color;
    final gradient = card.type.gradient;
    final dimmed = blocked;

    // Le contenu du conteneur se pose sur DEUX fonds différents (2026-08-10) :
    // sur le remplissage plein du dégradé quand la Card n'est pas ouverte — il
    // reste alors blanc quel que soit le thème — ou sur le fond du chat, et il
    // doit dans ce cas suivre le thème. Avant cette distinction, ces blancs
    // étaient invisibles en thème clair.
    final onGradient = gradient != null && unopened;
    final titleColor = dimmed
        ? context.muted
        : (onGradient ? Colors.white : baseColor);
    final iconColor = dimmed
        ? context.faint
        : (onGradient ? Colors.white : baseColor);
    final subtleColor = dimmed
        ? context.faint
        : (onGradient ? Colors.white70 : context.muted);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          // Une Card détruite ne se rouvre pas — les autres états ouvrent le
          // viewer (qui gère épuisement et demande de replay).
          onTap: blocked
              ? null
              : () => Navigator.of(context)
                    .push(
                      MaterialPageRoute(
                        builder: (_) => CardViewerScreen(card: card),
                      ),
                    )
                    .then((_) {
                      ref.invalidate(_myDeliveryProvider(card.id));
                    }),
          child: Opacity(
            opacity: dimmed ? 0.45 : 1,
            child: Container(
              width: 190,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                // Non ouverte : remplissage plein (comme le carré Snap) ;
                // ouverte : simple contour. Jamais d'aperçu de l'image.
                gradient: unopened ? gradient : null,
                color: unopened && gradient == null
                    ? baseColor.withValues(alpha: 0.28)
                    : null,
                border: Border.all(
                  color: dimmed ? context.ghost : baseColor,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    blocked
                        ? Icons.lock
                        : unopened
                        ? Icons.crop_portrait
                        : Icons.crop_portrait_outlined,
                    color: iconColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                card.type.tag,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: titleColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            // Image importée de la galerie : petit logo
                            // discret (consigne Jay 2026-07-12)
                            if (card.imported)
                              Padding(
                                padding: const EdgeInsets.only(left: 5),
                                child: Icon(
                                  Icons.photo_library_outlined,
                                  size: 13,
                                  color: subtleColor,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          stateLabel,
                          style: TextStyle(fontSize: 11, color: subtleColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Replay : le destinataire demande, l'émetteur décide
        // (jamais automatique — décision verrouillée du produit)
        for (final delivery in pendingReplays)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.replay, size: 18),
              label: const Text('Replay demandé — accorder'),
              onPressed: () async {
                try {
                  await ref
                      .read(cardsRepositoryProvider)
                      .grantReplay(delivery.id);
                  ref.invalidate(pendingReplayForCardProvider(card.id));
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
                  }
                }
              },
            ),
          ),
      ],
    );
  }
}

final _cardProvider = FutureProvider.family<CardModel?, String>((
  ref,
  id,
) async {
  final row = await ref
      .watch(supabaseProvider)
      .from('cards')
      .select()
      .eq('id', id)
      .maybeSingle();
  return row == null ? null : CardModel.fromJson(row);
});

/// Aperçu d'un contenu **repartagé** dans le fil.
///
/// Volontairement différent du container d'une Vibe envoyée : celui-ci cache
/// son contenu et se consomme en un nombre de vues limité. Un repartage, lui,
/// n'est qu'un **raccourci** vers une story ou une publication qui vit
/// ailleurs — il s'affiche donc en aperçu réduit, et le clic ouvre la source.
///
/// Quand la source a disparu (story expirée, publication retirée, contenu
/// révoqué), la tuile le DIT au lieu de s'évaporer : un raccourci vers rien
/// doit s'annoncer comme tel (règle arrêtée par Jay le 2026-08-11).
class _SharedContentTile extends ConsumerWidget {
  const _SharedContentTile({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = message.contentId;
    if (id == null) return const _SharedGone();

    final shared = ref.watch(sharedContentProvider(id));
    return shared.when(
      loading: () => const _SharedShell(
        child: Center(
          child: SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, _) => const _SharedGone(),
      data: (content) {
        final story = content.story;
        final item = content.item;
        if (story == null && item == null) return const _SharedGone();

        final type = story?.cardType ?? item!.cardType;
        final label = story != null ? 'Story' : 'Publication';
        final face = ref.watch(
          contentFaceProvider((
            contentId: id,
            ownerId: story?.ownerId ?? item!.ownerId,
            bucket: story != null ? 'stories' : 'library',
            path: story?.frontPath ?? item!.frontPath,
            front: true,
            isVideo: story?.frontIsVideo ?? item!.frontIsVideo,
            encrypted: story?.encrypted ?? item!.encrypted,
            batchOwner: null,
          )),
        );

        return GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => story != null
                  ? StoryViewerScreen(
                      ring: StoryRing(owner: story.owner!, stories: [story]),
                    )
                  : PublicationViewerScreen(item: item!),
            ),
          ),
          child: _SharedShell(
            borderColor: type.color,
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 46,
                    height: 46 / kMiniCardRatio,
                    child: face.when(
                      loading: () => const ColoredBox(color: Color(0xFF1C1C24)),
                      error: (_, _) => const ColoredBox(
                        color: Color(0xFF1C1C24),
                        child: Icon(
                          Icons.error_outline,
                          size: 16,
                          color: Colors.white38,
                        ),
                      ),
                      data: (file) =>
                          (story?.frontIsVideo ?? item!.frontIsVideo)
                          ? const ColoredBox(
                              color: Color(0xFF1C1C24),
                              child: Icon(
                                Icons.videocam,
                                size: 16,
                                color: Colors.white54,
                              ),
                            )
                          : Image.file(
                              file,
                              fit: BoxFit.cover,
                              cacheWidth: 160,
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          CardTypeBadge(type: type, fontSize: 10),
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: type.color,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Appuie pour ouvrir',
                        style: TextStyle(fontSize: 12, color: context.muted),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: context.faint, size: 20),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Le cadre commun de la tuile de repartage.
class _SharedShell extends StatelessWidget {
  const _SharedShell({required this.child, this.borderColor});

  final Widget child;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: borderColor ?? Theme.of(context).dividerColor,
          width: borderColor == null ? 1 : 1.5,
        ),
      ),
      child: child,
    );
  }
}

/// La source n'existe plus. On le dit.
class _SharedGone extends StatelessWidget {
  const _SharedGone();

  @override
  Widget build(BuildContext context) {
    return _SharedShell(
      child: Row(
        children: [
          Icon(Icons.link_off, size: 18, color: context.faint),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Ce contenu n\'est plus disponible.',
              style: TextStyle(fontSize: 13, color: context.muted),
            ),
          ),
        ],
      ),
    );
  }
}
