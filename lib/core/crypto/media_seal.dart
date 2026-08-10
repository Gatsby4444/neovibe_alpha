import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Chiffrement des médias, partagé par les Vibes et les bibliothèques
/// éphémères.
///
/// Le principe est le même dans les deux cas : le média est chiffré **sur
/// l'appareil de l'auteur**, la clé est confiée au serveur, et c'est le serveur
/// qui décide quand il la rend. Les octets lourds ne voyagent qu'une fois et
/// peuvent rester en cache — chiffrés, donc inertes.
///
/// AES-256-GCM. Le nonce et le MAC voyagent avec le chiffré
/// (`concatenation`) : seule la **clé** est retenue côté serveur.
class MediaSeal {
  MediaSeal._();

  static final _algorithm = AesGcm.with256bits();

  /// Longueurs imposées par AES-GCM, nécessaires pour redécouper la
  /// concaténation à la lecture.
  static const _nonceLength = 12;
  static const _macLength = 16;

  /// Une clé neuve, en base64 — la forme sous laquelle elle est stockée et
  /// transportée.
  static Future<String> newKey() async {
    final key = await _algorithm.newSecretKey();
    return base64Encode(await key.extractBytes());
  }

  static Future<Uint8List> sealBytes(List<int> clear, String keyBase64) async {
    final box = await _algorithm.encrypt(
      clear,
      secretKey: SecretKey(base64Decode(keyBase64)),
    );
    return Uint8List.fromList(box.concatenation());
  }

  static Future<Uint8List> sealFile(File source, String keyBase64) async =>
      sealBytes(await source.readAsBytes(), keyBase64);

  static Future<Uint8List> unsealBytes(
    Uint8List sealed,
    String keyBase64,
  ) async {
    final box = SecretBox.fromConcatenation(
      sealed,
      nonceLength: _nonceLength,
      macLength: _macLength,
    );
    final clear = await _algorithm.decrypt(
      box,
      secretKey: SecretKey(base64Decode(keyBase64)),
    );
    return Uint8List.fromList(clear);
  }

  /// Déchiffre [sealed] et écrit le clair dans [target].
  ///
  /// ⚠️ Le fichier produit est **en clair sur le disque** : il ne doit vivre
  /// que le temps de l'affichage, et l'appelant doit le supprimer en quittant
  /// l'écran. C'est le compromis assumé pour que le lecteur vidéo et
  /// `Image.file` continuent de fonctionner sans être réécrits.
  static Future<File> unsealToFile(
    File sealed,
    String keyBase64,
    File target,
  ) async {
    final clear = await unsealBytes(await sealed.readAsBytes(), keyBase64);
    await target.writeAsBytes(clear, flush: true);
    return target;
  }
}
