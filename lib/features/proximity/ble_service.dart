import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/models/nearby_user.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/supabase_providers.dart';

/// Identifiant fabricant de test + préfixe "NV" : signe les trames NeoVibe.
/// Le payload diffusé est : 'N' 'V' + 16 octets de ble_token.
/// Le token est un identifiant opaque distinct de l'id de compte — il ne
/// révèle rien sans passer par le serveur (resolve_ble_tokens, authentifié).
const _manufacturerId = 0xFFFF;
const _magic = [0x4E, 0x56]; // "NV"

/// Seuil RSSI grossier — jamais de distance précise (spec 4.2).
const _veryCloseRssi = -60;

/// Un pair est considéré hors de portée après ce délai sans trame.
const _staleAfter = Duration(seconds: 30);

/// Anti-spam Waves : un seul enregistrement par pair par fenêtre.
const _waveCooldown = Duration(hours: 2);

class BleState {
  const BleState({this.visible = false, this.nearby = const {}, this.error});

  /// Visibilité BLE : opt-in explicite, jamais activée au lancement (spec 4.2).
  final bool visible;

  /// token → utilisateur proche résolu.
  final Map<String, NearbyUser> nearby;
  final String? error;

  List<NearbyUser> get nearbyList {
    final list = nearby.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list;
  }

  BleState copyWith({
    bool? visible,
    Map<String, NearbyUser>? nearby,
    String? error,
  }) => BleState(
    visible: visible ?? this.visible,
    nearby: nearby ?? this.nearby,
    error: error,
  );
}

class BleService extends Notifier<BleState> {
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _housekeeping;
  final _peripheral = FlutterBlePeripheral();

  /// Tokens vus mais inconnus du serveur (évite de re-résoudre en boucle).
  final _unknownTokens = <String>{};

  /// token → dernier RSSI vu (mis à jour à chaque trame).
  final _lastRssi = <String, int>{};

  /// Derniers Waves enregistrés par pair (anti-spam local).
  final _lastWaveAt = <String, DateTime>{};

