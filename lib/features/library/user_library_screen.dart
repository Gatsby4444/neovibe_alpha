import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import 'library_repository.dart';
import 'profile_header.dart';
import 'profile_screen.dart';

/// Profil d'une connexion : même en-tête que le mien (PP, username, stats,
/// bio) + sa bibliothèque publique — la RLS applique ses droits d'accès.
class UserLibraryScreen extends ConsumerWidget {
  const UserLibraryScreen({super.key, required this.profile});
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(libraryItemsProvider(profile.id));

    return Scaffold(
      appBar: AppBar(title: Text(profile.displayName)),
      body: ListView(
        children: [
          ProfileHeader(profile: profile),
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
                      'Rien à voir ici — bibliothèque vide ou accès restreint.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                        ),
                    itemCount: list.length,
                    itemBuilder: (context, index) =>
                        LibraryTile(item: list[index]),
                  ),
          ),
        ],
      ),
    );
  }
}
