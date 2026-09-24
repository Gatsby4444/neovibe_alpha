import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **L'empreinte de CE téléphone, pour borner la création de comptes**
/// (Jay, 2026-09-24).
///
/// Le natif lit `ANDROID_ID` (`NativeDeviceIdentity.kt`) ; ici on n'en garde
/// qu'une **empreinte** : SHA-256 d'un sel propre à NeoVibe suivi de la
/// valeur. La valeur brute ne quitte jamais le téléphone ; le serveur reçoit
/// 64 caractères qui permettent de reconnaître l'appareil, pas de le décrire.
///
/// ⚠️ **Ce fichier ne décide de rien.** Le plafond (combien de comptes, sur
/// quelle durée) est une ligne en base, appliquée par le serveur au moment
/// de l'inscription (`hook_before_user_created`). Voir
/// `docs/inscription-et-appareil.md`.
class DeviceIdentity {
  const DeviceIdentity();

  static const _channel = MethodChannel('neovibe/device');

  /// Changer ce sel rendrait tous les téléphones « neufs » aux yeux du
  /// serveur : il ne change jamais.
  static const _salt = 'neovibe-device-v1:';

  /// L'empreinte, ou `null` si le système ne donne pas d'identifiant (le
  /// serveur refusera alors l'inscription, et le dira).
  Future<String?> fingerprint() async {
    String? id;
    try {
      id = await _channel.invokeMethod<String>('androidId');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
    if (id == null || id.isEmpty) return null;
    return hash(id);
  }

  /// Le calcul seul, exposé pour les tests.
  static Future<String> hash(String androidId) async {
    final digest = await Sha256().hash(utf8.encode('$_salt$androidId'));
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

final deviceIdentityProvider = Provider((ref) => const DeviceIdentity());
