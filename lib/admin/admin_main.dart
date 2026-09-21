import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/env.dart';
import 'admin_app.dart';

/// **La console d'administration** — un second point d'entrée du même
/// dépôt, construit pour le web :
///
///     flutter build web --target lib/admin/admin_main.dart
///
/// Jay, 2026-09-21 : *« on construira toute une plateforme d'administration
/// complète avant la première release de production »* (RAPPELS #156).
/// Ceci en est la **première console** : elle ne connaît que les RPC
/// `admin_*` du serveur (`supabase/migrations/20260921220000_administration.sql`),
/// qui refusent quiconque n'est pas dans `admins`. Ce qui manque pour
/// « complète » est dit dans `docs/administration.md`.
///
/// Aucune clé secrète ici : la console se connecte comme un utilisateur
/// (clé publique + mot de passe), et c'est le serveur qui sait qu'il est
/// administrateur.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabasePublishableKey,
  );
  runApp(const ProviderScope(child: AdminApp()));
}
