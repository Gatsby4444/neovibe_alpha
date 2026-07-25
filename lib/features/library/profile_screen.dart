import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/library_item.dart';
import '../../core/supabase_providers.dart';
import '../../core/widgets/gradient.dart';
import '../cards/card_viewer_screen.dart';
import '../cards/face_thumb.dart';
import '../connections/friends_list_screen.dart';
import '../connections/heart_screen.dart';
import '../conversations/video_player_screen.dart';
import '../settings/settings_screen.dart';
import 'library_repository.dart';
import 'photo_viewer_screen.dart';
import 'profile_edit_screen.dart';
import 'profile_header.dart';

/// Mon profil (consigne Jay 2026-07-12) : PP + username en haut, stats, bio,
/// puis la bibliothèque PUBLIQUE (partagée avec les amis). La bibliothèque
/// privée (« Enregistrements ») vit dans les Réglages.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final profile = ref.watch(myProfileProvider).value;
    final items = ref.watch(libraryItemsProvider(me));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'),
        actions: [
          if (profile != null)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Modifier le profil',
              onPressed: () => Navigator.of(context)
                  .push(
                    MaterialPageRoute(
                      builder: (_) => ProfileEditScreen(profile: profile),
                    ),
                  )
                  .then((_) => ref.invalidate(myProfileProvider)),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Réglages',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          // Cœur à droite des paramètres (consigne Jay) : demandes de
          // connexion, recommandations et Waves.
          IconButton(
            icon: const Icon(Icons.favorite_border),
            tooltip: 'Demandes & rencontres',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const HeartScreen())),
          ),
        ],
      ),
      floatingActionButton: GradientFab(
        tooltip: 'Ajouter à ma bibliothèque',
        icon: Icons.add_photo_alternate,
        onPressed: () async {
          final picked = await ImagePicker().pickImage(
            source: ImageSource.gallery,
            imageQuality: 85,
            maxWidth: 1600,
          );
          if (picked == null || !context.mounted) return;
          // L'option publique se règle À la publication (consigne Jay)
          final isPublic = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Qui peut voir cette photo ?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Selon mes règles d\'accès'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Publique'),
                ),
              ],
            ),
          );
          if (isPublic == null) return;
          await ref
              .read(libraryRepositoryProvider)
              .addMedia(File(picked.path), 'photo', isPublic: isPublic);
          ref.invalidate(libraryItemsProvider(me));
        },
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myProfileProvider);
          ref.invalidate(libraryItemsProvider(me));
        },
        child: ListView(
          children: [
            if (profile != null)
              ProfileHeader(
                profile: profile,
                // Le compteur d'amis ouvre la liste recherchable (consigne Jay)
                onFriendsTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FriendsListScreen()),
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                'Bibliothèque',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
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
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Ta bibliothèque est vide.\nPublie une Card ou ajoute une photo : ici, ça reste.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 80),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
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
          ],
        ),
      ),
    );
  }
}

/// Vignette de bibliothèque : photo/vidéo (plein écran au tap) ou Card
/// (viewer, lecture illimitée en bibliothèque).
class LibraryTile extends ConsumerWidget {
  const LibraryTile({super.key, required this.item, this.onLongPress});
  final LibraryItem item;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tag « Public » indiqué côté créateur uniquement (consigne Jay)
    final me = ref.watch(currentUserIdProvider);
    final showPublicTag = item.isPublic && item.ownerId == me;

    Widget tagged(Widget child) => showPublicTag
        ? Stack(
            fit: StackFit.expand,
            children: [
              child,
              const Positioned(top: 4, right: 4, child: _PublicBadge()),
            ],
          )
        : child;

    if (item.kind == 'card' && item.card != null) {
      final card = item.card!;
      return GestureDetector(
        onLongPress: onLongPress,
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
          child: tagged(
            _CardThumb(
              path: card.frontPath,
              tag: card.type.tag,
              color: card.type.color,
            ),
          ),
        ),
      );
    }
    // Photo/vidéo simple : plein écran au tap (correctif consigne Jay)
    return GestureDetector(
      onLongPress: onLongPress,
      onTap: () async {
        final path = item.mediaPath;
        if (path == null) return;
        final url = await ref.read(libraryRepositoryProvider).mediaUrl(path);
        if (!context.mounted) return;
        if (item.kind == 'video') {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => VideoPlayerScreen(url: url)),
          );
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  PhotoViewerScreen(url: url, caption: item.caption),
            ),
          );
        }
      },
      child: tagged(_MediaThumb(path: item.mediaPath!)),
    );
  }
}

/// Badge « Public » affiché sur les publications publiques, uniquement
/// dans la bibliothèque de leur créateur.
class _PublicBadge extends StatelessWidget {
  const _PublicBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white38),
      ),
      child: const Text(
        'Public',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
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
          child: FaceThumb(path: path, url: url.value),
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
      child: FaceThumb(path: path, url: url.value),
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
