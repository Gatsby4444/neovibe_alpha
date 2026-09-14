import '../../../core/models/card.dart';
import '../../connections/friendship.dart';

/// **Ce que l'utilisateur a coché, et les règles PROPRES à chaque destination.**
///
/// ## 🔴 Le défaut que ce fichier supprime — demande de Jay, 2026-08-30
///
/// > *« sur Snap on peut partager à la fois en story et à des amis […] il
/// > faudrait rendre le partage aussi simple et aussi polyvalent »*
///
/// La décision du 2026-08-11 — *un contenu part dans un seul contexte* — avait
/// été lue comme *« un envoi = une destination »*. **C'était une erreur de
/// lecture** : la règle parle des OBJETS, pas des ÉCRANS. Snapchat aussi crée
/// plusieurs objets quand on coche une story et trois amis ; il épargne
/// seulement les trois allers-retours.
///
/// ## ⚠️ Ce qui rend ce plan compatible avec la séparation
///
/// **Chaque destination porte SES réglages**, et il n'existe aucun réglage
/// global au plan. C'est exactement ce que l'écran unique d'avant le
/// 2026-08-14 faisait mal : un `shareable` activé pour une story repartait
/// avec une publication sans que rien ne l'annonce. Ici, un réglage vit dans
/// l'objet de sa destination et ne peut pas en sortir — le type l'interdit.
///
/// ## ⚠️ Classe PURE
///
/// Aucun réseau, aucun disque, aucun widget. Elle décrit une intention et sait
/// dire ce qui cloche. C'est ce qui permet d'éprouver les règles de cohérence
/// sans lancer l'app — et il n'y en avait **aucune** avant ce jour.

/// Une destination cochée, avec ce qu'elle seule sait régler.
sealed class ShareDestination {
  const ShareDestination();

  /// Un **contexte de diffusion** compte pour un objet créé, donc pour une
  /// montée de fichier. Voir [SharePlan.televersements].
  ///
  /// ⚠️ Deux amis dans la même conversation ne comptent qu'une fois : une Vibe
  /// envoyée à dix personnes, c'est **une** Card et dix livraisons.
  String get contexte;
}

/// **Ma story** — visible par mes amis, filtrée par palier, 24 h.
class StoryShare extends ShareDestination {
  const StoryShare({
    this.tier = FriendshipTier.friend,
    this.shareable = false,
    this.saveable = false,
  });

  /// À partir de quel palier d'amitié la story est visible.
  ///
  /// ⚠️ **C'est ce que Snapchat ne sait pas faire**, et le champ existe déjà
  /// en base (`stories.min_tier`). Deux boutons « amis / public » chez eux ;
  /// trois cercles réels ici, dérivés des jours de croisement.
  final FriendshipTier tier;

  final bool shareable;
  final bool saveable;

  @override
  String get contexte => 'story';

  StoryShare copyWith({
    FriendshipTier? tier,
    bool? shareable,
    bool? saveable,
  }) => StoryShare(
    tier: tier ?? this.tier,
    shareable: shareable ?? this.shareable,
    saveable: saveable ?? this.saveable,
  );
}

/// **Ma bibliothèque** — la grille du profil, permanente, sans limite de vues.
class LibraryShare extends ShareDestination {
  const LibraryShare({
    this.isPublic = false,
    this.shareable = false,
    this.saveable = false,
    this.caption,
  });

  final bool isPublic;
  final bool shareable;
  final bool saveable;
  final String? caption;

  @override
  String get contexte => 'bibliotheque';

  LibraryShare copyWith({
    bool? isPublic,
    bool? shareable,
    bool? saveable,
    String? caption,
  }) => LibraryShare(
    isPublic: isPublic ?? this.isPublic,
    shareable: shareable ?? this.shareable,
    saveable: saveable ?? this.saveable,
    caption: caption ?? this.caption,
  );
}

/// **Une conversation** — un ami ou un groupe. C'est le « cercle ».
///
/// ⚠️ **Toutes les conversations cochées ne coûtent QU'UN objet** : une seule
/// Card, autant de livraisons que de destinataires. C'est pour ça que
/// [SharePlan.televersements] les compte ensemble.
class ConversationShare extends ShareDestination {
  const ConversationShare({
    this.conversationId,
    this.peerId,
    required this.memberIds,
    required this.label,
    this.saveable = false,
    this.dansLeChat = true,
    this.aussiDansLaBibliotheque = false,
  }) : assert(
         conversationId != null || peerId != null,
         'une conversation ou un ami, jamais ni l\'un ni l\'autre',
       );

  /// La conversation — **nulle pour un ami avec qui on n'a jamais discuté** :
  /// le DM s'ouvrira à l'envoi (`get_or_create_direct_conversation`). Un ami
  /// n'a pas à avoir déjà parlé pour recevoir (constat n° 2 du plan).
  final String? conversationId;

