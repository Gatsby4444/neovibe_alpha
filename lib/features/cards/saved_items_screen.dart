import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/card.dart';
import '../../core/supabase_providers.dart';
import 'card_viewer_screen.dart';
import 'cards_repository.dart';
import 'face_thumb.dart';

enum _SavedFilter { mine, friends, others }

/// Enregistrements : la bibliothèque PRIVÉE, visible de moi seul.
/// Tri : mes créations / cards sauvegardées de mes amis / les autres
/// (onglet d'anticipation, vide pour l'instant — consigne Jay).
class SavedItemsScreen extends ConsumerStatefulWidget {
  const SavedItemsScreen({super.key});

  @override
  ConsumerState<SavedItemsScreen> createState() => _SavedItemsScreenState();
}

class _SavedItemsScreenState extends ConsumerState<SavedItemsScreen> {
  var _filter = _SavedFilter.mine;

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final saved = ref.watch(savedCardsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Enregistrements')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<_SavedFilter>(
              segments: const [
                ButtonSegment(
                  value: _SavedFilter.mine,
                  label: Text('Moi'),
                  icon: Icon(Icons.person, size: 16),
                ),
                ButtonSegment(
                  value: _SavedFilter.friends,
                  label: Text('Amis'),
                  icon: Icon(Icons.people, size: 16),
                ),
                ButtonSegment(
                  value: _SavedFilter.others,
                  label: Text('Autres'),
                  icon: Icon(Icons.public, size: 16),
                ),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(savedCardsProvider),
              child: saved.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Erreur : $e'),
                    ),
                  ],
                ),
                data: (list) {
                  final filtered = switch (_filter) {
                    _SavedFilter.mine =>
                      list.where((s) => s.card!.ownerId == me).toList(),
                    _SavedFilter.friends =>
                      list.where((s) => s.card!.ownerId != me).toList(),
                    // Anticipation : contenus de non-amis (événements futurs)
                    _SavedFilter.others => <SavedCard>[],
                  };
                  if (filtered.isEmpty) {
                    return ListView(
                      children: [
                        const SizedBox(height: 100),
                        Icon(
                          Icons.bookmark_border,
                          size: 56,
                          color: Colors.white24,
                        ),
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            switch (_filter) {
                              _SavedFilter.mine =>
                                'Aucune création enregistrée.\nDepuis l\'envoi d\'une Card, active « Enregistrer pour moi ».',
                              _SavedFilter.friends =>
                                'Aucune card d\'ami enregistrée.\nLes cards « sauvegardables » reçues peuvent être gardées ici.',
                              _SavedFilter.others =>
                                'Rien ici pour l\'instant — cet espace servira plus tard.',
                            },
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54),
                          ),
                        ),
                      ],
                    );
                  }
                  return GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                        ),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final savedCard = filtered[index];
                      final card = savedCard.card!;
                      return GestureDetector(
                        // Lecture illimitée dans les Enregistrements
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                CardViewerScreen(card: card, fromLibrary: true),
                          ),
                        ),
                        onLongPress: () async {
                          final remove = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text(
                                'Retirer des Enregistrements ?',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Annuler'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Retirer'),
                                ),
                              ],
                            ),
                          );
                          if (remove == true) {
                            await ref
                                .read(cardsRepositoryProvider)
                                .unsaveCard(card.id);
                            ref.invalidate(savedCardsProvider);
                          }
                        },
                        child: _SavedThumb(card: card),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SavedThumb extends ConsumerWidget {
  const _SavedThumb({required this.card});
  final CardModel card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(_savedUrlProvider(card.frontPath));
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: card.type.color, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: FaceThumb(path: card.frontPath, url: url.value),
          ),
          Positioned(
            bottom: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                card.type.tag,
                style: TextStyle(
                  color: card.type.color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final _savedUrlProvider = FutureProvider.family<String, String>(
  (ref, path) => ref
      .watch(supabaseProvider)
      .storage
      .from('cards')
      .createSignedUrl(path, 3600),
);
