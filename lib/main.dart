import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/notifications/notification_service.dart';
import 'core/prefs.dart';
import 'features/cards/card_capture_screen.dart';
import 'features/cards/card_media_cache.dart';
import 'features/cards/native_camera.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
        MaterialPageRoute(
          builder: (_) => const CardCaptureScreen(bereal: true),
        ),
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
    NativeCameraController.setSecure(
      prefs.getBool(DevSecureEnabled.prefsKey) ?? false,
    );
  });

  runApp(const ProviderScope(child: NeoVibeApp()));
}
