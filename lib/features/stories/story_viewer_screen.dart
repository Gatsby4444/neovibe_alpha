import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/card.dart';
import '../../core/models/story.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/gradient.dart';
import '../cards/card_viewer_screen.dart';
import '../cards/cards_repository.dart';
import '../library/user_library_screen.dart';
import 'stories_repository.dart';

/// Hauteur de l'en-tête sous la barre d'état : padding 8 + barres de
/// progression 2 + espace 10 + rangée d'icônes 48 + padding 8.
const _headerHeight = 76.0;

/// Visionneuse de stories d'un auteur : on avance d'une story à l'autre en
/// tapant à droite, on recule à gauche.
///
/// La Card elle-même est rendue par `CardViewerScreen` en mode **chromeless**
/// (`fromLibrary: true` = lecture illimitée, décision de Jay du 2026-08-02 :
/// une story se revoit autant qu'on veut pendant 24 h). Sans `chromeless`,
/// l'AppBar de la Card passait SOUS l'en-tête de la story et les deux
/// s'écrasaient — défaut relevé au test de la v0.9.40.
class StoryViewerScreen extends ConsumerStatefulWidget {
  const StoryViewerScreen({super.key, required this.ring});
  final StoryRing ring;

  @override
  ConsumerState<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends ConsumerState<StoryViewerScreen> {
  var _index = 0;

  Story get _story => widget.ring.stories[_index];

  void _next() {
    if (_index < widget.ring.stories.length - 1) {
      setState(() => _index++);
    } else {
      Navigator.of(context).pop();
    }
  }

  void _previous() {
    if (_index > 0) setState(() => _index--);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider);
    final owner = widget.ring.owner;
    final isMine = owner.id == me;
    final card = _story.card;
    final headerBottom = MediaQuery.paddingOf(context).top + _headerHeight;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        // ⚠️ TOUS les enfants sont `Positioned`. Un `Stack` se dimensionne sur
        // ses enfants NON positionnés ; l'en-tête était le seul, et le Stack
        // s'effondrait donc à sa hauteur (~100 px), écrasant et rognant la
        // Card en dessous. C'était la cause du « rien n'apparaît » de la
        // v0.9.40. Sans enfant non positionné, le Stack prend toute la place
        // que lui laisse le Scaffold.
        children: [
          Positioned.fill(
            child: card == null
                ? const Center(
                    child: Text(
                      'Story indisponible.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : CardViewerScreen(
                    // Clé sur l'identifiant : sans elle, passer d'une story à
                    // l'autre réutiliserait l'état du lecteur précédent
                    // (média déjà chargé, face retournée).
                    key: ValueKey(card.id),
                    card: card,
                    fromLibrary: true,
                    chromeless: true,
                  ),
          ),
          // Zones de navigation, sous l'en-tête pour ne pas manger ses taps.
          Positioned(
            top: headerBottom,
            left: 0,
            right: 0,
            bottom: 0,
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _previous,
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _next,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _Header(
              ring: widget.ring,
              index: _index,
              card: card,
              isMine: isMine,
              onClose: () => Navigator.of(context).pop(),
              onDelete: !isMine ? null : () => _confirmDelete(),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retirer cette story ?'),
        content: const Text(
          'Elle disparaît pour tout le monde. La Vibe, elle, reste.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (delete != true || !mounted) return;
    await ref.read(storiesRepositoryProvider).remove(_story.id);
    if (mounted) Navigator.of(context).pop();
  }
}

/// En-tête façon Instagram : barres de progression, avatar + pseudo cliquables
/// (consigne Jay 2026-08-02), horodatage, type de la Card, enregistrement,
/// fermeture.
///
/// C'est le SEUL habillage de l'écran : la `CardViewerScreen` est en mode
/// `chromeless`, donc les actions qu'elle porte d'ordinaire dans son AppBar
/// (enregistrer) sont reprises ici.
class _Header extends ConsumerWidget {
  const _Header({
    required this.ring,
    required this.index,
    required this.card,
    required this.isMine,
    required this.onClose,
    this.onDelete,
  });

  final StoryRing ring;
  final int index;
  final CardModel? card;
  final bool isMine;
  final VoidCallback onClose;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = ring.owner;
    final type = card?.type;
    // Mêmes règles que dans la CardViewerScreen : ses propres cards (1/1
    // exclue), ou une card reçue que son créateur a marquée sauvegardable.
    final canSave =
        card != null &&
        (isMine
            ? type != CardType.oneOfOne
            : (card!.saveable && type!.canBeSaveable));
    final isSaved = card == null
        ? null
        : ref.watch(isCardSavedProvider(card!.id)).value;

    return SafeArea(
      bottom: false,
      child: Container(
        height: _headerHeight,
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                for (var i = 0; i < ring.stories.length; i++)
                  Expanded(
                    child: Container(
                      height: 2,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      color: i <= index ? Colors.white : Colors.white24,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: InkWell(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => UserLibraryScreen(profile: owner),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GradientRing(
                            size: 32,
                            thickness: 1.5,
                            child: owner.avatarUrl != null
                                ? Image.network(
                                    owner.avatarUrl!,
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    color: const Color(0xFF2A2A36),
                                    alignment: Alignment.center,
                                    child: Text(
                                      owner.chatName.characters.first
                                          .toUpperCase(),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              owner.chatName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    shortTime(ring.stories[index].createdAt),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const Spacer(),
                  if (type != null) ...[
                    CardTypeBadge(type: type, fontSize: 11),
                    const SizedBox(width: 4),
                  ],
                  if (canSave)
                    IconButton(
                      color: Colors.white,
                      icon: Icon(
                        isSaved == true
                            ? Icons.bookmark
                            : Icons.bookmark_border,
                      ),
                      tooltip: isSaved == true
                          ? 'Retirer de mes Enregistrements'
                          : 'Enregistrer pour moi',
                      onPressed: () =>
                          _toggleSave(context, ref, isSaved == true),
                    ),
                  if (onDelete != null)
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Retirer cette story',
                      onPressed: onDelete,
                    ),
                  IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleSave(
    BuildContext context,
    WidgetRef ref,
    bool saved,
  ) async {
    final repo = ref.read(cardsRepositoryProvider);
    final id = card!.id;
    try {
      saved ? await repo.unsaveCard(id) : await repo.saveCard(id);
      ref.invalidate(isCardSavedProvider(id));
      ref.invalidate(savedCardsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    }
  }
}
