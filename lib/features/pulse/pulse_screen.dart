import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/anchor.dart';
import '../../core/models/library_item.dart';
import '../../core/theme.dart';
import '../../core/widgets/cover_host.dart';
import '../../core/widgets/vibe_face.dart';
import '../library/mini_card.dart';
import '../stories/stories_bar.dart';
import '../stories/stories_repository.dart';
import 'pulse_feed_screen.dart';
import 'pulse_repository.dart';

/// **Pulse** — la section des contenus, le feed (Jay, 2026-09-20). Nom
/// temporaire : le pouls de ta ville.
///
/// Trois étages :
/// 1. les **stories** de mes amis, en bandeau (venues du Cercle) ;
/// 2. une **galerie** de mini-cards, comme une bibliothèque : **des Vibes,
///    rien d'autre** (Jay, 2026-09-21 — les Flows et les publications qui
///    s'y mêlaient sont sortis du MVP) ;
/// 3. un tap ouvre **le plein écran** ([PulseFeedScreen]), posé sur la case
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
