import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import 'rust_backend.dart';
import 'serveur.dart';

/// **Ouvre le serveur de cette construction de l'app**, avant le premier
/// écran : le serveur Rust (le défaut depuis la bascule du 2026-09-29) —
/// qui relit alors la session gardée sur le téléphone — ou Supabase
/// (`--dart-define=SERVEUR=supabase`, l'ancien serveur, en pause).
Future<void> demarrerLeServeur() async {
  if (Serveur.rust) {
    await RustBackend.instance.demarrer();
    return;
  }
  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabasePublishableKey,
  );
}
