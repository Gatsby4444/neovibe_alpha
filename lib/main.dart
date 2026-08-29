import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/motion.dart';
import 'core/config/env.dart';
import 'core/diagnostics/app_log.dart';
import 'core/diagnostics/app_log_observers.dart';
import 'core/notifications/notification_service.dart';
import 'core/prefs.dart';
import 'core/supabase_providers.dart';
import 'features/cards/card_capture_screen.dart';
import 'features/cards/card_media_cache.dart';
import 'package:rive/rive.dart' as rive;

import 'core/content/content_media_cache.dart';
import 'core/widgets/avatar.dart';
import 'features/library_vibes/library_vault_cache.dart';
import 'features/cards/native_camera.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Moteur Rive : chargement de la bibliothèque native. Obligatoire avant tout
  // `File.asset` / `RiveWidget`, et une seule fois pour toute l'app.
  //
  // ⚠️ Enveloppé : sur un appareil où le natif ne se charge pas, l'app doit
  // démarrer quand même. Un bouton qui retombe sur son rendu Flutter est un
  // désagrément ; un écran noir au lancement est une panne.
  try {
    await rive.RiveNative.init();
  } catch (e) {
    AppLog.instance.error('Rive', 'moteur natif indisponible : $e');
  }

  // Toute erreur Dart part dans le MÊME journal que la couche caméra native
  // (Réglages → Développeur → Journal caméra) : Jay peut copier une trace
  // unique, y compris après un crash.
  final flutterOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    NativeCameraController.log('ERREUR FLUTTER : ${details.exception}');
    AppLog.instance.error('Erreur Flutter', '${details.exception}');
    flutterOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    NativeCameraController.log('ERREUR DART : $error');
    AppLog.instance.error('Erreur Dart', '$error');
    return false;
  };

  // Journal d'application (Réglages → Développeur → Journal de l'app). Ouvert
  // le plus tôt possible pour que même un échec d'initialisation y figure.
  AppLog.instance.sessionStart();

  // Portrait uniquement : un seul sens de prise, un seul format de card (9:16)
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // **Bord à bord, une fois pour toutes** (2026-08-15).
  //
  // ### Pourquoi ici, et plus dans l'écran de capture
  //
  // Seul l'écran de capture en avait besoin (le flash frontal doit couvrir la
  // surface physique entière), et il basculait donc le mode à l'ouverture puis
  // le restaurait à la fermeture. Or **changer ce mode change la taille utile
  // de la fenêtre** : l'arbre entier se remet en page, `HomeShell` compris,
  // qui est encore monté derrière pendant la transition.
  //
  // C'est l'à-coup que Jay a signalé trois fois — et la seule chose qui
  // restait après avoir sorti le travail lourd de l'animation (v0.9.90).
  //
  // Ne plus jamais basculer supprime la cause. Un garde-fou (« basculer plus
  // tard ») aurait laissé la remise en page, juste ailleurs.
  //
  // ⚠️ **L'inventaire qui autorise ce choix**, fait avant de le prendre :
  // tous les écrans de l'app ont soit une `AppBar` (qui applique elle-même la
  // marge du haut), soit une `SafeArea`. Les deux seuls fichiers sans ni l'un
  // ni l'autre sont `app.dart` (un indicateur centré) et `home_shell.dart` —
  // dont la `NavigationBar` embarque sa propre `SafeArea` (vérifié dans le
  // SDK, `material/navigation_bar.dart:291`).
  //
  // Le commentaire qui affirmait « le reste de l'app n'est pas écrit pour le
  // bord à bord » était donc faux : il n'avait jamais été vérifié.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabasePublishableKey,
  );
  _suivreLeJetonDuTempsReel();
  await NotificationService.instance.init();

  // Tap sur la notification BeReal → capture contrainte (fenêtre 5 min)
  NotificationService.instance.onNotificationTap = (payload) {
    if (payload == 'bereal') {
      navigatorKey.currentState?.push(
        NeoFadeRoute(builder: (_) => const CardCaptureScreen(bereal: true)),
      );
    }
  };

  // Service de premier plan : maintient la détection BLE (Ping/Waves)
  // quand l'app n'est plus au premier plan, tant que la visibilité est active.
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'neovibe_presence',
      channelName: 'Présence NeoVibe',
      channelDescription: 'Détection de proximité active',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(60000),
      autoRunOnBoot: false,
      allowWakeLock: true,
    ),
  );

  // Balayage du cache des cards au démarrage (TTL + plafonds), sans bloquer
  // le lancement — et anti-capture FLAG_SECURE : DÉSACTIVÉ par défaut le
  // temps du développement (Jay doit pouvoir prendre des captures d'écran),
  // activable dans Réglages → Développeur. À réactiver avant la prod
  // (RAPPELS.md).
  // ⚠️ **Attendu, et c'est délibéré.** L'onglet de démarrage doit être connu
  // AVANT le premier rendu : lu après coup, l'app s'ouvrait sur le Cercle puis
  // sautait ailleurs, en laissant la barre et l'écran désaccordés (défaut du
  // 2026-08-29, voir `SectionCursor`). Le coût est une lecture de préférences,
  // que l'écran de démarrage natif couvre ; les balayages ci-dessous, eux, ne
  // bloquent toujours rien.
  final prefs = await SharedPreferences.getInstance();
  final startupTab = StartupTab.fromKey(
    prefs.getString(StartupTabPref.prefsKey),
  );

  {
    CardMediaCache().sweep(prefs.getInt(OwnCardsQuotaMb.prefsKey) ?? 2048);
    // Le socle de contenu (stories et publications) a son propre balayage :
    // sa règle est l'expiration du contenu, pas un budget de vues.
    // Deux cycles de vie, deux espaces.
    ContentMediaCache().sweep();
    // Et le coffre des bibliothèques de conversation, troisième cycle de vie :
    // ses scellés sont amenés d'avance pour que le reveal soit instantané, et
    // ils restent sur l'appareil ensuite. Sans balayage, ils s'y accumuleraient.
    LibraryVaultCache().sweep();
    // Les avatars : petits, nombreux, et gardés parce que leur chemin est
    // versionné (voir `AvatarFileCache`). Le balayage borne simplement leur
    // nombre.
    AvatarFileCache().sweep();
    NativeCameraController.setSecure(
      prefs.getBool(DevSecureEnabled.prefsKey) ?? false,
    );
  }

  runApp(
    ProviderScope(
      // Capte tout échec de provider — donc l'essentiel des erreurs serveur,
      // sans instrumenter le moindre appel.
      observers: const [AppLogProviderObserver()],
      // L'onglet d'ouverture, figé pour la session. Voir
      // `startupTabAtLaunchProvider` : sans cet override, il lève.
      overrides: [startupTabAtLaunchProvider.overrideWithValue(startupTab)],
      child: const NeoVibeApp(),
    ),
  );
}

