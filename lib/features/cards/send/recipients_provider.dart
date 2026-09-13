import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/message.dart';
import '../../../core/supabase_providers.dart';
import '../../connections/connections_repository.dart';
import '../../connections/friendship.dart';
import '../../connections/friendships_repository.dart';
import '../../conversations/conversations_repository.dart';
import '../../events/events_providers.dart';
import '../../proximity/net/crossed_repository.dart';
import 'recipients.dart';

/// **LE SERVEUR** entre les sources et l'écran « À qui ? » : la liste
/// assemblée et ordonnée, qui ne réveille l'écran que si elle change.
///
/// Quatre sources, chacune à son rythme : mes amis et leurs paliers
/// (`friendshipsProvider`, `friendProfilesProvider`), mes conversations
/// (`conversationsProvider` — les DM donnent leur date d'activité aux amis,
/// les groupes deviennent des lignes), ma participation
/// (`myParticipationProvider`), les croisés (`crossedRecentlyProvider`), et
/// l'événement en cours (`currentEventProvider`). L'ordre lui-même est calculé
/// par `RecipientCatalog.build`, pur et éprouvé.
///
/// Nul tant que les amis ou les conversations ne sont pas là : l'écran montre
/// alors son attente, jamais une liste à moitié vide qu'on prendrait pour la
/// vraie.
class _Recipients extends Notifier<RecipientCatalog?> {
  @override
  RecipientCatalog? build() {
    final me = ref.watch(currentUserIdProvider);
    if (me == null) return null;

    final amities = ref.watch(friendshipsProvider).value;
    final profils = ref.watch(friendProfilesProvider).value;
    final conversations = ref.watch(conversationsProvider).value;
    if (amities == null || profils == null || conversations == null) {
      return null;
    }
    // Les sources secondaires n'empêchent pas la liste d'exister : sans
    // participation, les groupes se rangent par activité ; sans croisés, le
    // bloc est vide.
    final participation = ref.watch(myParticipationProvider).value ?? const {};
    final croises = ref.watch(crossedRecentlyProvider).value ?? const [];
    final evenement = ref.watch(currentEventProvider);

    // Le DM de chaque ami, s'il existe : c'est lui qui porte l'interaction.
    final dmParAmi = <String, Conversation>{};
    final groupes = <GroupRecipient>[];
    for (final c in conversations) {
      switch (c.type) {
        case ConversationType.direct:
          final autre = c.otherMember(me);
          if (autre != null) dmParAmi[autre.id] = c;
        case ConversationType.group:
        case ConversationType.event:
          groupes.add(
            GroupRecipient(
              conversationId: c.id,
              label: c.displayName(me),
              memberIds: [
                for (final m in c.members)
                  if (m.id != me) m.id,
              ],
              isEvent: c.type == ConversationType.event,
              lastActivityAt: c.lastActivityAt,
              myLastAt: participation[c.id],
            ),
          );
        case ConversationType.proximity:
          // Un canal de proximité se ferme dès qu'on ne s'entend plus : le
          // proposer ici afficherait un bouton dont le seul effet possible est
          // un refus du serveur.
          break;
      }
    }

    final amis = <FriendRecipient>[];
    for (final entry in profils.entries) {
      final amitie = amities[entry.key];
      final dm = dmParAmi[entry.key];
      amis.add(
        FriendRecipient(
          profile: entry.value,
          tier: amitie?.tier ?? FriendshipTier.friend,
          serie: amitie?.serie ?? 0,
          conversationId: dm?.id,
          lastActivityAt: dm?.lastActivityAt,
        ),
      );
    }

    return RecipientCatalog.build(
      friends: amis,
      groups: groupes,
      crossed: croises,
      currentEventConversationId: evenement?.conversationId,
    );
  }

  // ⚠️ Égalité de VALEUR : sans elle, chaque relecture d'une source
  // reconstruirait l'écran entier, même quand rien n'a changé.
  @override
  bool updateShouldNotify(RecipientCatalog? previous, RecipientCatalog? next) =>
      previous != next;
}

final recipientsProvider = NotifierProvider<_Recipients, RecipientCatalog?>(
  _Recipients.new,
);
