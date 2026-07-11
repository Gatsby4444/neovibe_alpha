import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import 'library_repository.dart';
import 'profile_screen.dart';

/// Bibliothèque d'une connexion — la RLS applique ses droits d'accès :
/// liste vide si l'accès m'est restreint.
class UserLibraryScreen extends ConsumerWidget {
  const UserLibraryScreen({super.key, required this.profile});
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(libraryItemsProvider(profile.id));

    return Scaffold(
      appBar: AppBar(title: Text(profile.displayName)),
      body: items.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (list) => list.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Rien à voir ici — bibliothèque vide ou accès restreint.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              )
            : GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemCount: list.length,
                itemBuilder: (context, index) => LibraryTile(item: list[index]),
              ),
      ),
    );
  }
}