/// Donne au socle temps réel le jeton FRAIS à chaque renouvellement.
///
/// ⚠️ **Défaut trouvé dans le journal de Jay le 2026-08-17**, et que personne
/// n'avait identifié comme un bug :
///
/// ```
/// RealtimeSubscribeException — "InvalidJWTToken: Token has expired 4847 seconds ago"
/// ```
///
/// Le jeton d'accès est renouvelé automatiquement pour les appels REST, mais le
/// **socket temps réel garde celui avec lequel il s'est ouvert**. Au bout d'une
/// heure d'app allumée, il porte donc un jeton mort — ici depuis **80 minutes**.
///
/// **Ce que ça casse, sans le moindre symptôme visible** : les abonnements
/// temps réel (`connection_requests`, `connections`) tombent en erreur et n'en
/// sortent plus. Une demande de connexion reçue **n'arrive jamais à l'écran**,
/// et l'utilisateur voit simplement… rien. C'est exactement la famille de
/// défauts qu'on passe la journée à chasser : ça marche, puis ça s'arrête, et
/// aucun écran ne le dit.
///
/// ⚠️ **Un `StreamProvider` en erreur y reste.** Même une fois le jeton rafraîchi,
/// rien ne le relance : le renouvellement ne change ni l'identifiant de
/// l'utilisateur ni le client, donc Riverpod n'a aucune raison de reconstruire.
/// D'où le `refresh` explicite ci-dessous — c'est lui qui remet les flux en
/// marche.
void _suivreLeJetonDuTempsReel() {
  final client = Supabase.instance.client;
  client.auth.onAuthStateChange.listen((state) {
    final token = state.session?.accessToken;
    if (token == null) return;
    if (state.event == AuthChangeEvent.tokenRefreshed ||
        state.event == AuthChangeEvent.signedIn ||
        state.event == AuthChangeEvent.initialSession) {
      client.realtime.setAuth(token);
      // Et on relance les abonnements : ceux qui étaient tombés ne se
      // relèveraient pas tout seuls.
      realtimeEpoch.value++;
      AppLog.instance.app('jeton temps réel rafraîchi', state.event.name);
    }
  });
}
