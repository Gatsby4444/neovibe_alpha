import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'content_face.dart';

/// Cache local des médias du **socle de contenu** (stories et publications) —
/// séparé de celui des Cards.
///
/// Ce n'est pas une duplication par négligence. Le cache des Cards raisonne en
/// budgets de vues et en TTL de message ; ces contenus-là n'ont ni l'un ni
/// l'autre. Ce qui les distingue entre eux est une seule donnée : leur date
/// d'expiration, **nulle pour une publication** (permanente, décision de Jay
/// du 2026-08-11) et à 24 h pour une story.
///
/// Deux espaces :
/// - `own/`    : MES contenus, déposés à la publication. Jamais retéléchargés —
///   l'affichage de mes propres contenus ne doit pas dépendre du réseau.
/// - `others/` : ce que je consulte, gardé jusqu'à expiration (ou sous plafond
///   global si le contenu est permanent).
///
/// Les fichiers y sont **chiffrés** : le clair ne vit que dans le répertoire
/// temporaire, le temps de l'écran. Une seule règle vaut donc partout — tout
/// fichier de ce cache est un scellé, quelle que soit sa provenance.
class ContentMediaCache {
  ContentMediaCache();

  static const othersMaxBytes = 150 * 1024 * 1024; // 150 Mo

  /// Plafond de l'espace `own/` — MES contenus, déposés à la publication.
  ///
  /// ## 🔴 Il n'y en avait AUCUN avant le 2026-08-31
  ///
  /// `tryOwn` marquait la date d'accès avec un commentaire `// usage LRU`, et
  /// **aucune éviction ne lisait cette date** : `_enforceLimits` ne balayait que
  /// `others/`. Chaque story et chaque publication déposait donc ses octets
  /// scellés sur l'appareil, définitivement — seul un « vider le cache » manuel
  /// les enlevait.
  ///
  /// ⚠️ **Le mécanisme existait pourtant, à côté** : `CardMediaCache` a son
  /// `_enforceOwnQuota`, qui trie exactement sur cette date. Il a été écrit d'un
  /// côté et oublié de l'autre — et la marque restée en place faisait croire au
  /// lecteur que les deux se ressemblaient.
  ///
  /// 200 Mo : plus généreux que `others/`, parce que perdre le cache de MON
  /// contenu coûte un téléchargement de ce que j'ai moi-même publié.
  ///
  /// ## 🔴 Passé à 600 Mo le 2026-09-20, avec une grâce de 24 h
  ///
  /// Une publication de 19 vidéos à 3,5 Mbit/s pèse à elle seule plus de
  /// 200 Mo : le plafond était **plus petit qu'une publication**. Le balai
  /// tournait juste après l'inscription et effaçait les premières places de
  /// ce que Jay venait de publier — pendant qu'il les regardait. Deux
  /// symptômes chez lui : « Source error » (le fichier retiré sous un lecteur
  /// suspendu) et « média introuvable : …/own/…_front.seal » (l'ouverture,
  /// mise en cache par le fournisseur, pointait encore sur le fichier
  /// effacé). Un cache qui efface ce qu'on regarde n'est pas un cache.
  ///
  /// Désormais : un fichier touché (copié ou ouvert) depuis moins de
  /// [ownGrace] n'est **jamais** balayé ; le plafond ne joue que sur le
  /// reste. Ce qu'on vient de publier reste sur l'appareil au moins un jour.
  static const ownMaxBytes = 600 * 1024 * 1024; // 600 Mo

  /// Ce qui a été touché depuis moins longtemps que ça est intouchable.
  static const ownGrace = Duration(hours: 24);

  Directory? _root;
  Map<String, dynamic>? _index;

