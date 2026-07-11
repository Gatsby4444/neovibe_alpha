import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/library_item.dart';
import '../../core/supabase_providers.dart';
import '../cards/card_viewer_screen.dart';
import '../settings/settings_screen.dart';
import 'library_repository.dart';

/// Mon profil + ma bibliothèque : l'espace qui PERSISTE, contrairement
/// à la messagerie (spec 4.10).
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final profile = ref.watch(myProfileProvider).value;
    final items = ref.watch(libraryItemsProvider(me));

    return Scaffold(
      appBar: AppBar(
        title: Text(profile?.displayName ?? 'Profil'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Ajouter à ma bibliothèque',
        onPressed: () async {
          final picked = await ImagePicker().pickImage(
            source: ImageSource.gallery,
            imageQuality: 85,
            maxWidth: 1600,
          );
          if (picked == null) return;
          await ref
              .read(libraryRepositoryProvider)
              .addMedia(File(picked.path), 'photo');
          ref.invalidate(libraryItemsProvider(me));
        },
        child: const Icon(Icons.add_photo_alternate),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(libraryItemsProvider(me)),
        child: items.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Erreur : $e')),
          data: (list) => list.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 120),
                    Icon(
                      Icons.photo_library_outlined,
                      size: 56,
                      color: Colors.white24,
                    ),
                    Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Ta bibliothèque est vide.\nPublie une Card ou ajoute une photo : ici, ça reste.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ],
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: list.length,
                  itemBuilder: (context, index) => LibraryTile(
                    item: list[index],
                    onLongPress: () async {
                      final delete = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Retirer de la bibliothèque ?'),
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
                      if (delete == true) {
                        await ref
                            .read(libraryRepositoryProvider)
                            .removeItem(list[index].id);
                        ref.invalidate(libraryItemsProvider(me));
                      }
                    },
                  ),
                ),
        ),
      ),
    );
  }
}

/// Vignette de bibliothèque : photo/vidéo ou Card (avec son liseré de type).
class LibraryTile extends ConsumerWidget {
  const LibraryTile({super.key, required this.item, this.onLongPress});
  final LibraryItem item;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (item.kind == 'card' && item.card != null) {
      final card = item.card!;
      return GestureDetector(
        onLongPress: onLongPress,
        // Bibliothèque : lecture illimitée (les limites de vues/durée ne
        // s'appliquent qu'en chat — consigne Jay)
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CardViewerScreen(card: card, fromLibrary: true),
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: card.type.color, width: 2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: _CardThumb(
            path: card.frontPath,
            tag: card.type.tag,
            color: card.type.color,
          ),
        ),
      );
    }
    return GestureDetector(
      onLongPress: onLongPress,
      child: _MediaThumb(path: item.mediaPath!),
    );
  }
}

class _CardThumb extends ConsumerWidget {
  const _CardThumb({
    required this.path,
    required this.tag,
    required this.color,
  });
  final String path;
  final String tag;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(_cardUrlProvider(path));
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: url.value == null
              ? const ColoredBox(color: Color(0xFF1C1C24))
              : Image.network(url.value!, fit: BoxFit.cover),
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
              tag,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaThumb extends ConsumerWidget {
  const _MediaThumb({required this.path});
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(_libraryUrlProvider(path));
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: url.value == null
          ? const ColoredBox(color: Color(0xFF1C1C24))
          : Image.network(url.value!, fit: BoxFit.cover),
    );
  }
}

final _cardUrlProvider = FutureProvider.family<String, String>(
  (ref, path) => ref
      .watch(supabaseProvider)
      .storage
      .from('cards')
      .createSignedUrl(path, 3600),
);

final _libraryUrlProvider = FutureProvider.family<String, String>(
  (ref, path) => ref
      .watch(supabaseProvider)
      .storage
      .from('library')
      .createSignedUrl(path, 3600),
);
