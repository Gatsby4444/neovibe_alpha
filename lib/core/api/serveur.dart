/// **L'adresse du serveur NeoVibe** — fixée à la CONSTRUCTION de l'APK,
/// jamais à l'exécution (docs/serveur-rust.md).
///
/// Par défaut, le serveur du VPS : `https://api.neovibe.fun` (depuis la
/// bascule du 2026-09-29, v0.9.300). L'app d'essai du serveur du PC se
/// construit avec une autre adresse (`server/outils/app_d_essai.sh`) :
///
/// ```
/// flutter build apk --dart-define=SERVEUR_URL=http://192.168.1.20:8787
/// ```
///
/// Les écrans et les dépôts ne la voient jamais : ils parlent à la couche
/// d'accès (`nv_api.dart`).
abstract final class Serveur {
  /// L'adresse du serveur (sans `/` final).
  static const url = String.fromEnvironment(
    'SERVEUR_URL',
    defaultValue: 'https://api.neovibe.fun',
  );
}
