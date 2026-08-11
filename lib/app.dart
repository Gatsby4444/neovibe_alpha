import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/content/saved_store.dart';
import 'core/diagnostics/app_log_observers.dart';
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
      // Trace le parcours d'écran en écran : sans lui, une erreur du journal
      // n'a pas de contexte (on voit le symptôme, pas d'où venait l'utilisateur).
      navigatorObservers: [AppLogNavigatorObserver()],
      theme: NeoTheme.light(),
      darkTheme: NeoTheme.dark(),
      themeMode: light ? ThemeMode.light : ThemeMode.dark,
      home: const RootGate(),
    );
  }
}

/// Aiguillage racine : non connecté → auth ; connecté sans profil →
/// onboarding ; sinon → app.
class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key});

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate> {
  @override
  void initState() {
    super.initState();
    // Balayage des révocations, une fois par lancement.
    //
    // C'est le SEUL point de contact entre les Enregistrements et le serveur :
    // ils sont locaux et en clair, donc lisibles hors ligne. On demande
    // simplement « lesquels de ceux-ci ont été révoqués ? » et on supprime
    // ceux-là.
    //
    // ⚠️ Révocation COOPÉRATIVE, faille connue et acceptée par Jay le
    // 2026-08-11 : un client modifié peut ignorer cette étape. On ne promet
    // donc jamais « révocation garantie » sur une sauvegarde — seulement sur
    // un contenu que le serveur sert encore.
    //
    // Différé après la première image : rien ici ne doit retarder l'affichage.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final removed = await ref.read(savedStoreProvider).purgeRevoked();
      if (removed > 0) ref.invalidate(savedItemsProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
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
