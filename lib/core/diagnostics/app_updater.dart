import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'diagnostic_bundle.dart';

/// Ce qu'on sait de la dernière version publiée.
class LatestBuild {
  const LatestBuild({
    required this.version,
    required this.notes,
    required this.assetUrl,
    required this.assetName,
    required this.sizeBytes,
  });

  final String version;
  final String notes;
  final String assetUrl;
  final String assetName;
  final int sizeBytes;
}

/// Télécharge et lance l'installation de la dernière release.
///
/// ## Ce que ça fait gagner, et ce que ça ne peut pas faire
///
/// Demande de Jay, 2026-08-16 : un bouton qui évite d'aller chercher l'APK à la
/// main. Le bouton supprime cinq gestes sur six — trouver la release, choisir
/// le bon fichier, ouvrir les téléchargements, lancer le fichier.
///
/// ⚠️ **Le sixième est incontournable.** Android n'autorise **aucune
/// installation silencieuse** : le système affiche toujours sa propre demande
/// de confirmation. Seule une application propriétaire de l'appareil (kiosque,
/// MDM) y échappe, et ce n'est pas notre cas. Promettre « ça s'installe tout
/// seul » serait faux.
///
/// ## Pourquoi un jeton facultatif
///
/// Jay a rendu le dépôt **public le 2026-08-16, exceptionnellement**, pour
/// pouvoir télécharger l'APK sur une tablette où il n'est pas connecté à
/// GitHub — et il le repassera en privé après les tests à deux appareils.
///
/// Un outil qui ne marcherait qu'en dépôt public **mourrait donc à la fin de la
/// semaine**. Il accepte un jeton GitHub en lecture seule, rangé dans le
/// Keystore de l'appareil : rien dans le dépôt, rien dans l'APK, et l'outil
/// survit au retour en privé. Sans jeton, il fonctionne tant que le dépôt est
/// public, et **le dit** quand ce n'est plus le cas.
///
/// ⚠️ **Outil de développement** — à retirer avec la section Développeur avant
/// la prod, avec la permission `REQUEST_INSTALL_PACKAGES` du manifeste
/// (`RAPPELS.md`).
class AppUpdater {
  static const repo = 'Gatsby4444/neovibe_alpha';
  static const _tokenKey = 'nv_github_token';
  static const _storage = FlutterSecureStorage();
  static const _channel = MethodChannel('neovibe/install');

  /// Le jeton, s'il a été posé. **Jamais dans le dépôt, jamais dans l'APK.**
  static Future<String?> token() => _storage.read(key: _tokenKey);

  static Future<void> setToken(String? value) => value == null || value.isEmpty
      ? _storage.delete(key: _tokenKey)
      : _storage.write(key: _tokenKey, value: value);

  /// La version actuellement installée, lue **dans le paquet Android**.
  static Future<String> installedVersion() async {
    final info = await DiagnosticBundle.deviceInfo();
    return info['appVersion'] ?? '?';
  }

  /// Interroge GitHub. Lève avec un message lisible en cas de refus.
  static Future<LatestBuild> latest() async {
    final headers = <String, String>{'Accept': 'application/vnd.github+json'};
    final tok = await token();
    if (tok != null && tok.isNotEmpty) headers['Authorization'] = 'Bearer $tok';

    final res = await http.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: headers,
    );
    if (res.statusCode == 404) {
      throw StateError(
        tok == null
            // Le cas exact qui arrivera quand Jay repassera le dépôt en privé.
            ? 'Dépôt introuvable. S\'il est redevenu privé, colle un jeton '
                  'GitHub en lecture seule ci-dessous.'
            : 'Dépôt ou release introuvable — le jeton a-t-il accès à ce dépôt ?',
      );
    }
    if (res.statusCode != 200) {
      throw StateError('GitHub a répondu ${res.statusCode}.');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final assets = (json['assets'] as List? ?? []).cast<Map<String, dynamic>>();
    // On prend l'arm64 : c'est le format de build tranché par Jay le
    // 2026-08-14 pour les APK de test.
    final asset = assets.firstWhere(
      (a) => '${a['name']}'.contains('arm64'),
      orElse: () => assets.isEmpty
          ? throw StateError('Cette release ne contient aucun APK.')
          : assets.first,
    );

    return LatestBuild(
      version: '${json['tag_name']}'.replaceFirst('v', ''),
      notes: '${json['body'] ?? ''}',
      assetUrl: '${asset['url']}', // l'URL d'API, la seule qui marche en privé
      assetName: '${asset['name']}',
      sizeBytes: asset['size'] as int? ?? 0,
    );
  }

  /// Télécharge l'APK. [onProgress] reçoit une fraction de 0 à 1.
  static Future<File> download(
    LatestBuild build, {
    void Function(double)? onProgress,
  }) async {
    final headers = <String, String>{
      // ⚠️ `octet-stream` et non `github+json` : sans ça, l'API renvoie la
      // FICHE de l'asset en JSON au lieu du fichier. On téléchargerait alors
      // quelques kilo-octets de métadonnées nommés `.apk`, et l'installateur
      // se plaindrait d'un paquet corrompu — sans qu'on comprenne pourquoi.
      'Accept': 'application/octet-stream',
    };
    final tok = await token();
    if (tok != null && tok.isNotEmpty) headers['Authorization'] = 'Bearer $tok';

    final request = http.Request('GET', Uri.parse(build.assetUrl))
      ..headers.addAll(headers)
      ..followRedirects = true;
    final response = await http.Client().send(request);
    if (response.statusCode != 200) {
      throw StateError('Téléchargement refusé (${response.statusCode}).');
    }

    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${build.assetName}');
    final sink = file.openWrite();
    var received = 0;
    final total = response.contentLength ?? build.sizeBytes;
    await response.stream
        .map((chunk) {
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
          return chunk;
        })
        .pipe(sink);
    return file;
  }

  /// Demande au système d'installer [apk].
  ///
  /// ⚠️ Rend la main **immédiatement** : c'est Android qui affiche sa
  /// confirmation, et rien ne nous dit ensuite si l'utilisateur a accepté. Une
  /// interface qui annoncerait « installé » ici mentirait une fois sur deux.
  static Future<void> install(File apk) =>
      _channel.invokeMethod('install', {'path': apk.path});

  /// Compare deux versions `x.y.z`. Rend vrai si [candidate] est plus récente.
  ///
  /// Comparaison **numérique par segment**, jamais alphabétique : `0.9.100`
  /// vient après `0.9.99`, alors que l'ordre des chaînes dit l'inverse. Ce
  /// piège est arrivé pour de bon le 2026-08-16, en passant de 99 à 100.
  static bool isNewer(String candidate, String installed) {
    List<int> parts(String v) =>
        v.split(RegExp(r'[.+\-]')).map((p) => int.tryParse(p) ?? 0).toList();
    final a = parts(candidate), b = parts(installed);
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