  @override
  BleState build() {
    ref.onDispose(_stopHardware);
    return const BleState();
  }

  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();
    return statuses[Permission.bluetoothScan]!.isGranted &&
        statuses[Permission.bluetoothAdvertise]!.isGranted;
  }

  /// Active la visibilité : advertising + scan + service de premier plan.
  Future<void> enable() async {
    if (state.visible) return;
    if (!await _requestPermissions()) {
      state = state.copyWith(error: 'Permissions Bluetooth refusées');
      return;
    }

    final profile = await ref.read(myProfileProvider.future);
    final token = profile?.bleToken;
    if (token == null) {
      state = state.copyWith(error: 'Profil incomplet');
      return;
    }

    try {
      await _startAdvertising(token);
      await _startScanning();
      await _startForegroundService();
      _housekeeping = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _prune(),
      );
      state = state.copyWith(visible: true, error: null);
    } catch (e) {
      await _stopHardware();
      state = state.copyWith(visible: false, error: 'Bluetooth : $e');
    }
  }

  /// Coupe tout — réversible à tout moment (spec : opt-in strict).
  Future<void> disable() async {
    await _stopHardware();
    state = const BleState();
  }

  Future<void> _startAdvertising(String token) async {
    final bytes = _uuidToBytes(token);
    await _peripheral.start(
      advertiseData: AdvertiseData(
        manufacturerId: _manufacturerId,
        manufacturerData: Uint8List.fromList([..._magic, ...bytes]),
        includeDeviceName: false,
      ),
      advertiseSettings: AdvertiseSettings(
        advertiseMode: AdvertiseMode.advertiseModeLowLatency,
        txPowerLevel: AdvertiseTxPower.advertiseTxPowerMedium,
        connectable: false,
        timeout: 0,
      ),
    );
  }

  Future<void> _startScanning() async {
    await FlutterBluePlus.startScan(
      continuousUpdates: true,
      androidScanMode: AndroidScanMode.lowLatency,
      removeIfGone: const Duration(seconds: 15),
    );
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'NeoVibe est attentif',
      notificationText: 'Détection de proximité active',
      callback: bleForegroundCallback,
    );
  }

  Future<void> _stopHardware() async {
    _housekeeping?.cancel();
    _housekeeping = null;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await _peripheral.stop();
    } catch (_) {}
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  Future<void> _onScanResults(List<ScanResult> results) async {
    final now = DateTime.now();
    final seenTokens = <String, int>{}; // token → rssi

    for (final r in results) {
      final data = r.advertisementData.manufacturerData[_manufacturerId];
      if (data == null || data.length != 18) continue;
      if (data[0] != _magic[0] || data[1] != _magic[1]) continue;
      final token = _bytesToUuid(data.sublist(2));
      seenTokens[token] = r.rssi;
    }
    if (seenTokens.isEmpty) return;

    final updated = Map<String, NearbyUser>.from(state.nearby);
    final toResolve = <String>[];

    for (final entry in seenTokens.entries) {
      _lastRssi[entry.key] = entry.value;
      final known = updated[entry.key];
      if (known != null) {
        updated[entry.key] = known.copyWith(
          lastSeen: now,
          proximity: entry.value >= _veryCloseRssi
              ? ProximityLevel.veryClose
              : ProximityLevel.close,
        );
      } else if (!_unknownTokens.contains(entry.key)) {
        toResolve.add(entry.key);
      }
    }

    if (toResolve.isNotEmpty) {
      await _resolveTokens(toResolve, updated, now);
    }
    state = state.copyWith(nearby: updated);
  }

  Future<void> _resolveTokens(
    List<String> tokens,
    Map<String, NearbyUser> updated,
    DateTime now,
  ) async {
    try {
      final rows =
          await ref
                  .read(supabaseProvider)
                  .rpc('resolve_ble_tokens', params: {'tokens': tokens})
              as List;
      final resolved = <String>{};
      for (final rawRow in rows) {
        final row = rawRow as Map<String, dynamic>;
        final token = row['ble_token'] as String;
        resolved.add(token);
        final rssi = _lastRssi[token] ?? -80;
        final user = NearbyUser(
          userId: row['user_id'] as String,
          displayName: row['display_name'] as String,
          avatarUrl: row['avatar_url'] as String?,
          isConnected: row['is_connected'] as bool? ?? false,
          proximity: rssi >= _veryCloseRssi
              ? ProximityLevel.veryClose
              : ProximityLevel.close,
          lastSeen: now,
        );
        updated[token] = user;
        if (user.isConnected) {
          await _recordWave(user);
        }
      }
      _unknownTokens.addAll(tokens.where((t) => !resolved.contains(t)));
    } catch (_) {
      // Réseau indisponible : on retentera à la prochaine trame.
    }
  }

  /// Wave "le presque" : croisement avec une connexion, enregistré avec
  /// anti-spam local, notification différée par défaut (spec 4.11).
  Future<void> _recordWave(NearbyUser peer) async {
    final last = _lastWaveAt[peer.userId];
    if (last != null && DateTime.now().difference(last) < _waveCooldown) {
      return;
    }
    _lastWaveAt[peer.userId] = DateTime.now();

    final client = ref.read(supabaseProvider);
    final me = client.auth.currentUser?.id;
    if (me == null) return;
    try {
      final profile = await ref.read(myProfileProvider.future);
      final realtime = profile?.realtimeWaves ?? false;
      final notifyAfter = realtime
          ? DateTime.now()
          : DateTime.now().add(const Duration(minutes: 45));
      await client.from('waves').insert({
        'user_id': me,
        'peer_id': peer.userId,
        'notify_after': notifyAfter.toUtc().toIso8601String(),
      });
      await NotificationService.instance.schedule(
        NotifChannel.waves,
        'Le presque…',
        '${peer.displayName} est passé tout près de toi.',
        notifyAfter,
      );
    } catch (_) {
      // Wave perdu : acceptable, le prochain croisement en recréera un.
    }
  }

  /// Retire les pairs plus vus depuis _staleAfter (sortie de portée).
  void _prune() {
    final now = DateTime.now();
    final kept = <String, NearbyUser>{};
    state.nearby.forEach((token, user) {
      if (now.difference(user.lastSeen) < _staleAfter) kept[token] = user;
    });
    if (kept.length != state.nearby.length) {
      state = state.copyWith(nearby: kept);
    }
  }

  /// L'utilisateur [userId] est-il actuellement en portée BLE ?
  bool isInRange(String userId) {
    final now = DateTime.now();
    return state.nearby.values.any(
      (u) => u.userId == userId && now.difference(u.lastSeen) < _staleAfter,
    );
  }
}

final bleServiceProvider = NotifierProvider<BleService, BleState>(
  BleService.new,
);

/// Callback du service de premier plan : il ne fait rien lui-même —
/// il maintient le process en vie pour que le scan continue en arrière-plan.
@pragma('vm:entry-point')
void bleForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_NoopTaskHandler());
}

class _NoopTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

Uint8List _uuidToBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

String _bytesToUuid(List<int> bytes) {
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
