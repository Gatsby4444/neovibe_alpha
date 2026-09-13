import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../cards/send/share_defaults.dart';
import '../../cards/send/share_settings_sheets.dart';
import '../../connections/connections_repository.dart';
import '../../connections/friendship.dart';
import '../../connections/tier_avatar.dart';
import '../settings_common.dart';
import 'vibes_settings_screen.dart';

/// **Réglages → Défauts de partage** — la nouvelle entrée demandée par Jay
/// (2026-09-14) : ce que l'écran « À qui ? » coche quand on n'a rien réglé.
///
/// Trois blocs : les publications (story, bibliothèque), les groupes et amis
/// (« Sauvegardable » général, et **par ami**), et le renvoi vers les limites
/// de vues, qui gardent leur propriétaire historique (Réglages → Vibes).
///
/// Écrit **exactement là où les sur-écrans ⚙︎ écrivent** : `shareDefaults`
/// (préférence) et `friend_share_defaults` (serveur). Un réglage, un
/// propriétaire — deux chemins d'écriture, une seule valeur.
class ShareDefaultsScreen extends ConsumerWidget {
  const ShareDefaultsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defauts = ref.watch(shareDefaultsProvider);
    final notifier = ref.read(shareDefaultsProvider.notifier);
    final story = defauts.story;
    final library = defauts.library;

    return Scaffold(
      appBar: AppBar(title: const Text('Défauts de partage')),
      body: ListView(
        children: [
          const SettingsHeader('Publier'),
          const SettingsNote(
            'Ce qui est coché quand tu choisis « Story » ou « Bibliothèque ». '
            'Modifiable à chaque envoi, dans la roue ⚙︎.',
          ),
          _Bloc(
            titre: 'Ma story — visible par',
            child: Wrap(
              spacing: NeoSpace.sm,
              runSpacing: NeoSpace.xs,
              children: [
                for (final t in FriendshipTier.values)
                  SettingChip(
                    label: switch (t) {
                      FriendshipTier.friend => 'Tous mes amis',
                      FriendshipTier.close => 'Mes proches',
                      FriendshipTier.inner => 'Mes inséparables',
                    },
                    actif: story.tier == t,
                    onTap: () => notifier.set(
                      defauts.copyWith(story: story.copyWith(tier: t)),
                    ),
                  ),
              ],
            ),
          ),
          _Bloc(
            titre: 'Ma story',
            child: Wrap(
              spacing: NeoSpace.sm,
              runSpacing: NeoSpace.xs,
              children: [
                SettingChip(
                  label: 'Partageable',
                  actif: story.shareable,
                  onTap: () => notifier.set(
                    defauts.copyWith(
                      story: story.copyWith(shareable: !story.shareable),
                    ),
                  ),
                ),
                SettingChip(
                  label: 'Sauvegardable',
                  actif: story.saveable,
                  onTap: () => notifier.set(
                    defauts.copyWith(
                      story: story.copyWith(saveable: !story.saveable),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _Bloc(
            titre: 'Ma bibliothèque',
            child: Wrap(
              spacing: NeoSpace.sm,
              runSpacing: NeoSpace.xs,
              children: [
                SettingChip(
                  label: 'Visible par les gens que tu croises',
                  actif: library.isPublic,
                  onTap: () => notifier.set(
                    defauts.copyWith(
                      library: library.copyWith(isPublic: !library.isPublic),
                    ),
                  ),
                ),
                SettingChip(
                  label: 'Partageable',
                  actif: library.shareable,
                  onTap: () => notifier.set(
                    defauts.copyWith(
                      library: library.copyWith(shareable: !library.shareable),
                    ),
                  ),
                ),
                SettingChip(
                  label: 'Sauvegardable',
                  actif: library.saveable,
                  onTap: () => notifier.set(
                    defauts.copyWith(
                      library: library.copyWith(saveable: !library.saveable),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          const SettingsHeader('Groupes et amis'),
          SwitchListTile(
            title: const Text('Sauvegardable par défaut'),
            subtitle: const Text(
              'Pour les amis et groupes sans réglage propre. Les '
              'destinataires pourront garder la Vibe dans leurs '
              'Enregistrements.',
            ),
            value: defauts.peopleSaveable,
            onChanged: (v) => notifier.set(defauts.copyWith(peopleSaveable: v)),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Limites de vues et durée'),
            subtitle: const Text('Dans Réglages → Vibes → Défauts d\'envoi'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const VibesSettingsScreen()),
            ),
          ),
          const Divider(),
          const SettingsHeader('Par ami'),
          const SettingsNote(
            '« Pour Léa, toujours sauvegardable. » Un réglage par ami, qui '
            'passe avant le défaut général. Se règle aussi dans la roue ⚙︎ de '
            'l\'écran de partage (bouton « Défauts »).',
          ),
          const _FriendDefaultsList(),
        ],
      ),
    );
  }
}

class _Bloc extends StatelessWidget {
  const _Bloc({required this.titre, required this.child});
  final String titre;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NeoSpace.lg,
      NeoSpace.sm,
      NeoSpace.lg,
      NeoSpace.sm,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(titre, style: TextStyle(color: context.muted, fontSize: 12)),
        const SizedBox(height: NeoSpace.xs),
        child,
      ],
    ),
  );
}

/// Chaque ami, avec son état : son défaut propre (oui / non) ou « comme le
/// défaut général ».
class _FriendDefaultsList extends ConsumerWidget {
  const _FriendDefaultsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider);
    if (me == null) return const SizedBox.shrink();
    final profils = ref.watch(friendProfilesProvider).value ?? const {};
    final parAmi = ref.watch(friendShareDefaultsProvider).value ?? const {};
    final general = ref.watch(shareDefaultsProvider).peopleSaveable;
    final repo = ref.read(friendShareDefaultsRepositoryProvider);

    if (profils.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(NeoSpace.lg),
        child: Text('Aucun ami pour l\'instant.'),
      );
    }
    final amis = profils.values.toList()
      ..sort(
        (a, b) => a.chatName.toLowerCase().compareTo(b.chatName.toLowerCase()),
      );

    return Column(
      children: [
        for (final p in amis)
          ListTile(
            leading: TierAvatar(
              peerId: p.id,
              storedAvatar: p.avatarUrl,
              initiale: p.chatName.characters.first.toUpperCase(),
              size: 36,
            ),
            title: Text(p.chatName),
            subtitle: Text(
              parAmi.containsKey(p.id)
                  ? (parAmi[p.id]! ? 'Sauvegardable' : 'Non sauvegardable')
                  : 'Comme le défaut général (${general ? 'oui' : 'non'})',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            // Trois états en un bouton : propre oui → propre non → général.
            trailing: SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(value: 1, label: Text('Oui')),
                ButtonSegment(value: 0, label: Text('Non')),
                ButtonSegment(value: -1, label: Text('Défaut')),
              ],
              selected: {
                parAmi.containsKey(p.id) ? (parAmi[p.id]! ? 1 : 0) : -1,
              },
              onSelectionChanged: (s) {
                final v = s.first;
                if (v == -1) {
                  repo.clear(p.id);
                } else {
                  repo.setMany({p.id: v == 1});
                }
              },
            ),
          ),
      ],
    );
  }
}
