import 'package:flutter/material.dart';
import '../../core/widgets/avatar.dart';
import '../../core/theme.dart';
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
///
/// L'accès au profil vaut aussi dans le Ping, y compris pour un non-ami :
/// vérifié en base le 2026-08-02, `can_view_profile` contient une branche
/// `encounters` depuis le 2026-07-12 — **un croisement certifié ouvre déjà
/// l'accès au profil**, par conception. Le bandeau ne crée donc aucun accès
/// nouveau.
class StoriesBar extends ConsumerWidget {
  const StoriesBar({super.key, required this.provider, this.emptyHint});

  /// `friendStoriesProvider` (Cercle) ou `crossedStoriesProvider` (Ping) :
  /// même bandeau, deux fils.
  final FutureProvider<List<StoryRing>> provider;

  /// Affiché à la place du bandeau quand il n'y a rien. Null = bandeau masqué.
  final String? emptyHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rings = ref.watch(provider);
    return rings.when(
      loading: () => const SizedBox(
        height: 96,
        child: Center(
          child: SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      // Une erreur ne doit PAS se traduire par un bandeau vide : c'est ce qui
      // a rendu la panne du 2026-08-02 indiscernable d'une absence de story.
      // Les trois états doivent se distinguer au premier coup d'œil.
      error: (e, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Text(
          'Stories indisponibles : $e',
          style: TextStyle(
            color: Theme.of(context).colorScheme.error,
            fontSize: 12,
          ),
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          if (emptyHint == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Text(
              emptyHint!,
              style: TextStyle(color: context.faint, fontSize: 12),
            ),
          );
        }
        return SizedBox(
          height: 96,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: list.length,
            // Chaque pastille reçoit TOUTE la liste : arrivé au bout d'un
            // auteur, la visionneuse enchaîne sur le suivant sans repasser
            // par ici (consigne de Jay du 2026-08-13).
            itemBuilder: (context, index) =>
                _StoryDot(rings: list, index: index),
          ),
        );
      },
    );
  }
}

class _StoryDot extends StatelessWidget {
  const _StoryDot({required this.rings, required this.index});

  final List<StoryRing> rings;
  final int index;

  StoryRing get ring => rings[index];

  @override
  Widget build(BuildContext context) {
    final name = ring.owner.chatName;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => StoryViewerScreen(rings: rings, initialRing: index),
          ),
        ),
        onLongPress: () => Navigator.of(context).push(
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
                child: AvatarFill(
                  stored: ring.owner.avatarUrl,
                  fallback: Container(
                    // Habillage de l'app : la pastille suit le thème. En dur,
                    // elle restait sombre en thème clair et l'initiale, qui
                    // hérite de `onSurface`, s'y écrivait en noir.
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Text(name.characters.first.toUpperCase()),
                  ),
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
