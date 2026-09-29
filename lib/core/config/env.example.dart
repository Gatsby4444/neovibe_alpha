// Copier ce fichier vers env.dart (gitignoré) et renseigner les valeurs.
// Gardées hors du dépôt par principe (consigne sécurité projet).
// (L'adresse et la clé de Supabase en sont sorties le 2026-09-29, avec
// l'ancien serveur ; l'adresse du serveur est dans core/api/serveur.dart.)

abstract final class Env {
  /// Jeton PUBLIC Mapbox (`pk.`), pour la carte. Compte de Jay ;
  /// valeur dans `docdev/mapbox.txt`.
  static const mapboxToken = 'pk....';
}
