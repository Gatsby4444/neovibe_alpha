import 'package:flutter/material.dart';
import '../connections/friendships_repository.dart';
import '../../core/typography.dart';
import '../../core/widgets/avatar.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/derived_list.dart';
import '../../core/models/story.dart';
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
  final Provider<AsyncValue<ValueList<StoryRing>>> provider;

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
          // La hauteur d'une carte, plus l'air autour. Elle est ici et pas
          // dans la carte : c'est la BARRE qui décide de la place qu'elle
          // prend, la carte ne fait que la remplir.
          height: _StoryCard.hauteur + NeoSpace.lg,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: NeoSpace.md,
              vertical: NeoSpace.sm,
            ),
            itemCount: list.length,
            // Chaque pastille reçoit TOUTE la liste : arrivé au bout d'un
            // auteur, la visionneuse enchaîne sur le suivant sans repasser
            // par ici (consigne de Jay du 2026-08-13).
            itemBuilder: (context, index) =>
                _StoryCard(rings: list.items, index: index),
          ),
        );
      },
    );
  }
}

/// Une story, **au format CARTE** — décision de Jay du 2026-08-29.
///
/// ## Pourquoi une carte et plus un rond
///
/// Un rond de 56 px ne montre qu'un visage flou : il dit **qui** publie, jamais
/// **quoi**. Une carte 3/4 montre le contenu, ce qui est tout l'intérêt d'une
/// story. La photo de profil reste ronde, posée par-dessus — c'est elle qui dit
/// qui.
///
/// ⚠️ **Le format est répandu** (Snapchat, TikTok, Netflix), et c'est assumé :
/// il ne nous démarquera pas à lui seul. Ce qui démarque est ce qu'on pose
/// dessus — ici, **l'anneau de palier d'amitié**, que personne d'autre n'a.
///
/// ## L'anneau n'apparaît qu'à partir de « Proche »
///
/// ⚠️ Si tout le monde en porte un, il ne distingue plus personne. Au palier le
/// plus bas, la carte n'a qu'un liseré discret.
class _StoryCard extends ConsumerWidget {
  const _StoryCard({required this.rings, required this.index});

  /// La largeur d'une carte, et sa hauteur en 3/4.
  static const largeur = 96.0;
  static const hauteur = largeur * 4 / 3;

  /// L'épaisseur de l'anneau de palier.
  static const _anneau = 2.5;

  final List<StoryRing> rings;
  final int index;

  StoryRing get ring => rings[index];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ring.owner.chatName;
    final p = context.palette;
    final tier = ref.watch(tierOfProvider(ring.owner.id));

    return Padding(
      padding: const EdgeInsets.only(right: NeoSpace.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(NeoRadius.lg),
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
        child: Container(
          width: largeur,
          height: hauteur,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NeoRadius.lg),
            // L'anneau de palier devient une BORDURE en dégradé. Sur un
            // rectangle, un anneau est un liseré — la forme change, la règle
            // non.
            gradient: tier.porteUnAnneau ? tier.anneau(p) : null,
            border: tier.porteUnAnneau ? null : Border.all(color: p.line),
          ),
          padding: EdgeInsets.all(tier.porteUnAnneau ? _anneau : 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              NeoRadius.lg - (tier.porteUnAnneau ? _anneau : 0),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                AvatarFill(
                  stored: ring.owner.avatarUrl,
                  fallback: Container(
                    // Habillage de l'app : la carte suit le thème. En dur, elle
                    // restait sombre en thème clair et l'initiale, qui hérite
                    // de `onSurface`, s'y écrivait en noir.
                    color: p.field,
                    alignment: Alignment.center,
                    child: Text(
                      name.characters.first.toUpperCase(),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ),
                // Le voile : sans lui, un pseudo blanc sur une photo claire est
                // illisible, et ça ne se voit que sur CERTAINES photos.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xB3000000)],
                    ),
                  ),
                ),
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // ⚠️ Blanc EN DUR, et c'est juste : ce texte se pose sur
                    // une photo, pas sur une surface du thème. Le faire suivre
                    // l'identité le rendrait noir sur une photo sombre.
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