  /// L'ami d'en face, pour un DM (existant ou à créer). Nul pour un groupe.
  final String? peerId;

  /// Ce qui identifie la ligne, avec ou sans conversation.
  String get key => conversationId ?? 'peer:$peerId';

  /// Les destinataires, sans moi. Dans un groupe, ce sont tous les autres.
  final List<String> memberIds;

  final String label;
  final bool saveable;

  /// 💬 — la Vibe part **dans le chat** : une Card, une livraison par membre.
  ///
  /// ## La ligne à deux cibles (Jay, 2026-09-14)
  ///
  /// Envoyer dans le chat (« regarde ça maintenant ») et ajouter à la
  /// bibliothèque (« on construit une collection, révélée au reveal ») sont
  /// deux gestes, deux objets, deux cycles de vie. Chaque ligne de groupe ou
  /// de DM porte donc **deux cibles** côte à côte, 💬 et 📚, et une ligne
  /// cochée en a au moins une. C'est un choix de *destination*, pas un
  /// réglage : il se voit sur la ligne, avant de cocher.
  final bool dansLeChat;

  /// 📚 — dans la **bibliothèque** de la conversation : le CINQUIÈME contexte.
  ///
  /// ⚠️ **C'est un objet de plus, pas une option de l'envoi.** La bibliothèque
  /// de conversation a son propre cycle de vie et son propre reveal ; la
  /// confondre avec la livraison ferait un seul fichier sous deux régimes,
  /// c'est-à-dire le défaut du 2026-08-11.
  final bool aussiDansLaBibliotheque;

  /// Une ligne sans aucune cible n'existe pas : elle est décochée.
  bool get vide => !dansLeChat && !aussiDansLaBibliotheque;

  /// Les clés des deux cibles — ce que « Réessayer » rend au plan.
  String get cleChat => 'conv:$key:chat';
  String get cleLibrary => 'conv:$key:lib';

  @override
  String get contexte => 'cercle';

  ConversationShare copyWith({
    bool? saveable,
    bool? dansLeChat,
    bool? aussiDansLaBibliotheque,
  }) => ConversationShare(
    conversationId: conversationId,
    peerId: peerId,
    memberIds: memberIds,
    label: label,
    saveable: saveable ?? this.saveable,
    dansLeChat: dansLeChat ?? this.dansLeChat,
    aussiDansLaBibliotheque:
        aussiDansLaBibliotheque ?? this.aussiDansLaBibliotheque,
  );

  @override
  bool operator ==(Object other) =>
      other is ConversationShare &&
      other.key == key &&
      other.saveable == saveable &&
      other.dansLeChat == dansLeChat &&
      other.aussiDansLaBibliotheque == aussiDansLaBibliotheque;

  @override
  int get hashCode =>
      Object.hash(key, saveable, dansLeChat, aussiDansLaBibliotheque);
}

/// **Quelqu'un qu'on a croisé** — pas encore un ami.
///
/// ## Ce que c'est vraiment
///
/// Une **demande d'ami qui porte une Vibe**, ouverte 24 h après un croisement
/// mutuel (`request_connection_with_vibe`). Pas un message : il n'existe aucun
/// canal de discussion vers un inconnu qu'on a quitté, et il ne doit pas en
/// exister — ce serait un canal de spam, l'inverse exact de la thèse.
///
/// ⚠️ **La fenêtre est plus large que celle de la demande nue (10 min) parce
/// que le geste coûte une capture.** C'est le coût du geste qui paie la
/// largeur de la fenêtre, pas une tolérance accordée au hasard.
class CrossedShare extends ShareDestination {
  const CrossedShare({required this.userId, required this.label});

  final String userId;
  final String label;

  String get cle => 'crossed:$userId';

  @override
  String get contexte => 'cercle';

  @override
  bool operator ==(Object other) =>
      other is CrossedShare && other.userId == userId;

  @override
  int get hashCode => userId.hashCode;
}

/// Les limites de visionnage d'une Vibe envoyée à des personnes.
class ViewingRules {
  const ViewingRules({
    this.maxViews,
    this.viewDurationSeconds,
    this.scrubbable = false,
  });

  /// `null` = sans limite de vues.
  final int? maxViews;

  /// `null` = durée par défaut. Ne s'applique qu'aux faces PHOTO : une face
  /// vidéo se lit en entier (consigne de Jay, 2026-07-12).
  final int? viewDurationSeconds;

  /// Le destinataire peut contrôler la barre de lecture des vidéos. Défaut :
  /// intouchable (consigne de Jay). Ne s'applique qu'aux faces vidéo.
  final bool scrubbable;

