import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/prefs.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/supabase_providers.dart';
import '../../core/widgets/cover_host.dart';
import '../connections/friends_list_screen.dart';
import '../connections/heart_screen.dart';
import '../settings/settings_screen.dart';
import 'library_repository.dart';
import 'pending_publications.dart';
import 'publications_tabs.dart';
import 'profile_edit_screen.dart';
import 'profile_header.dart';
import '../../core/motion.dart';
import '../cards/card_capture_screen.dart';
import '../gallery/gallery_screen.dart';

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
            ListTile(
              leading: const Icon(Icons.auto_awesome_motion_outlined),
              title: const Text('Ma galerie'),
              subtitle: const Text('Mes moments : où, quand, avec qui'),
              onTap: () => Navigator.pop(context, 'galerie'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choix == null || !context.mounted) return;
    if (choix == 'galerie') {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const GalleryScreen()));
      return;
    }
    await _editer(context, ref, profile, bio: choix == 'bio');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final profile = ref.watch(myProfileProvider).value;
    final items = ref.watch(libraryItemsProvider(me));
    // Les publications en cours d'envoi, dans la grille avec leur avancement
    // (2026-09-19). Celles que la liste contient déjà sont acquittées.
    final pending = ref.watch(pendingPublicationsProvider);
    if (items.hasValue && pending.any((p) => p.isDone)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(pendingPublicationsProvider.notifier)
            .seen(items.requireValue.map((i) => i.id));
      });
    }

    // Le fil des publications se pose PAR-DESSUS ce profil (voir
    // [CoverHost]) : la barre de navigation reste, et un balayage vers la
    // droite découvre le profil.
    return CoverHost(
      child: Scaffold(
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
              if (profile != null)
                ProfileHeader(
                  profile: profile,
                  onAddBio: () => _editer(context, ref, profile, bio: true),
                  // Le compteur d'amis ouvre la liste recherchable (consigne Jay)
                  onFriendsTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const FriendsListScreen(),
                    ),
                  ),
                ),
              // La photo temporaire de l'arrivée en soirée (2026-09-24).
              if (profile != null &&
                  profile.avatarUrl != null &&
                  profile.avatarUrl == ref.watch(arrivalAvatarProvider))
                _TemporaryPhoto(
                  onChange: () => _editer(context, ref, profile),
                  onKeep: () =>
                      ref.read(arrivalAvatarProvider.notifier).forget(),
                ),
              // Ma galerie : mes Vibes, datées et situées (2026-09-25).
              ListTile(
                leading: const Icon(Icons.auto_awesome_motion_outlined),
                title: const Text('Ma galerie'),
                subtitle: const Text('Mes Vibes : quand, où, quelle soirée'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const GalleryScreen()),
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
                    // Publier une Vibe : notre caméra, restreinte à la
                    // publication (pas de story, pas d'amis : la destination
                    // est imposée). Un seul format depuis le 2026-09-21 —
                    // plus de choix entre Vibe, photos/vidéos et Flow.
                    IconButton(
                      icon: const Icon(Icons.add_box_outlined),
                      tooltip: 'Publier une Vibe',
                      onPressed: () => Navigator.of(context).push(
                        NeoFadeRoute(
                          builder: (_) =>
                              const CardCaptureScreen(publicationOnly: true),
                        ),
                      ),
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
                  pending: pending,
                  emptyMessage:
                      'Ta bibliothèque est vide.\nPublie une Vibe : ici, ça '
                      'reste.',
                  onLongPress: (item) async {
                    final delete = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text(
                          'Retirer cette Vibe de la bibliothèque ?',
                        ),
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
      ),
    );
  }
}

/// « Ta photo, c'est ton selfie d'arrivée » — la proposition de la changer,
/// tant qu'elle est encore celle déposée à l'inscription.
class _TemporaryPhoto extends StatelessWidget {
  const _TemporaryPhoto({required this.onChange, required this.onKeep});

  final VoidCallback onChange;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(NeoRadius.md),
          border: Border.all(color: p.action.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ta photo, c\'est ton selfie d\'arrivée.',
              style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
            ),
            const SizedBox(height: 2),
            Text(
              'Tu en choisis une autre, ou tu la gardes ?',
              style: TextStyle(color: p.inkMuted),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onKeep, child: const Text('Je la garde')),
                TextButton(onPressed: onChange, child: const Text('Changer')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
