import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../connections/friends_list_screen.dart';
import '../connections/heart_screen.dart';
import '../settings/settings_screen.dart';
import 'album_editor/album_publish_banner.dart';
import 'library_repository.dart';
import 'publications_tabs.dart';
import 'profile_edit_screen.dart';
import 'profile_header.dart';
import 'publish_choice_sheet.dart';

/// Mon profil (consigne Jay 2026-07-12) : PP + username en haut, stats, bio,
/// puis la bibliothèque PUBLIQUE (partagée avec les amis). La bibliothèque
/// privée (« Enregistrements ») vit dans les Réglages.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  Future<void> _editer(
    BuildContext context,
    WidgetRef ref,
    Profile profile, {
    bool bio = false,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileEditScreen(profile: profile, focusBio: bio),
      ),
    );
    ref.invalidate(myProfileProvider);
  }

  Future<void> _menu(
    BuildContext context,
    WidgetRef ref,
    Profile profile,
  ) async {
    final choix = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Modifier le profil'),
              subtitle: const Text('Photo, pseudo, tag'),
              onTap: () => Navigator.pop(context, 'profil'),
            ),
            ListTile(
              leading: const Icon(Icons.notes_outlined),
              title: const Text('Modifier la bio'),
              onTap: () => Navigator.pop(context, 'bio'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choix == null || !context.mounted) return;
    await _editer(context, ref, profile, bio: choix == 'bio');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final profile = ref.watch(myProfileProvider).value;
    final items = ref.watch(libraryItemsProvider(me));

    return Scaffold(
      appBar: AppBar(
        // Titre centré : c'est un TITRE DE SECTION, pas un fil d'Ariane
        // (consigne de Jay, 2026-08-15). Les écrans poussés gardent le titre
        // aligné à gauche — le thème n'est pas touché.
        centerTitle: true,
        title: const Text('Profil'),
        actions: [
          // Le menu « … » de mon profil (Jay, 2026-09-18) : les options,
          // nommées, dans une feuille — dont « Modifier la bio », qui ouvre
          // le clavier directement sur elle.
          if (profile != null)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: 'Plus',
              onPressed: () => _menu(context, ref, profile),
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
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myProfileProvider);
          ref.invalidate(libraryItemsProvider(me));
        },
        child: ListView(
          children: [
            // L'album en cours d'envoi, s'il y en a un : « Publication… n/N ».
            const AlbumPublishBanner(),
            if (profile != null)
              ProfileHeader(
                profile: profile,
                onAddBio: () => _editer(context, ref, profile, bio: true),
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
                  // Publier : une Vibe (notre caméra) ou des photos / vidéos
                  // (l'éditeur). Le bouton du « deck » vivait ici — le deck
                  // est supprimé (Jay, 2026-09-15), et l'import direct d'une
                  // photo qu'ouvrait le bouton flottant passe par l'éditeur.
                  IconButton(
                    icon: const Icon(Icons.add_box_outlined),
                    tooltip: 'Publier',
                    onPressed: () => showPublishChoice(context),
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
              data: (list) => PublicationsTabs(
                items: list,
                feedTitle: 'Publications',
                emptyMessage:
                    'Ta bibliothèque est vide.\nPublie une Vibe ou ajoute '
                    'une photo : ici, ça reste.',
                onLongPress: (item) async {
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
                        .removeItem(item.id);
                    ref.invalidate(libraryItemsProvider(me));
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