  ViewingRules copyWith({
    int? maxViews,
    bool effacerMaxViews = false,
    int? viewDurationSeconds,
    bool effacerDuree = false,
    bool? scrubbable,
  }) => ViewingRules(
    maxViews: effacerMaxViews ? null : (maxViews ?? this.maxViews),
    viewDurationSeconds: effacerDuree
        ? null
        : (viewDurationSeconds ?? this.viewDurationSeconds),
    scrubbable: scrubbable ?? this.scrubbable,
  );

  @override
  bool operator ==(Object other) =>
      other is ViewingRules &&
      other.maxViews == maxViews &&
      other.viewDurationSeconds == viewDurationSeconds &&
      other.scrubbable == scrubbable;

  @override
  int get hashCode => Object.hash(maxViews, viewDurationSeconds, scrubbable);
}

/// Un lot de personnes qui reçoivent **la même Card**.
///
/// ⚠️ **C'est l'unité qui coûte une montée de fichier.** Deux personnes dans le
/// même lot partagent la Card ; deux personnes dans deux lots en demandent
/// deux. Le lot se forme sur ce qu'une Card ne peut porter qu'une fois — pour
/// l'instant, `saveable`.
class CercleLot {
  CercleLot({required this.saveable});

  final bool saveable;
  final List<ConversationShare> conversations = [];
  final List<CrossedShare> crossed = [];

  /// Tous les destinataires du lot, croisés compris.
  int get destinataires =>
      conversations.fold<int>(0, (n, c) => n + c.memberIds.length) +
      crossed.length;
}

/// **Le plan complet : un geste, plusieurs objets.**
class SharePlan {
  const SharePlan({
    this.story,
    this.library,
    this.conversations = const [],
    this.crossed = const [],
    this.regles = const ViewingRules(),
  });

  final StoryShare? story;
  final LibraryShare? library;
  final List<ConversationShare> conversations;
  final List<CrossedShare> crossed;

  static const cleStory = 'story';
  static const cleLibrary = 'library';

  /// **Le même plan, réduit aux destinations dont la clé est dans [cles].**
  ///
  /// C'est « Réessayer » : une destination a échoué, on ne renvoie qu'elle —
  /// jamais celles qui sont déjà parties. Une ligne de conversation qui avait
  /// les deux cibles ne garde que celle demandée.
  SharePlan restreintA(Set<String> cles) => SharePlan(
    story: cles.contains(cleStory) ? story : null,
    library: cles.contains(cleLibrary) ? library : null,
    conversations: [
      for (final c in conversations)
        if (cles.contains(c.cleChat) || cles.contains(c.cleLibrary))
          c.copyWith(
            dansLeChat: cles.contains(c.cleChat),
            aussiDansLaBibliotheque: cles.contains(c.cleLibrary),
          ),
    ],
    crossed: [
      for (final c in crossed)
        if (cles.contains(c.cle)) c,
    ],
    regles: regles,
  );

  bool get isEmpty =>
      story == null &&
      library == null &&
      conversations.isEmpty &&
      crossed.isEmpty;

  /// Combien de personnes recevront quelque chose **dans un chat**. Une
  /// conversation cochée 📚 seulement n'envoie rien à personne : ses membres
  /// découvriront la Vibe au reveal, ils ne sont pas des destinataires.
  int get destinataires =>
      conversations
          .where((c) => c.dansLeChat)
          .fold<int>(0, (n, c) => n + c.memberIds.length) +
      crossed.length;

  /// Le nombre de lignes cochées — ce que dit le bouton « Envoyer · N ».
  int get destinations =>
      (story != null ? 1 : 0) +
      (library != null ? 1 : 0) +
      conversations.length +
      crossed.length;

  /// Les limites de visionnage, **communes à tout l'envoi**.
  ///
  /// ⚠️ **Elles ne peuvent PAS être par personne**, et il faut savoir pourquoi :
  /// elles sont portées par la Card elle-même. Les rendre différentes d'un
  /// destinataire à l'autre demanderait une Card par destinataire, donc une
  /// montée de fichier par destinataire. Le réglage vit donc une fois, en haut
  /// de l'écran, comme dans l'ancien paramétrage du cercle.
  final ViewingRules regles;

