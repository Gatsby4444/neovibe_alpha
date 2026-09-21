/// Conversation visée quand la capture est ouverte pour une **bibliothèque
/// éphémère** (bouton « plus » de la barre de saisie).
///
/// Sa seule présence bascule l'écran de capture dans le mode bibliothèque :
/// aucun aperçu après la prise, pas de couleur de fond, pas d'import galerie,
/// et un écran de partage réduit. Voir `docs/bibliotheques-ephemeres.md`.
class LibraryTarget {
  const LibraryTarget({
    required this.conversationId,
    required this.label,
    required this.isGroup,
    this.isEvent = false,
    this.challengeId,
    this.challengeText,
  });

  final String conversationId;

  /// Le Drop d'un ÉVÉNEMENT : visible **tout de suite** par les participants
  /// (2026-09-21), là où celui d'une conversation se révèle à 18h30.
  final bool isEvent;

  /// **Le défi auquel cette Vibe répond** (mode événement, 2026-09-21) : la
  /// Vibe est déposée dans le Drop de l'événement, marquée du défi. Nul =
  /// un dépôt ordinaire.
  final String? challengeId;
  final String? challengeText;

  /// Nom du groupe, ou nom de la personne d'en face en DM. Affiché sur le
  /// bouton d'ajout pour un groupe ; en petit et discrètement sous le bouton
  /// pour un DM (consigne Jay).
  final String label;

  final bool isGroup;
}
