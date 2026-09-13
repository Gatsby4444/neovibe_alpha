import 'package:flutter/foundation.dart';

import '../../../core/models/profile.dart';
import '../../connections/friendship.dart';
import '../../proximity/net/crossed_repository.dart';

/// **Qui peut recevoir une Vibe — la liste « Groupes et amis », dans l'ordre
/// voulu par Jay (2026-09-14).**
///
/// > *« On fait comme sur Snap : les 10 amis les plus proches dans un tableau
/// > 2 colonnes […] en dessous la liste des groupes triée [par participation
/// > récente], et ensuite la liste de tous les amis et tous les groupes
/// > classés selon l'interaction la plus récente. »*
///
/// ## Ce fichier est PUR
///
/// Aucun réseau, aucun provider, aucun widget : des listes en entrée, trois
/// blocs ordonnés en sortie. C'est ce qui permet d'éprouver l'ordre sans
/// lancer l'app — et l'ordre est précisément ce qui distingue « fluide » de
/// « il faut chercher ». Le provider (`recipients_provider.dart`) ne fait que
/// brancher les sources ; l'écran ne fait que dessiner.
///
/// ## Les trois dates qui décident
///
/// | Bloc | Clé de tri | D'où elle vient |
/// |---|---|---|
/// | les 10 plus proches | **palier**, puis interaction | `friendships` (palier), `conversations.last_activity_at` du DM |
/// | les groupes | **ma participation** | `conversation_participation` (mon dernier message) |
/// | tout le monde | **interaction** | `conversations.last_activity_at` |
///
/// ⚠️ Ces dates **survivent à la purge des messages** : elles sont
/// entretenues par un trigger serveur, pas recalculées sur les 24 dernières
/// heures. Sans ça, un groupe où j'ai parlé avant-hier serait indiscernable
/// d'un groupe où je n'ai jamais parlé.

/// Une personne ou un groupe à qui envoyer.
sealed class Recipient {
  const Recipient();

  /// L'identifiant sous lequel l'écran coche la ligne.
  String get key;

  /// Ce que la recherche compare.
  String get searchText;
}

/// Un ami — avec ou sans conversation existante. **Sans** : le DM s'ouvrira
/// à l'envoi (`get_or_create_direct_conversation`), l'ami n'a pas à avoir
/// déjà discuté pour recevoir.
class FriendRecipient extends Recipient {
  const FriendRecipient({
    required this.profile,
    required this.tier,
    required this.serie,
    this.conversationId,
    this.lastActivityAt,
  });

  final Profile profile;
  final FriendshipTier tier;

  /// La série de croisements, en jours (🔥).
  final int serie;

  /// Le DM avec cet ami, s'il existe déjà.
  final String? conversationId;

  /// Le dernier message du DM, de qui que ce soit.
  final DateTime? lastActivityAt;

  String get userId => profile.id;

  @override
  String get key => 'friend:$userId';

  @override
  String get searchText => '${profile.chatName} ${profile.tagName ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is FriendRecipient &&
      other.profile == profile &&
      other.tier == tier &&
      other.serie == serie &&
      other.conversationId == conversationId &&
      other.lastActivityAt == lastActivityAt;

  @override
  int get hashCode =>
      Object.hash(profile, tier, serie, conversationId, lastActivityAt);
}

/// Un groupe — ou le chat d'un événement.
class GroupRecipient extends Recipient {
  const GroupRecipient({
    required this.conversationId,
    required this.label,
    required this.memberIds,
    this.isEvent = false,
    this.lastActivityAt,
    this.myLastAt,
  });

  final String conversationId;
  final String label;

  /// Les membres sans moi : ce sont les destinataires d'une livraison.
  final List<String> memberIds;

  /// Le chat d'un événement (privé) auquel je participe.
  final bool isEvent;

  /// Le dernier message du groupe, de qui que ce soit.
  final DateTime? lastActivityAt;

  /// Mon dernier message dans ce groupe — « ma participation ».
  final DateTime? myLastAt;

  @override
  String get key => 'conv:$conversationId';

  @override
  String get searchText => label;

  @override
  bool operator ==(Object other) =>
      other is GroupRecipient &&
      other.conversationId == conversationId &&
      other.label == label &&
      listEquals(other.memberIds, memberIds) &&
      other.isEvent == isEvent &&
      other.lastActivityAt == lastActivityAt &&
      other.myLastAt == myLastAt;

  @override
  int get hashCode => Object.hash(
    conversationId,
    label,
    Object.hashAll(memberIds),
    isEvent,
    lastActivityAt,
    myLastAt,
  );
}

/// La liste entière, en blocs, prête à dessiner.
@immutable
class RecipientCatalog {
  const RecipientCatalog({
    required this.closest,
    required this.groups,
    required this.everyone,
    required this.crossed,
    this.currentEvent,
  });

  static const empty = RecipientCatalog(
    closest: [],
    groups: [],
    everyone: [],
    crossed: [],
  );

