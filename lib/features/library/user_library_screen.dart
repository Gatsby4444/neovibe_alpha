import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/connection.dart';
import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/widgets/content_overflow_menu.dart';
import '../connections/connections_repository.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
import '../proximity/net/proximity_controller.dart';
import 'library_deck_screen.dart';
import 'library_repository.dart';
import 'mini_card.dart';
import 'profile_header.dart';

/// Profil d'un autre utilisateur — connexion OU personne croisée en ping.
/// En-tête commun (PP, username, stats, bio) + bibliothèque : la RLS ne
/// laisse passer que ce que j'ai le droit de voir (tout pour une connexion
/// selon ses règles, uniquement les contenus PUBLICS pour un simple croisé).
/// Actions (consigne Jay 2026-07-12) : Message + Ajouter côte à côte.
class UserLibraryScreen extends ConsumerWidget {
  const UserLibraryScreen({super.key, required this.profile});
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final items = ref.watch(libraryItemsProvider(profile.id));
    final connections = ref.watch(fullConnectionsProvider);
    final isConnected = connections.any((c) => c.peerIdFor(me) == profile.id);
    final inRange = ref.watch(peerInRangeProvider(profile.id));

    return Scaffold(
      appBar: AppBar(
        title: Text(profile.displayName),
        // Signaler / bloquer une PERSONNE. Sans ce point d'entrée, le
        // signalement de profil était inatteignable (v0.9.53 → 2026-08-12) : le
        // menu n'existait que sur les stories et les publications. C'est aussi
        // le seul recours pour une Vibe reçue en DM, qui n'a pas de Content ID.
        actions: [
          // ⚠️ **Retirer un ami n'avait AUCUN bouton** jusqu'au 2026-08-27.
          // `ConnectionsRepository.remove` existait, la politique RLS aussi —
          // seule l'entrée manquait. Un geste que le produit autorise mais que
          // l'interface ne propose pas n'existe pas.
          if (profile.id != me && isConnected)
            IconButton(
              tooltip: 'Retirer de mes amis',
              icon: const Icon(Icons.person_remove_alt_1_outlined),
              onPressed: () => _retirer(context, ref, connections, me),
            ),
          if (profile.id != me)
            ContentOverflowMenu(
              authorId: profile.id,
              authorName: profile.displayName,
              color:
                  Theme.of(context).appBarTheme.foregroundColor ??
                  Theme.of(context).colorScheme.onSurface,
            ),
        ],
      ),
      body: ListView(
        children: [
          ProfileHeader(profile: profile),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                if (isConnected)
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Message'),
                      onPressed: () => _openDirect(context, ref),
                    ),
                  )
                else if (inRange) ...[
                  // ⚠️ **Les deux boutons BLE ont été retirés le 2026-08-27.**
                  //
                  // Ils ouvraient une conversation ping LOCALE et envoyaient une
                  // demande de connexion co-signée d'appareil à appareil. Les
                  // deux fonctions passent désormais par le serveur (décision de
                  // Jay : *« le BLE ne sert qu'à valider et authentifier la
                  // proximité réelle »*), et le chemin serveur vit sur l'écran
                  // Ping, sur la personne elle-même.
                  //
                  // Les laisser aurait fait **deux boutons « Ajouter » dans
                  // l'app qui font deux choses différentes** — un chemin, une
                  // donnée : c'est le défaut que ce projet traque le plus.
                  Expanded(
                    child: Text(
                      "À portée — retrouve-le dans Ping pour lui écrire ou "
                      "l'ajouter.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.muted),
                    ),
                  ),
                ] else
                  Expanded(
                    child: Text(
                      'Hors de portée — recroisez-vous pour échanger.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.muted),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Bibliothèque',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.view_carousel_outlined),
                  tooltip: 'Parcourir en deck',
                  onPressed: () {
                    final list = items.value;
                    if (list == null || list.isEmpty) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LibraryDeckScreen(
                          items: list,
                          title: profile.displayName,
                        ),
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
                      'Rien à voir ici — bibliothèque vide ou accès restreint.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.muted),
                    ),
                  )
                : GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(10),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: kMiniCardRatio,
                        ),
                    itemCount: list.length,
                    itemBuilder: (context, index) =>
                        MiniCard(item: list[index]),
                  ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Retire cette personne de mes amis.
  ///
  /// ⚠️ **Une confirmation, et qui dit le VRAI coût.** Depuis le 2026-08-27,
  /// redevenir amis exige une **proximité physique prouvée** : le serveur refuse
  /// toute demande sans paire mutuelle fraîche. Ce n'est donc plus un geste
  /// qu'on défait d'un clic — il faut se recroiser. Le dire avant, c'est la
  /// différence entre un choix et un accident.
  Future<void> _retirer(
    BuildContext context,
    WidgetRef ref,
    List<Connection> connections,
    String me,
  ) async {
    final lien = connections
        .where((c) => c.peerIdFor(me) == profile.id)
        .firstOrNull;
    if (lien == null) return;

    final confirme = await showDialog<bool>(
      context: context,
      builder: (dialogue) => AlertDialog(
        title: Text('Retirer ${profile.displayName} ?'),
        content: const Text(
          "Vous ne vous verrez plus en proximité, et vos croisements "
          "s'arrêteront. Pour redevenir amis, il faudra vous RECROISER "
          "PHYSIQUEMENT : une demande n'est acceptée que si la proximité "
          "est prouvée des deux côtés.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogue).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogue).pop(true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (confirme != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(connectionsRepositoryProvider).remove(lien.id);
      // ⚠️ **L'invalidation appartient à l'ÉCRITURE**, pas à l'appelant : deux
      // écrans qui retirent un ami doivent laisser le lecteur dans le même état.
      ref.invalidate(fullConnectionsProvider);
      messenger.showSnackBar(
        SnackBar(content: Text('${profile.displayName} a été retiré.')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(messageServeur(e))));
    }
  }

  Future<void> _openDirect(BuildContext context, WidgetRef ref) async {
    // ⚠️ **Un appui qui n'aboutit à RIEN est le pire des retours.** Sans ce
    // garde-fou, un échec de la RPC laissait l'écran exactement dans l'état où
    // il était : pas de conversation, pas d'erreur, rien. L'utilisateur n'a
    // alors d'autre hypothèse que « le bouton ne marche pas ».
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final String convId;
    try {
      convId = await ref
          .read(conversationsRepositoryProvider)
          .getOrCreateDirect(profile.id);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Impossible d'ouvrir la conversation pour l'instant."),
        ),
      );
      return;
    }
    navigator.push(
      MaterialPageRoute(builder: (_) => ChatScreen(conversationId: convId)),
    );
  }
}
