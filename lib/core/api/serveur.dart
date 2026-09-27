/// **Le serveur de l'app** — choisi à la CONSTRUCTION de l'APK, jamais à
/// l'exécution (docs/serveur-rust.md, étape 11).
///
/// L'app de tous les jours parle à Supabase. L'app d'essai du serveur Rust
/// se construit avec :
///
/// ```
/// flutter build apk --dart-define=SERVEUR=rust \
///   --dart-define=SERVEUR_URL=http://192.168.1.20:8787
/// ```
///
/// Rien d'autre ne change : les écrans et les dépôts parlent à la couche
/// d'accès (`nv_api.dart`), qui seule sait à quel serveur elle parle.
abstract final class Serveur {
  /// `supabase` (l'app de tous les jours) ou `rust`.
  static const nom = String.fromEnvironment(
    'SERVEUR',
    defaultValue: 'supabase',
  );

  /// L'adresse du serveur Rust (sans `/` final).
  static const url = String.fromEnvironment(
    'SERVEUR_URL',
    defaultValue: 'http://127.0.0.1:8787',
  );

  /// Vrai pour l'app d'essai du serveur Rust.
  static const rust = nom == 'rust';
}