  /// Combien d'amis dans le tableau du haut (Jay : « les 10 amis les plus
  /// proches »).
  static const closestCount = 10;

  /// Le tableau 2 colonnes : au plus [closestCount] amis, par palier puis
  /// par interaction.
  final List<FriendRecipient> closest;

  /// Les groupes, par ma participation la plus récente.
  final List<GroupRecipient> groups;

  /// Tous les amis et tous les groupes, par interaction la plus récente.
  final List<Recipient> everyone;

  /// Les gens croisés récemment (une demande d'ami qui porte la Vibe).
  final List<CrossedPerson> crossed;

  /// Le chat de l'événement où je suis, s'il y en a un — il figure aussi dans
  /// [groups], mais l'écran le met **tout en haut** (Jay, 2026-09-14).
  final GroupRecipient? currentEvent;

  bool get isEmpty =>
      closest.isEmpty && groups.isEmpty && everyone.isEmpty && crossed.isEmpty;

  /// **Construit l'ordre.** Pure : c'est ce qui se teste.
  ///
  /// - [friends] : mes amis avec leur palier ;
  /// - [directConversations] : mes DM, par identifiant d'ami d'en face ;
  /// - [groupConversations] : mes groupes (et chats d'événements) ;
  /// - [myLastAt] : ma participation, par conversation ;
  /// - [currentEventConversationId] : le chat de l'événement en cours.
  static RecipientCatalog build({
    required List<FriendRecipient> friends,
    required List<GroupRecipient> groups,
    required List<CrossedPerson> crossed,
    String? currentEventConversationId,
  }) {
    // Les plus proches : le palier d'abord (inséparables > proches > amis),
    // l'interaction ensuite, le nom enfin — pour que deux amis sans aucune
    // date gardent un ordre stable d'une ouverture à l'autre.
    final parProximite = [...friends]
      ..sort((a, b) {
        final palier = b.tier.index.compareTo(a.tier.index);
        if (palier != 0) return palier;
        final date = _plusRecent(a.lastActivityAt, b.lastActivityAt);
        if (date != 0) return date;
        return a.profile.chatName.toLowerCase().compareTo(
          b.profile.chatName.toLowerCase(),
        );
      });
    final closest = parProximite.take(closestCount).toList(growable: false);

    // Les groupes : ma participation d'abord ; un groupe où je n'ai jamais
    // écrit se range après, par activité, puis par nom.
    final groupesTries = [...groups]
      ..sort((a, b) {
        final participation = _plusRecent(a.myLastAt, b.myLastAt);
        if (participation != 0) return participation;
        final activite = _plusRecent(a.lastActivityAt, b.lastActivityAt);
        if (activite != 0) return activite;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

    // Tout le monde : l'interaction la plus récente, sans distinction ami /
    // groupe. Sans date, le nom.
    final tous = <Recipient>[...friends, ...groups]
      ..sort((a, b) {
        final date = _plusRecent(_activite(a), _activite(b));
        if (date != 0) return date;
        return a.searchText.toLowerCase().compareTo(b.searchText.toLowerCase());
      });

    GroupRecipient? evenement;
    if (currentEventConversationId != null) {
      for (final g in groups) {
        if (g.conversationId == currentEventConversationId) evenement = g;
      }
    }

    return RecipientCatalog(
      closest: closest,
      groups: groupesTries,
      everyone: tous,
      crossed: crossed,
      currentEvent: evenement,
    );
  }

  static DateTime? _activite(Recipient r) => switch (r) {
    FriendRecipient(:final lastActivityAt) => lastActivityAt,
    GroupRecipient(:final lastActivityAt) => lastActivityAt,
  };

  /// Plus récent d'abord ; l'absence de date passe après toute date.
  static int _plusRecent(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return b.compareTo(a);
  }

  /// La même liste, réduite à ce qui contient [query]. Vide = tout.
  ///
  /// ⚠️ Quand on cherche, le tableau des plus proches s'efface : on cherche
  /// **quelqu'un**, pas une position dans un tableau.
  RecipientCatalog filter(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return this;
    bool garde(String texte) => texte.toLowerCase().contains(q);
    return RecipientCatalog(
      closest: const [],
      groups: const [],
      everyone: [
        for (final r in everyone)
          if (garde(r.searchText)) r,
      ],
      crossed: [
        for (final c in crossed)
          if (garde(c.displayName) || garde(c.tagName ?? '')) c,
      ],
      currentEvent: currentEvent == null || !garde(currentEvent!.label)
          ? null
          : currentEvent,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RecipientCatalog &&
      listEquals(other.closest, closest) &&
      listEquals(other.groups, groups) &&
      listEquals(other.everyone, everyone) &&
      listEquals(other.crossed, crossed) &&
      other.currentEvent == currentEvent;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(closest),
    Object.hashAll(groups),
    Object.hashAll(everyone),
    Object.hashAll(crossed),
    currentEvent,
  );
}
