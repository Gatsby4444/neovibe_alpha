import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/content/saved_store.dart';
import 'core/day_cycle_background.dart';
import 'core/day_cycle_clock.dart';
import 'core/diagnostics/app_log_observers.dart';
import 'core/prefs.dart';
import 'core/supabase_providers.dart';
import 'core/theme.dart';
import 'features/auth/auth_screen.dart';
import 'features/auth/onboarding_screen.dart';
import 'features/home/home_shell.dart';
import 'features/proximity/net/friend_book_watcher.dart';
import 'features/proximity/net/ping_beacon_service.dart';
import 'features/proximity/net/proximity_controller.dart';
import 'features/proximity/net/proximity_supervisor.dart';

/// Clé de navigation globale : permet aux notifications (ex. BeReal)
/// d'ouvrir un écran hors de tout contexte de widget.
final navigatorKey = GlobalKey<NavigatorState>();

/// Observateur de routes — permet à un écran de savoir qu'on **revient** sur
/// lui, ce que son propre `build` ne dit pas.
///
/// Utilisé par `HomeShell` pour rejouer l'entrée de la barre de navigation à
/// chaque retour d'un écran poussé. Sans lui, il faudrait lire l'animation de
/// la route — et la séquence serait alors enfermée dans sa durée.
final routeObserver = RouteObserver<PageRoute<dynamic>>();

class NeoVibeApp extends ConsumerWidget {
  const NeoVibeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // L'identité visuelle choisie par Jay (2026-08-29). Cinq identités
    // mutuellement exclusives ; deux d'entre elles — Aurore et Sable — suivent
    // le jour et la nuit du téléphone, les trois autres sont des choix fermes.
    final identity = ref.watch(themeIdentityProvider);

    return MaterialApp(
      title: 'NeoVibe',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      // Trace le parcours d'écran en écran : sans lui, une erreur du journal
      // n'a pas de contexte (on voit le symptôme, pas d'où venait l'utilisateur).
      navigatorObservers: [AppLogNavigatorObserver(), routeObserver],
      theme: NeoTheme.of(identity, Brightness.light),
      darkTheme: NeoTheme.of(identity, Brightness.dark),
      // ⚠️ **C'est l'identité qui décide si le système a son mot à dire.**
      // Une identité qui ne suit pas le système reçoit deux fois la même
      // palette (voir `NeoIdentity.palette`) : le forçage ci-dessous n'est donc
      // qu'une ceinture — il évite qu'un futur `Brightness` ajouté à une
      // palette fixe se mette à réagir au réglage du téléphone sans qu'on l'ait
      // demandé.
      themeMode: identity.suitLeSysteme
          ? ThemeMode.system
          : (identity.palette(Brightness.light).isDark
                ? ThemeMode.dark
                : ThemeMode.light),
      // Le dégradé du cycle, posé UNE fois sous toute l'app.
      //
      // C'est ici que l'identité « Cycle du jour » se branche, et nulle part
      // ailleurs : ses Scaffold sont transparents (voir `NeoTheme`), donc ce fond est
      // celui de tous les écrans à la fois. Aucun des 60 Scaffold n'a été
      // touché — et aucun futur écran n'aura à s'en soucier.
      //
      // ⚠️ `builder` et non un `Stack` autour de `home` : les routes poussées
      // par-dessus (visionneuses, capture, réglages) sont des surfaces sœurs de
      // `home`, pas ses enfants. Un Stack autour de `home` seul laisserait donc
      // toutes les navigations sur un fond noir — et le défaut ne se verrait
      // qu'à la deuxième page.
      builder: identity.fondDuCycle ? _gradientBuilder : null,
      home: const RootGate(),
    );
  }

  static Widget _gradientBuilder(BuildContext context, Widget? child) =>
      _DayCycleScope(child: child ?? const SizedBox.shrink());
}

/// Le fond dégradé vivant, sous l'app entière.
class _DayCycleScope extends ConsumerWidget {
  const _DayCycleScope({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Repli sur midi tant que la première heure n'est pas arrivée : c'est
    // l'affaire d'une image, et un fond noir le temps du premier build se
    // verrait comme un clignotement au lancement.
    final hour = ref.watch(currentHourProvider).value ?? 12.0;
    return DayCycleBackground(hour: hour, child: child);
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

    // ------------------------------------------------------------------
    // ⚠️ **CE QUI DOIT VIVRE AUSSI LONGTEMPS QUE LA SESSION**
    // ------------------------------------------------------------------
    //
    // Un provider Riverpod ne calcule **rien** tant que personne ne l'observe.
    // Les quatre ci-dessous n'ont pas d'écran à eux : ils tiennent la
    // proximité, qui doit fonctionner quel que soit l'onglet affiché.
    //
    // ## 🔴 Le défaut relevé le 2026-08-28
    //
    // Le superviseur, le contrôleur et le service de balise n'étaient tenus
    // vivants **que par l'écran Ping**. Conséquences, aucune ne levant la
    // moindre erreur :
    //
    // - un utilisateur qui **n'ouvre jamais l'onglet Ping** de la session
    //   n'avait **ni radio, ni croisement d'amis, ni balise** — ses deux
    //   réglages étaient simplement ignorés ;
    // - l'onglet d'ouverture est **configurable** (`StartupTab`), donc ça
    //   dépendait d'une préférence sans rapport ;
    // - le nouveau réglage « Croiser mes amis » ne survivait pas à la fermeture
    //   de l'écran Réglages ;
    // - et quand l'écran était détruit, la surveillance du carnet d'amis et la
    //   rotation horaire du plan s'arrêtaient **sans arrêter la radio** : le
    //   natif continuait de crier un plan que plus rien ne mettait à jour.
    //
    // ⚠️ **C'était l'écran qui tenait la cuisine ouverte** — l'inverse exact de
    // la règle de `CLAUDE.md`. Un réglage doit valoir parce qu'il est posé, pas
    // parce qu'on regarde l'écran qui le montre.
    ref.watch(friendBookWatcherProvider);
    ref.watch(proximitySupervisorProvider);
    ref.watch(proximityControllerProvider);
    ref.watch(pingBeaconProvider);

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
