import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../cards/cards_repository.dart';

/// En-tête de profil (consigne Jay 2026-07-12) : PP + username en haut,
/// stats (amis / posts / cards 7 jours), bio, tag name.
/// Réutilisé sur mon profil et sur celui d'une connexion.
class ProfileHeader extends ConsumerWidget {
  const ProfileHeader({super.key, required this.profile});
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(profileStatsProvider(profile.id)).value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        children: [
          CircleAvatar(
            radius: 44,
            backgroundImage: profile.avatarUrl == null
                ? null
                : NetworkImage(profile.avatarUrl!),
            child: profile.avatarUrl == null
                ? Text(
                    profile.displayName.characters.first.toUpperCase(),
                    style: const TextStyle(fontSize: 30),
                  )
                : null,
          ),
          const SizedBox(height: 10),
          Text(
            profile.displayName,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (profile.tagName != null && profile.tagName!.isNotEmpty)
            Text(
              '« ${profile.tagName} » en conversation',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          const SizedBox(height: 14),
          if (stats != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _Stat(value: stats.friends, label: 'amis'),
                _Stat(value: stats.posts, label: 'posts'),
                _Stat(value: stats.cardsWeek, label: 'cards / 7 j'),
              ],
            ),
          if (profile.bio != null && profile.bio!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                profile.bio!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.white54),
        ),
      ],
    );
  }
}
