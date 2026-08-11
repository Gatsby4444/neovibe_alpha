import 'dart:io';

import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/supabase_providers.dart';
import '../../core/widgets/gradient.dart';
import '../connections/friends_list_screen.dart';
import '../connections/heart_screen.dart';
import '../settings/settings_screen.dart';
import 'library_deck_screen.dart';
import 'library_repository.dart';
import 'mini_card.dart';
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
          // C�"ur à droite des paramètres (consigne Jay) : demandes de
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
          // L'option publique se règle �? la publication (consigne Jay)
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
          // Une photo importée est une publication à face unique : même
          // chemin que celles issues de la caméra depuis le 2026-08-11.
          await ref
              .read(libraryRepositoryProvider)
              .publish(front: File(picked.path), isPublic: isPublic);
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Bibliothèque',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Bascule grille �?" deck (consigne Jay : on essaie les deux)
                  IconButton(
                    icon: const Icon(Icons.view_carousel_outlined),
                    tooltip: 'Parcourir en deck',
                    onPressed: () {
                      final list = items.value;
                      if (list == null || list.isEmpty) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => LibraryDeckScreen(items: list),
                        ),
                      );
                    },
                  ),
                ],
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
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Ta bibliothèque est vide.\nPublie une Vibe ou ajoute une photo : ici, ça reste.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.muted),
                      ),
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 80),
                      // 3 colonnes (consigne Jay), mais au FORMAT CARD
                      // (portrait) au lieu des carrés d'avant.
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: kMiniCardRatio,
                          ),
                      itemCount: list.length,
                      itemBuilder: (context, index) => MiniCard(
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