  Future<Directory> _dir(String sub) async {
    _root ??= await getApplicationSupportDirectory();
    final dir = Directory(
      '${_root!.path}${Platform.pathSeparator}content_media'
      '${Platform.pathSeparator}$sub',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Le fichier d'une place. Les places 0 et 1 gardent leurs anciens noms
  /// (`front` / `back`) : les caches déjà posés sur les appareils restent
  /// valables après le passage aux places (2026-09-15).
  File _faceFile(Directory dir, String contentId, int slot) => File(
    '${dir.path}${Platform.pathSeparator}${contentId}_'
    '${switch (slot) {
      ContentSlot.front => 'front',
      ContentSlot.back => 'back',
      _ => 'slot$slot',
    }}.seal',
  );

  // ---------------------------------------------------------------------
  // « Complet » se dit PAR PLACE (2026-09-15)
  // ---------------------------------------------------------------------
  //
  // L'index portait un seul `complete` par contenu. Juste pour deux faces
  // téléchargées d'un bloc ; faux pour un album de onze médias : la place 0
  // arrivée aurait déclaré les dix autres complètes, et [others] aurait rendu
  // un fichier partiel — ou absent — comme s'il était entier. Le champ est
  // désormais la liste des places complètes ; un ancien `true` se lit comme
  // « la place 0 » (les caches existants ne portaient qu'elle en entier).

  static List<int> _completeSlots(Object? meta) {
    if (meta is! Map) return const [];
    final raw = meta['complete'];
    if (raw == true) return const [ContentSlot.front];
    if (raw is List) return raw.cast<int>();
    return const [];
  }

  static void _markComplete(Map<String, dynamic> meta, int slot) {
    final slots = {..._completeSlots(meta), slot}.toList()..sort();
    meta['complete'] = slots;
  }

  // ---------------------------------------------------------------------
  // Index des entrées `others/` : la date d'expiration, ou rien.
  // ---------------------------------------------------------------------

  Future<File> _indexFile() async =>
      File('${(await _dir('others')).path}${Platform.pathSeparator}index.json');

  Future<Map<String, dynamic>> _loadIndex() async {
    if (_index != null) return _index!;
    try {
      final file = await _indexFile();
      _index = await file.exists()
          ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      _index = <String, dynamic>{};
    }
    return _index!;
  }

