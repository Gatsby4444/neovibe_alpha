import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/story.dart';
import '../../core/widgets/gradient.dart';
import '../library/user_library_screen.dart';
import 'story_viewer_screen.dart';

/// Bandeau horizontal de stories, en haut du Cercle et du Ping.
///
/// Chaque pastille montre l'avatar cerclé du dégradé de marque et le pseudo
/// dessous (registre Instagram, consigne Jay 2026-08-02). Un appui ouvre la
/// visionneuse ; un appui **long** mène au profil de l'auteur — le tap simple
/// est réservé à la lecture, c'est ce que le geste attend partout ailleurs.
class StoriesBar extends ConsumerWidget {
  const StoriesBar({
    super.key,
    required this.provider,
    this.emptyHint,
    this.profileTapEnabled = true,
  });

  /// `friendStoriesProvider` (Cercle) ou `crossedStoriesProvider` (Ping) :
  /// même bandeau, deux fils.
  final FutureProvider<List<StoryRing>> provider;

  /// Affiché à la place du bandeau quand il n'y a rien. Null = bandeau masqué.
  final String? emptyHint;

  /// Accès au profil de l'auteur depuis la pastille. Coupé dans le Ping tant
  /// que les règles de confidentialité des comptes non liés n'ont pas été
  /// tranchées par Jay (2026-08-02).
  final bool profileTapEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rings = ref.watch(provider);
    return rings.when(
      loading: () => const SizedBox(height: 96),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) {
          if (emptyHint == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Text(
              emptyHint!,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          );
        }
        return SizedBox(
          height: 96,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: list.length,
            itemBuilder: (context, index) => _StoryDot(
              ring: list[index],
              profileTapEnabled: profileTapEnabled,
            ),
          ),
        );
      },
    );
  }
}

class _StoryDot extends StatelessWidget {
  const _StoryDot({required this.ring, required this.profileTapEnabled});
  final StoryRing ring;
  final bool profileTapEnabled;

  @override
  Widget build(BuildContext context) {
    final name = ring.owner.chatName;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => StoryViewerScreen(ring: ring)),
        ),
        onLongPress: !profileTapEnabled
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => UserLibraryScreen(profile: ring.owner),
                ),
              ),
        child: SizedBox(
          width: 64,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GradientRing(
                size: 56,
                child: ring.owner.avatarUrl != null
                    ? Image.network(ring.owner.avatarUrl!, fit: BoxFit.cover)
                    : Container(
                        color: const Color(0xFF2A2A36),
                        alignment: Alignment.center,
                        child: Text(name.characters.first.toUpperCase()),
                      ),
              ),
              const SizedBox(height: 4),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
