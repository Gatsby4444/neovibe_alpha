import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/anchor.dart';
import '../../core/models/library_item.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/cover_host.dart';
import '../../core/widgets/vibe_face.dart';
import '../events/events_providers.dart';
import '../library/mini_card.dart';
import '../library_vibes/conversation_library_screen.dart';
import '../stories/stories_bar.dart';
import '../stories/stories_repository.dart';
import 'pulse_feed_screen.dart';
import 'pulse_repository.dart';

/// **Pulse** — la section des contenus, le feed (Jay, 2026-09-20). Nom
/// temporaire : le pouls de ta ville.
///
/// Quatre étages :
/// 1. les **stories** de mes amis, en bandeau (venues du Cercle) ;
/// 2. **mes soirées** ([_MesSoirees], 2026-09-21) : les événements où j'ai
///    été, en cours ou fermés depuis moins de cinq jours — un tap ouvre leur
///    Drop. C'est « les jours qui suivent, je vois dans mon feed les contenus
///    de cette bibliothèque » (Jay) : le Drop d'un événement est un autre
///    objet que les publications du feed, il n'y est pas mêlé, il y est
///    tendu ;
/// 3. une **galerie** de mini-cards, comme une bibliothèque : **des Vibes,
///    rien d'autre** (Jay, 2026-09-21 — les Flows et les publications qui
///    s'y mêlaient sont sortis du MVP) ;
/// 4. un tap ouvre **le plein écran** ([PulseFeedScreen]), posé sur la case
///    touchée, avec son sélecteur Tout / Amis / Autour de moi.
///
/// Pas de scroll infini ici : une grille de ce qui est là (le serveur borne).
/// Ce qui est là : les croisés des 3 derniers jours, ce que mes amis m'ont
/// ajouté, et ce qui a été localisé près de moi — trois sources humaines,
/// aucun algorithme (`feed_items`).
class PulseScreen extends ConsumerStatefulWidget {
  const PulseScreen({super.key});

  @override
  ConsumerState<PulseScreen> createState() => _PulseScreenState();
}

class _PulseScreenState extends ConsumerState<PulseScreen> {
  /// Où je suis, pour la source « autour de moi » de la galerie — relevé à
  /// l'ouverture et à chaque tirer-pour-rafraîchir. Nul tant qu'il n'est pas
  /// là (la galerie montre déjà les deux autres sources).
  ContentAnchor? _at;

  @override
  void initState() {
    super.initState();
    unawaited(_locate());
  }

  Future<void> _locate() async {
    final a = await ref.read(anchorSourceProvider).current();
    if (mounted && a != null && a != _at) setState(() => _at = a);
  }

  FeedQuery get _query => (mode: FeedMode.tout, at: _at);

  Future<void> _refresh() async {
    await _locate();
    ref.invalidate(feedItemsProvider(_query));
    await ref.read(feedItemsProvider(_query).future);
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(feedItemsProvider(_query));
    return CoverHost(
      child: Scaffold(
        appBar: AppBar(centerTitle: true, title: const Text('Pulse')),
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            children: [
              StoriesBar(
                provider: friendStoriesProvider,
                emptyHint: 'Pas de story pour l\'instant.',
              ),
              const _MesSoirees(),
              items.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Erreur : $e'),
                ),
                data: (list) => list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Rien pour l\'instant.\nCroise des gens, et ce '
                          'qu\'ils publient apparaîtra ici — avec ce que tes '
                          'amis t\'ajoutent.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.muted),
                        ),
                      )
                    : _Grille(items: list, at: _at),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La grille : les mêmes cases que le profil.
class _Grille extends StatelessWidget {
  const _Grille({required this.items, required this.at});

  final List<LibraryItem> items;
  final ContentAnchor? at;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 80),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: kVibeFaceRatio,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => MiniCard(
        item: items[i],
        // Un tap ouvre le plein écran, posé sur cette case.
        onTap: () => openPulseFeed(context, initial: items[i], at: at),
      ),
    );
  }
}

/// **Mes soirées** : les événements où j'ai été (présent ou invité), en
/// cours ou fermés depuis moins de cinq jours — le temps que leur Drop vit.
/// Rien si je n'en ai aucun : pas de titre vide.
class _MesSoirees extends ConsumerWidget {
  const _MesSoirees();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(myEventsProvider).value ?? const [];
    final now = DateTime.now();
    final recents = [
      for (final e in events)
        if (e.openedAt != null &&
            (e.isOpen ||
                (e.closedAt != null &&
                    now.difference(e.closedAt!) < const Duration(days: 5))))
          e,
    ];
    if (recents.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Text('Mes soirées', style: context.sectionTitle),
        ),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: recents.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final e = recents[i];
              final p = context.palette;
              return Material(
                color: e.isOpen ? p.action.withValues(alpha: 0.12) : p.surface,
                borderRadius: BorderRadius.circular(NeoRadius.md),
                child: InkWell(
                  borderRadius: BorderRadius.circular(NeoRadius.md),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ConversationLibraryScreen(
                        conversationId: e.conversationId,
                        title: e.title,
                      ),
                    ),
                  ),
                  child: Container(
                    width: 150,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(NeoRadius.md),
                      border: Border.all(color: p.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Icon(
                          e.autoCreated
                              ? Icons.auto_awesome
                              : Icons.photo_library_outlined,
                          size: 20,
                          color: p.ink,
                        ),
                        Text(
                          e.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          e.isOpen
                              ? 'En cours'
                              : 'Drop · ${vagueTimeAgo(e.closedAt!)}',
                          style: TextStyle(color: context.muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
