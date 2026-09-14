import 'vibe_draft.dart';

/// **Ce qu'on partage, et ce qui est permis** — l'objet qui rend l'écran
/// « À qui ? » unique.
///
/// Avant le 2026-09-14, cinq écrans choisissaient « à qui » avec cinq listes
/// et cinq logiques. Ils différaient par **ce qu'ils avaient le droit de
/// proposer**, pas par la liste elle-même : un envoi depuis un chat impose ce
/// chat, un repartage de story ne connaît ni story ni bibliothèque. Ce qui
/// change d'un cas à l'autre tient dans cet objet ; ce qui ne change pas —
/// la liste, l'ordre, la recherche — vit une seule fois dans l'écran.
sealed class ShareContext {
  const ShareContext();

  /// Peut-on publier (story, bibliothèque) ?
  bool get allowsPublish;

  /// Peut-on envoyer à un croisé (une demande d'ami qui porte la Vibe) ?
  bool get allowsCrossed;

  /// Les lignes de groupe et de DM ont-elles la cible 📚 ?
  bool get allowsConversationLibrary;

  /// La conversation à pré-cocher (ouverture depuis un chat), s'il y en a une.
  String? get presetConversationId;

  /// Le titre de l'écran.
  String get title;

  /// Le libellé du bouton.
  String get sendLabel;

  /// **Publication seulement** (Jay, 2026-09-15) : la capture a été ouverte
  /// depuis « Publier » sur le profil. La destination est imposée — la
  /// bibliothèque, cochée d'office — et rien d'autre n'est proposé : ni story,
  /// ni ami, ni groupe, ni croisé. L'écran « À qui ? » ne pose plus la
  /// question, il ne sert qu'à régler et à confirmer.
  bool get libraryOnly => false;
}

/// **Une Vibe neuve**, sortie de la capture. Tout est permis.
class VibeShareContext extends ShareContext {
  const VibeShareContext({
    required this.draft,
    this.presetConversationId,
    this.libraryOnly = false,
  });

  final VibeDraft draft;

  @override
  final bool libraryOnly;

  /// Capture ouverte depuis un chat : ce chat est coché à l'arrivée, et
  /// modifiable — on peut ajouter d'autres destinataires.
  @override
  final String? presetConversationId;

  @override
  bool get allowsPublish => true;

  @override
  bool get allowsCrossed => !libraryOnly;

  @override
  bool get allowsConversationLibrary => !libraryOnly;

  @override
  String get title => libraryOnly ? 'Publier' : 'Partager';

  @override
  String get sendLabel => libraryOnly ? 'Publier' : 'Envoyer';
}

/// **Un repartage** d'une story ou d'une publication existante.
///
/// Un repartage est un **chemin vers la source, jamais une copie**
/// (`docs/stockage-et-acces.md`) : il ne va que dans des chats — pas de
/// story, pas de bibliothèque, pas de croisé. C'est ce même écran qui, le jour
/// du feed, portera « ajouter au feed de l'autre ».
class RepostShareContext extends ShareContext {
  const RepostShareContext({required this.contentId, required this.what});

  final String contentId;

  /// « Story » ou « Publication » : ce que le titre dit.
  final String what;

  @override
  bool get allowsPublish => false;

  @override
  bool get allowsCrossed => false;

  @override
  bool get allowsConversationLibrary => false;

  @override
  String? get presetConversationId => null;

  @override
  String get title => 'Partager la $what';

  @override
  String get sendLabel => 'Partager';
}
