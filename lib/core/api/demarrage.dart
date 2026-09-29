import 'rust_backend.dart';

/// **Ouvre le serveur**, avant le premier écran : le serveur NeoVibe (Rust),
/// qui relit alors la session gardée sur le téléphone. (Jusqu'au
/// 2026-09-29, une construction pouvait encore viser l'ancien serveur,
/// Supabase — retiré de l'app depuis.)
Future<void> demarrerLeServeur() => RustBackend.instance.demarrer();
