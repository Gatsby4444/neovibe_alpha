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
  });

  final String conversationId;

  /// Nom du groupe, ou nom de la personne d'en face en DM. Affiché sur le
  /// bouton d'ajout pour un groupe ; en petit et discrètement sous le bouton
  /// pour un DM (consigne Jay).
  final String label;

  final bool isGroup;
}
