import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import 'rust_backend.dart';
import 'serveur.dart';

/// **Ouvre le serveur de cette construction de l'app**, avant le premier
/// écran : Supabase (l'app de tous les jours) ou le serveur Rust (l'app
/// d'essai, `--dart-define=SERVEUR=rust`) — qui relit alors la session
/// gardée sur le téléphone.
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
