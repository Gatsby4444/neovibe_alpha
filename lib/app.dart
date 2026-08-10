import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/prefs.dart';
import 'core/supabase_providers.dart';
import 'core/theme.dart';
import 'features/auth/auth_screen.dart';
import 'features/auth/onboarding_screen.dart';
import 'features/home/home_shell.dart';

/// Clé de navigation globale : permet aux notifications (ex. BeReal)
/// d'ouvrir un écran hors de tout contexte de widget.
final navigatorKey = GlobalKey<NavigatorState>();

class NeoVibeApp extends ConsumerWidget {
  const NeoVibeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Thème piloté par le réglage de Jay (2026-08-10), pas par le système :
    // le sombre reste le défaut et l'utilisateur choisit explicitement.
    final light = ref.watch(lightThemeProvider);
    return MaterialApp(
      title: 'NeoVibe',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: NeoTheme.light(),
      darkTheme: NeoTheme.dark(),
      themeMode: light ? ThemeMode.light : ThemeMode.dark,
      home: const RootGate(),
    );
  }
}

/// Aiguillage racine : non connecté → auth ; connecté sans profil →
/// onboarding ; sinon → app.
class RootGate extends ConsumerWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(authStateProvider);
    final user = ref.watch(currentUserProvider);
    if (user == null) return const AuthScreen();

    final profile = ref.watch(myProfileProvider);
    return profile.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Erreur de chargement du profil\n$e',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => ref.invalidate(myProfileProvider),
                  child: const Text('Réessayer'),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (p) => p == null ? const OnboardingScreen() : const HomeShell(),
    );
  }
}
