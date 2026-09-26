import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Notifications locales, par catégorie (désactivables individuellement
/// dans les réglages système Android — spec 4.9).
enum NotifChannel {
  fomo('fomo', 'Activité du cercle', 'Publications et Vibes reçues'),
  waves('waves', 'Waves', 'Croisements physiques manqués'),
  proximity('proximity', 'Proximité', 'Demandes de connexion à proximité'),
  bereal('bereal', 'BeReal', 'C\'est le moment de capturer l\'instant'),
  position('position', 'Position', 'Demandes de position de tes amis');

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

  /// [id] : **à fournir dès qu'on voudra pouvoir l'annuler**.
  ///
  /// ⚠️ Sans lui, l'identifiant est tiré de l'heure : la notification est donc
  /// **introuvable** une seconde plus tard. C'est ce qui rendait impossible de
  /// retirer « ton ami est tout près » quand l'ami repartait — le seul moment où
  /// cette notification doit disparaître.
  Future<void> show(
    NotifChannel channel,
    String title,
    String body, {
    String? payload,
    int? id,
  }) async {
    await init();
    await _plugin.show(
      id ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      _details(channel),
      payload: payload,
    );
  }

  /// Retire une notification déjà affichée ou programmée.
  Future<void> cancel(int id) async {
    await init();
    await _plugin.cancel(id);
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
