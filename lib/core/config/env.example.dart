// Copier ce fichier vers env.dart (gitignoré) et renseigner les valeurs.
// La clé publishable est publique par conception (protégée par RLS),
// mais on la garde hors du repo par principe (consigne sécurité projet).

abstract final class Env {
  static const supabaseUrl = 'https://VOTRE-PROJET.supabase.co';
  static const supabasePublishableKey = 'sb_publishable_...';
}