  /// **Combien de fois les octets vont monter.**
  ///
  /// ## ⚠️ Ce nombre est la seule chose que ce chantier rend plus chère
  ///
  /// Chaque contexte a son propre dépôt, ses propres octets et sa propre clé
  /// (`cards`, `stories`, bibliothèque) — c'est le prix de la séparation, et
  /// Jay l'a assumé explicitement le 2026-08-30 : *« on garde l'option 1 comme
  /// aujourd'hui »*.
  ///
  /// ⚠️ **Le nombre de DESTINATAIRES ne le fait pas monter, mais le nombre de
  /// RÉGLAGES DIFFÉRENTS, si.** Une Card porte UN `saveable` : deux personnes
  /// qui n'ont pas le même demandent deux Cards, donc deux montées. C'est le
  /// prix honnête de la case « Sauvegardable » posée par ligne dans la maquette
  /// de Jay — et le dire au lieu de le cacher est ce qui permet de choisir.
  ///
  /// ⚠️ **Une bibliothèque de conversation coûte une montée PAR conversation**
  /// (`LibraryVibesRepository.addVibe` dépose ses propres octets), pas une pour
  /// toutes.
  int get televersements =>
      (story != null ? 1 : 0) +
      (library != null ? 1 : 0) +
      conversations.where((c) => c.aussiDansLaBibliotheque).length +
      lotsDeCercle.length;

  /// Les groupes de personnes qui partagent **exactement** les mêmes réglages.
  /// Un groupe = une Card = une montée de fichier.
  ///
  /// ⚠️ **Un croisé est toujours dans le lot NON sauvegardable** : il n'est pas
  /// encore un ami, on ne lui laisse pas garder la Vibe. Il rejoint donc
  /// gratuitement le lot des amis non sauvegardables quand il y en a.
  List<CercleLot> get lotsDeCercle {
    final parReglage = <bool, CercleLot>{};
    // Une conversation cochée 📚 seulement ne demande aucune Card : la
    // bibliothèque dépose ses propres octets (voir [televersements]).
    for (final c in conversations.where((c) => c.dansLeChat)) {
      final lot = parReglage.putIfAbsent(
        c.saveable,
        () => CercleLot(saveable: c.saveable),
      );
      lot.conversations.add(c);
    }
    if (crossed.isNotEmpty) {
      parReglage
          .putIfAbsent(false, () => CercleLot(saveable: false))
          .crossed
          .addAll(crossed);
    }
    return parReglage.values.toList();
  }

  /// Ce qui empêche d'envoyer, en clair. Vide = on peut partir.
  ///
  /// ⚠️ **Les règles sont vérifiées ICI, pas à l'envoi.** Ouvrir la porte puis
  /// échouer laisse l'utilisateur devant un refus qu'il ne pouvait pas prévoir
  /// — et lui fait perdre sa prise.
  List<String> problemes(CardType type, {required bool importe}) {
    final out = <String>[];

    if (isEmpty || conversations.any((c) => c.vide)) {
      out.add('Choisis au moins une destination.');
    }

    // ⚠️ **La règle du 1/1 est une règle de PRODUIT, pas une limite technique.**
    // Une Vibe 1/1 n'existe que si elle n'a qu'un seul destinataire et aucune
    // publication : c'est ce qui en fait un cadeau.
    if (type == CardType.oneOfOne) {
      if (story != null || library != null) {
        out.add('Une Vibe 1/1 ne se publie pas : elle est pour une personne.');
      }
      if (destinataires > 1) {
        out.add('Une Vibe 1/1 ne peut avoir qu\'un seul destinataire.');
      }
    }

    // Règles arrêtées par Jay le 2026-08-10 pour la bibliothèque de
    // conversation : de vraies photos ou vidéos, et pas de BeReal.
    final bibliothequeDeGroupe = conversations.any(
      (c) => c.aussiDansLaBibliotheque,
    );
    if (bibliothequeDeGroupe && importe) {
      out.add(
        'Le Drop n\'accepte pas les imports de la '
        'galerie.',
      );
    }
    if (bibliothequeDeGroupe && type == CardType.bereal) {
      out.add('Un BeReal ne va pas dans un Drop.');
    }

    // ⚠️ **Un croisé ne reçoit pas une Vibe sauvegardable ni rejouable** : il
    // n'est pas encore un ami. Le réglage n'existe donc pas sur sa ligne, et on
    // le vérifie ici plutôt que de faire confiance à l'écran.
    if (crossed.isNotEmpty && type == CardType.oneOfOne) {
      out.add(
        'Une Vibe 1/1 ne s\'envoie qu\'à un ami : garde-la pour plus tard.',
      );
    }

    return out;
  }

  SharePlan copyWith({
    StoryShare? story,
    bool effacerStory = false,
    LibraryShare? library,
    bool effacerLibrary = false,
    List<ConversationShare>? conversations,
    List<CrossedShare>? crossed,
    ViewingRules? regles,
  }) => SharePlan(
    story: effacerStory ? null : (story ?? this.story),
    library: effacerLibrary ? null : (library ?? this.library),
    conversations: conversations ?? this.conversations,
    crossed: crossed ?? this.crossed,
    regles: regles ?? this.regles,
  );
}
