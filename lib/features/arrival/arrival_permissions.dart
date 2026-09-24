import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../proximity/geo/coarse_location.dart';
import '../proximity/geo/live_position.dart';
import '../proximity/net/ble_radio.dart';
import '../proximity/net/proximity_supervisor.dart';
import '../proximity/net/radio_permissions.dart';
import '../proximity/net/radio_status.dart';

/// Ce qu'une autorisation vaut **pour l'arrivée en soirée**.
enum ArrivalGrant {
  /// Accordée, entièrement.
  yes,

  /// Accordée à moitié : la position « approximative » d'Android (~2 km,
  /// brouillée exprès). Ça marche, mais ça ne trouve pas un bar.
  partial,

  /// Pas accordée.
  no,
}

/// **Les trois autorisations de l'arrivée — la cuisine de l'écran de test.**
///
/// ⚠️ **Rien n'est demandé ici d'une façon nouvelle.** Chaque geste passe par
/// le chemin que l'app utilise déjà ailleurs, pour que l'arrivée et le reste
/// de l'app ne puissent pas diverger :
///
/// | Autorisation | Lue par | Demandée par |
/// |---|---|---|
/// | position | `CoarseLocation.blocker` + `precision` | `LivePosition.requestPrecise` (comme l'écran Ping) |
/// | Bluetooth | `BleRadio.probe` (le natif dit ce qui manque) | `requestRadioPermissions` (partagé avec l'écran Ping) |
/// | notifications | `permission_handler` | `permission_handler` |
/// | caméra | `permission_handler` | `permission_handler` (comme l'écran de capture) |
class ArrivalPermissions {
  ArrivalPermissions(this._ref);

  final Ref _ref;

  Future<ArrivalGrant> location() async {
    final coarse = _ref.read(coarseLocationProvider);
    if (await coarse.blocker() != null) return ArrivalGrant.no;
    return await coarse.precision() == LocationPrecision.precise
        ? ArrivalGrant.yes
        : ArrivalGrant.partial;
  }

  Future<ArrivalGrant> requestLocation() async {
    await _ref.read(livePositionProvider.notifier).requestPrecise();
    return location();
  }

  Future<ArrivalGrant> bluetooth() async {
    final status = await _ref.read(bleRadioProvider).probe();
    return status is RadioPermissionsMissing
        ? ArrivalGrant.no
        : ArrivalGrant.yes;
  }

  Future<ArrivalGrant> requestBluetooth() async {
    final status = await _ref.read(bleRadioProvider).probe();
    if (status is RadioPermissionsMissing) {
      await requestRadioPermissions(status.missing, withNotifications: false);
      // Même geste que l'écran Ping : c'est le natif qui dira si ça a marché,
      // et la radio repart sans attendre son prochain tour.
      await _ref.read(proximitySupervisorProvider.notifier).retry();
    }
    return bluetooth();
  }

  Future<ArrivalGrant> notifications() async =>
      (await Permission.notification.status).isGranted
      ? ArrivalGrant.yes
      : ArrivalGrant.no;

  Future<ArrivalGrant> requestNotifications() async =>
      (await Permission.notification.request()).isGranted
      ? ArrivalGrant.yes
      : ArrivalGrant.no;

  Future<bool> requestCamera() async =>
      (await Permission.camera.request()).isGranted;

  Future<void> openSettings() => openAppSettings();
}

final arrivalPermissionsProvider = Provider<ArrivalPermissions>(
  ArrivalPermissions.new,
);
