import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/story.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/gradient.dart';
import '../cards/card_viewer_screen.dart';
import '../library/user_library_screen.dart';
import 'stories_repository.dart';

/// Visionneuse de stories d'un auteur : on avance d'une story à l'autre en
/// tapant à droite, on recule à gauche.
///
/// La Card elle-même est rendue par `CardViewerScreen` avec `fromLibrary:
/// true` — c'est le mode **lecture illimitée**, qui correspond à la décision
/// de Jay du 2026-08-02 (une story se revoit autant qu'on veut pendant 24 h).
/// Les compteurs de vues et la destruction des Cards en chat ne s'appliquent
/// donc pas ici.
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
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
                  ),
          ),
          // Zones de navigation, sous l'en-tête pour ne pas manger ses taps.
          Positioned.fill(
            top: 96,
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
          _Header(
            ring: widget.ring,
            index: _index,
            isMine: isMine,
            onClose: () => Navigator.of(context).pop(),
            onDelete: !isMine ? null : () => _confirmDelete(),
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
          'Elle disparaît pour tout le monde. La Card, elle, reste.',
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
/// (consigne Jay 2026-08-02), horodatage, fermeture.
class _Header extends StatelessWidget {
  const _Header({
    required this.ring,
    required this.index,
    required this.isMine,
    required this.onClose,
    this.onDelete,
  });

  final StoryRing ring;
  final int index;
  final bool isMine;
  final VoidCallback onClose;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final owner = ring.owner;
    return SafeArea(
      child: Container(
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
            Row(
              children: [
                InkWell(
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
                            ? Image.network(owner.avatarUrl!, fit: BoxFit.cover)
                            : Container(
                                color: const Color(0xFF2A2A36),
                                alignment: Alignment.center,
                                child: Text(
                                  owner.chatName.characters.first.toUpperCase(),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        owner.chatName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  shortTime(ring.stories[index].createdAt),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const Spacer(),
                if (onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Retirer cette story',
                    onPressed: onDelete,
                  ),
                IconButton(icon: const Icon(Icons.close), onPressed: onClose),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
