import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Notifications locales, par catégorie (désactivables individuellement
/// dans les réglages système Android — spec 4.9).
enum NotifChannel {
  fomo('fomo', 'Activité du cercle', 'Publications et Cards reçues'),
  waves('waves', 'Waves', 'Croisements physiques manqués'),
  proximity('proximity', 'Proximité', 'Demandes de connexion à proximité'),
  bereal('bereal', 'BeReal', 'C\'est le moment de capturer l\'instant');

  const NotifChannel(this.id, this.title, this.description);
  final String id;
  final String title;
  final String description;
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  var _initialized = false;

  /// Branché par l'app au démarrage : reçoit le payload d'une notification
  /// touchée (ex. 'bereal' → ouvrir la capture contrainte).
  void Function(String payload)? onNotificationTap;

  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          onNotificationTap?.call(payload);
        }
      },
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.requestNotificationsPermission();
    for (final channel in NotifChannel.values) {
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          channel.id,
          channel.title,
          description: channel.description,
          importance: Importance.defaultImportance,
        ),
      );
    }
    _initialized = true;
  }

  NotificationDetails _details(NotifChannel channel) => NotificationDetails(
    android: AndroidNotificationDetails(
      channel.id,
      channel.title,
      channelDescription: channel.description,
    ),
  );

  Future<void> show(
    NotifChannel channel,
    String title,
    String body, {
    String? payload,
  }) async {
    await init();
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      _details(channel),
      payload: payload,
    );
  }

  /// Notification différée (Waves par défaut : jamais en temps réel
  /// sauf opt-in explicite — spec 4.11).
  Future<void> schedule(
    NotifChannel channel,
    String title,
    String body,
    DateTime when, {
    String? payload,
    bool exact = false,
  }) async {
    await init();
    if (when.isBefore(DateTime.now())) {
      return show(channel, title, body, payload: payload);
    }
    await _plugin.zonedSchedule(
      when.millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      tz.TZDateTime.from(when, tz.local),
      _details(channel),
      // exact : requis pour la notif BeReal programmée « à la seconde près »
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }
}

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService.instance,
);
