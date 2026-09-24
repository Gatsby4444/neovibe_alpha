import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/device_identity.dart';

void main() {
  test('l\'empreinte est SHA-256(sel + ANDROID_ID), en hexadécimal', () async {
    // Valeur attendue calculée hors de Dart (Python, hashlib.sha256) : si le
    // sel ou le calcul changeait, tous les téléphones deviendraient « neufs »
    // aux yeux du serveur — et le plafond ne vaudrait plus rien.
    expect(
      await DeviceIdentity.hash('9774d56d682e549c'),
      '53f07947a2b940216a06915519d06b4785a4b508adf8b0e03458543648493386',
    );
  });

  test('l\'empreinte a la forme que le serveur exige', () async {
    final h = await DeviceIdentity.hash('abc');
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h), isTrue);
  });
}