  Future<void> _saveIndex() async {
    if (_index == null) return;
    try {
      await (await _indexFile()).writeAsString(jsonEncode(_index));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Mes contenus
  // ---------------------------------------------------------------------

  /// **Où** le scellé d'une de MES places se range — pour la file de
  /// publication native, qui y copie elle-même ce qu'elle a scellé une fois
  /// la publication inscrite (2026-09-19). Le chemin, pas le fichier : une
  /// seule définition du rangement, ici.
  Future<String> ownPath(String contentId, {required int slot}) async =>
      _faceFile(await _dir('own'), contentId, slot).path;

  /// Dépose le scellé d'une de MES faces, à la publication.
  Future<void> storeOwn(
    String contentId,
    File sealed, {
    required int slot,
  }) async {
    try {
      await sealed.copy(_faceFile(await _dir('own'), contentId, slot).path);
      await enforceOwnLimit();
    } catch (_) {
      // Le cache est un confort : un échec ne doit jamais bloquer la
      // publication (le contenu existe déjà côté serveur à ce moment-là).
    }
  }

  Future<File?> tryOwn(String contentId, {required int slot}) async {
    final file = _faceFile(await _dir('own'), contentId, slot);
    if (!await file.exists()) return null;
    try {
      // La date d'accès, lue par [enforceOwnLimit] : les moins récemment
      // OUVERTES partent d'abord, pas les plus anciennement créées.
      //
      // ⚠️ Jusqu'au 2026-08-31, cette ligne portait `// usage LRU` et **rien ne
      // lisait cette date** : il n'existait aucune éviction sur `own/`. Le
      // commentaire décrivait un mécanisme absent.
      await file.setLastModified(DateTime.now());
    } catch (_) {}
    return file;
  }

  /// Ramène `own/` sous [ownMaxBytes] : les faces les moins récemment ouvertes
  /// repassent au cloud.
  ///
  /// Perdre une face de MON contenu n'est pas grave : elle se retéléchargera
  /// depuis le coffre, où elle est toujours. C'est un cache, pas un original.
  Future<void> enforceOwnLimit() async {
    final dir = await _dir('own');
    var total = 0;
    final fichiers = <(File, DateTime, int)>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      total += stat.size;
      fichiers.add((entity, stat.modified, stat.size));
    }
    if (total <= ownMaxBytes) return;
    fichiers.sort((a, b) => a.$2.compareTo(b.$2)); // le plus vieux d'abord
    final limite = DateTime.now().subtract(ownGrace);
    for (final (file, touche, size) in fichiers) {
      if (total <= ownMaxBytes) break;
      // Touché récemment : on le regarde peut-être en ce moment même.
      if (touche.isAfter(limite)) continue;
      try {
        await file.delete();
        total -= size;
      } catch (_) {}
    }
  }

  /// Où vit le cache **partiel** d'une face lue en flux.
  ///
  /// C'est **le même fichier** que celui d'un téléchargement complet : une fois
  /// tous ses blocs arrivés, un cache partiel EST le fichier scellé d'origine,
  /// octet pour octet. Deux caches aux règles différentes pour le même objet
  /// auraient été un chemin de plus à tenir — la règle 2 de `CLAUDE.md`.
  ///
  /// L'entrée d'index est posée **à l'ouverture** et non à la fin du
  /// téléchargement : sinon une vidéo regardée à moitié échapperait à la
  /// politique de rétention et ne serait jamais purgée.
  Future<String> streamingPath(
    String contentId, {
    required int slot,
    DateTime? expiresAt,
  }) async {
    final file = _faceFile(await _dir('others'), contentId, slot);
    final index = await _loadIndex();
    if (!index.containsKey(contentId)) {
      index[contentId] = {
        if (expiresAt != null) 'expiresAt': expiresAt.toIso8601String(),
        'storedAt': DateTime.now().toIso8601String(),
        // ⚠️ **Aucune place complète, explicitement — c'est le correctif du
        // 2026-08-31.** Voir [others] : « le fichier existe » n'est PAS « le
        // fichier est complet », et c'est ici que la différence naît.
        'complete': <int>[],
      };
      await _saveIndex();
    }
    return file.path;
  }

  // ---------------------------------------------------------------------
  // Les contenus des autres
  // ---------------------------------------------------------------------

  /// Scellé d'une face d'autrui : depuis le cache s'il est là, sinon
  /// téléchargé puis indexé. [expiresAt] nul = contenu permanent (publication).
  Future<File> others(
    String contentId, {
    required int slot,
    required Future<String> Function() signedUrl,
    DateTime? expiresAt,
  }) async {
    final file = _faceFile(await _dir('others'), contentId, slot);
    final index = await _loadIndex();
    // 🔴 **« LE FICHIER EXISTE » N'EST PAS « LE FICHIER EST COMPLET » —
    // corrigé le 2026-08-31.**
    //
    // Cette condition était `file.exists() && index.containsKey(contentId)`.
    // Or [streamingPath] pose l'entrée d'index **avant** tout téléchargement, et
    // le lecteur natif crée le fichier dès l'ouverture — vide s'il refuse le
    // média.
    //
    // Conséquence : le repli des vidéos scellées **avant** le format par blocs
    // appelait cette méthode, recevait un fichier de zéro octet présenté comme
    // complet, et échouait au déchiffrement. Le repli écrit exactement pour ces
    // contenus ne pouvait pas s'exécuter.
    //
    // ⚠️ Le partage du même fichier entre le cache partiel et le téléchargement
    // complet reste le bon choix (un cache partiel rempli EST le fichier
    // scellé). Ce qui manquait, c'est de savoir lequel des deux on tient.
    final connu = index[contentId];
    final complet = _completeSlots(connu).contains(slot);
    if (await file.exists() && complet) return file;
    await _download(await signedUrl(), file);
    final meta = connu is Map<String, dynamic>
        ? connu
        : <String, dynamic>{
            if (expiresAt != null) 'expiresAt': expiresAt.toIso8601String(),
            'storedAt': DateTime.now().toIso8601String(),
          };
    _markComplete(meta, slot);
    index[contentId] = meta;
    await _saveIndex();
    await _enforceLimits();
    return file;
  }

  /// Purge immédiate de toutes les faces d'un contenu : expiration, retrait
  /// par l'auteur, ou **révocation** par la modération.
  Future<void> purge(String contentId) async {
    for (final sub in const ['own', 'others']) {
      final dir = await _dir(sub);
      await for (final entity in dir.list()) {
        if (entity is File &&
            entity.uri.pathSegments.last.startsWith('${contentId}_')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    final index = await _loadIndex();
    if (index.remove(contentId) != null) await _saveIndex();
  }

  /// Expiration puis plafond global. Un contenu expiré n'a aucune raison de
  /// rester : le serveur ne le sert plus.
  Future<void> _enforceLimits() async {
    final index = await _loadIndex();
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in index.entries) {
      final meta = entry.value as Map<String, dynamic>;
      final raw = meta['expiresAt'] as String?;
      if (raw == null) continue; // permanent
      final expiresAt = DateTime.tryParse(raw);
      if (expiresAt == null || now.isAfter(expiresAt)) expired.add(entry.key);
    }
    for (final id in expired) {
      await purge(id);
    }

    final dir = await _dir('others');
    var total = 0;
    final sizes = <String, int>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name == 'index.json') continue;
      final size = (await entity.stat()).size;
      total += size;
      final id = name.split('_').first;
      sizes[id] = (sizes[id] ?? 0) + size;
    }
    if (total <= othersMaxBytes) return;
    // Les plus anciennement stockés partent d'abord.
    final byAge = index.entries.toList()
      ..sort((a, b) {
        final sa = (a.value as Map)['storedAt'] as String? ?? '';
        final sb = (b.value as Map)['storedAt'] as String? ?? '';
        return sa.compareTo(sb);
      });
    for (final entry in byAge) {
      if (total <= othersMaxBytes) break;
      total -= sizes[entry.key] ?? 0;
      await purge(entry.key);
    }
  }

  /// Balayage de démarrage.
  Future<void> sweep() async {
    try {
      await _enforceLimits();
    } catch (_) {}
  }

  Future<int> _dirSize(String sub) async {
    var total = 0;
    await for (final entity in (await _dir(sub)).list()) {
      if (entity is File) total += (await entity.stat()).size;
    }
    return total;
  }

  /// Occupation actuelle (octets), pour l'écran de gestion du stockage.
  Future<({int ownBytes, int othersBytes})> usage() async =>
      (ownBytes: await _dirSize('own'), othersBytes: await _dirSize('others'));

  Future<void> clear() async {
    for (final sub in const ['own', 'others']) {
      final dir = await _dir(sub);
      await for (final entity in dir.list()) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    _index = <String, dynamic>{};
  }

  /// Un téléchargement qui n'aboutit pas doit **échouer**, pas attendre.
  ///
  /// Sans délai maximal, une requête bloquée laissait l'écran sur son
  /// indicateur de chargement pour toujours : l'utilisateur ne peut ni
  /// comprendre ni réessayer. Mieux vaut une erreur visible qu'une attente
  /// silencieuse.
  static const _timeout = Duration(seconds: 25);

  Future<void> _download(String url, File target) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('Téléchargement échoué (${response.statusCode})');
      }
      final tmp = File('${target.path}.part');
      await response.pipe(tmp.openWrite()).timeout(_timeout);
      await tmp.rename(target.path);
    } finally {
      client.close(force: true);
    }
  }
}

final contentMediaCacheProvider = Provider((ref) => ContentMediaCache());
