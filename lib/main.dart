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

  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabasePublishableKey,
  );
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
  SharedPreferences.getInstance().then((prefs) {
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
  });

  runApp(
    const ProviderScope(
      // Capte tout échec de provider — donc l'essentiel des erreurs serveur,
      // sans instrumenter le moindre appel.
      observers: [AppLogProviderObserver()],
      child: NeoVibeApp(),
    ),
  );
}
