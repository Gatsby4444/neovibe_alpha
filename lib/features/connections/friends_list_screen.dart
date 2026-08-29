import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../library/user_library_screen.dart';
import 'connections_repository.dart';
import 'tier_avatar.dart';
import 'friendships_repository.dart';
import 'friendship.dart';
import '../../core/typography.dart';

/// Liste des amis (consigne Jay 2026-07-12) : ouverte depuis le compteur
/// d'amis du profil — username + PP + barre de recherche.
class FriendsListScreen extends ConsumerStatefulWidget {
  const FriendsListScreen({super.key});

  @override
  ConsumerState<FriendsListScreen> createState() => _FriendsListScreenState();
}

class _FriendsListScreenState extends ConsumerState<FriendsListScreen> {
  var _query = '';

  /// Le filtre par palier. ⚠️ Il vit dans l'ÉCRAN et non dans un provider :
  /// c'est un état d'affichage, propre à cette page et à cette visite. Le
  /// hisser au niveau de l'app le ferait persister d'un écran à l'autre, et
  /// Jay retrouverait sa liste filtrée sans savoir pourquoi.
  var _filtre = FiltreDePalier.tous;

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mes amis')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              decoration: const InputDecoration(
                hintText: 'Rechercher un ami…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          // ⚠️ La rangée n'apparaît QUE s'il y a des paliers à filtrer.
          // Trois puces devant une liste où tout le monde est au même palier
          // ne trient rien : elles promettent une distinction qui n'existe pas
          // encore, et l'utilisateur croit à une panne.
          if (ref
                  .watch(friendshipsProvider)
                  .value
                  ?.values
                  .any((f) => f.tier.porteUnAnneau) ??
              false)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NeoSpace.lg,
                NeoSpace.sm,
                NeoSpace.lg,
                NeoSpace.xs,
              ),
              child: Row(
                children: [
                  for (final f in FiltreDePalier.values)
                    Padding(
                      padding: const EdgeInsets.only(right: NeoSpace.sm),
                      child: ChoiceChip(
                        label: Text(f.label),
                        selected: _filtre == f,
                        onSelected: (_) => setState(() => _filtre = f),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: connections.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Personne pour l\'instant. Tes connexions naissent '
                        'dans la vraie vie : active ta visibilité quand tu sors.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.muted),
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (final connection in connections)
                        _FriendTile(
                          peerId: connection.peerIdFor(me),
                          query: _query,
                          filtre: _filtre,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _FriendTile extends ConsumerWidget {
  const _FriendTile({
    required this.peerId,
    required this.query,
    required this.filtre,
  });
  final String peerId;
  final String query;
  final FiltreDePalier filtre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Profile? peer = ref.watch(profileByIdProvider(peerId)).value;
    if (peer == null) return const SizedBox.shrink();
    if (query.isNotEmpty &&
        !peer.displayName.toLowerCase().contains(query) &&
        !(peer.tagName?.toLowerCase().contains(query) ?? false)) {
      return const SizedBox.shrink();
    }

    final amitie = ref.watch(friendshipsProvider).value?[peerId];
    final tier = amitie?.tier ?? FriendshipTier.friend;
    if (!filtre.retient(tier)) return const SizedBox.shrink();

    return ListTile(
      leading: TierAvatar(
        peerId: peerId,
        storedAvatar: peer.avatarUrl,
        initiale: peer.displayName.characters.first.toUpperCase(),
      ),
      title: Text(peer.displayName),
      subtitle: _Sousligne(peer: peer, amitie: amitie),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => UserLibraryScreen(profile: peer)),
      ),
    );
  }
}

/// Sous le pseudo : le tag, le palier s'il y en a un, et la série si elle a
/// commencé.
///
/// ⚠️ **Rien n'est calculé ici.** Le palier, les jours et la série arrivent du
/// serveur ; cet écran ne fait que les mettre bout à bout. Un seuil recopié ici
/// serait une seconde définition de la règle, et c'est celle-là qui finirait
/// par mentir.
class _Sousligne extends StatelessWidget {
  const _Sousligne({required this.peer, required this.amitie});

  final Profile peer;
  final Friendship? amitie;

  @override
  Widget build(BuildContext context) {
    final morceaux = <String>[
      if (peer.tagName != null && peer.tagName!.isNotEmpty) peer.tagName!,
      if (amitie != null && amitie!.tier.porteUnAnneau) amitie!.tier.label,
      if (amitie != null && amitie!.serie > 0)
        '${PalierDeSerie.pour(amitie!.serie).emoji} ${amitie!.serie} j',
    ];
    if (morceaux.isEmpty) return const SizedBox.shrink();
    return Text(morceaux.join(' · '));
  }
}
