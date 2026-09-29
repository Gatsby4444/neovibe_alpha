/// **Le serveur de l'app** — choisi à la CONSTRUCTION de l'APK, jamais à
/// l'exécution (docs/serveur-rust.md, étapes 11 et 12).
///
/// ✏️ **Depuis la bascule du 2026-09-29 (v0.9.300), l'app de tous les jours
/// parle au serveur Rust du VPS**, `https://api.neovibe.fun` : c'est le
/// défaut, sans rien passer à la construction. Supabase est en pause.
///
/// L'app d'essai du serveur du PC se construit encore avec une autre
/// adresse (`server/outils/app_d_essai.sh`) :
///
/// ```
/// flutter build apk --dart-define=SERVEUR=rust \
///   --dart-define=SERVEUR_URL=http://192.168.1.20:8787
/// ```
///
/// Rien d'autre ne change : les écrans et les dépôts parlent à la couche
/// d'accès (`nv_api.dart`), qui seule sait à quel serveur elle parle.
abstract final class Serveur {
  /// `rust` (le défaut depuis la bascule) ou `supabase` (l'ancien serveur,
  /// en pause — gardé tant que le retrait de Supabase de l'app n'est pas
  /// fait).
  static const nom = String.fromEnvironment('SERVEUR', defaultValue: 'rust');

  /// L'adresse du serveur Rust (sans `/` final).
  static const url = String.fromEnvironment(
    'SERVEUR_URL',
    defaultValue: 'https://api.neovibe.fun',
  );

  /// Vrai quand l'app parle au serveur Rust.
  static const rust = nom == 'rust';
}
