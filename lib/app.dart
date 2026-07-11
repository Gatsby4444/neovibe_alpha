import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/supabase_providers.dart';
import 'core/theme.dart';
import 'features/auth/auth_screen.dart';
import 'features/auth/onboarding_screen.dart';
import 'features/home/home_shell.dart';

class NeoVibeApp extends StatelessWidget {
  const NeoVibeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NeoVibe',
      debugShowCheckedModeBanner: false,
      theme: NeoTheme.dark(),
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
