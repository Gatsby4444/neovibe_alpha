import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Le cache local des **scellés** de bibliothèque de conversation.
///
/// ### L'idée, formulée par Jay le 2026-08-13
///
/// > « On télécharge les contenus de la bibliothèque 5 minutes avant le reveal.
/// > L'utilisateur ouvre les cards instantanément et ne voit même pas le
/// > téléchargement — **comme si les cards étaient toujours là mais qu'elles
/// > étaient juste bloquées en local.** »
///
/// C'est une conception, pas une optimisation, et elle vaut mieux que la
/// lecture par intervalles sur ce chemin précis. Une vibe de bibliothèque est
/// **connue d'avance** : elle est annoncée dans le fil et son heure de reveal
/// est écrite. Il n'y a donc rien à deviner — contrairement à un feed, où l'on
/// ne sait pas ce que l'utilisateur regardera ensuite. Quand on peut tout
/// amener d'avance, streamer n'apporte rien.
///
/// ### Pourquoi les garder SUR LE DISQUE et non en mémoire
///
/// Jusqu'au 2026-08-13, les octets préchargés vivaient dans l'état d'un
/// widget (`_VibeTileState._sealed`) : ils **mouraient avec l'écran**. Sortir
/// de la bibliothèque et y revenir retéléchargeait tout, et rouvrir une vibe
/// déjà révélée le lendemain aussi. L'illusion voulue par Jay — « elles ont
/// toujours été là » — ne tenait que pendant la minute qui suivait le reveal.
///
/// ### Pourquoi c'est sans danger
///
/// Ces octets sont **chiffrés**, et la clé n'est pas sur l'appareil : elle est
/// retenue par le serveur jusqu'au reveal (`get_library_vibe_key`). Un scellé
/// posé sur le disque n'est donc rien de plus qu'un bloc d'octets inertes. La
/// barrière du reveal n'est pas affaiblie d'un pouce — **elle est même mieux
/// énoncée** : le contenu est *présent mais verrouillé*, au lieu d'être
/// *absent parce qu'on refuse de le livrer*.
///
/// ⚠️ La barrière des 5 minutes est tenue **par le serveur**, dans la politique
/// du coffre `library_vault` (`now() >= reveal_at - interval '5 minutes'`).
/// Ce cache n'en décide rien : il ne fait que conserver ce que le serveur a
/// bien voulu livrer.
class LibraryVaultCache {
  LibraryVaultCache();

  /// Au-delà, les scellés les plus anciennement stockés partent. Plus petit
  /// que le cache du socle (150 Mo) : une bibliothèque de conversation est
  /// bornée par une journée de collecte, pas par un fil infini.
  static const maxBytes = 80 * 1024 * 1024; // 80 Mo

  Directory? _root;

  Future<Directory> _dir() async {
    _root ??= await getApplicationSupportDirectory();
    final dir = Directory(
      '${_root!.path}${Platform.pathSeparator}library_vault',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String vibeId, bool front) async => File(
    '${(await _dir()).path}${Platform.pathSeparator}'
    '${vibeId}_${front ? 'front' : 'back'}.seal',
  );

  /// Le scellé de cette face, s'il est déjà sur l'appareil.
  ///
  /// Touche la date de dernier accès : l'éviction est un LRU, et une vibe
  /// souvent rouverte ne doit pas partir avant une vibe oubliée.
  Future<File?> tryFace(String vibeId, {required bool front}) async {
    final file = await _file(vibeId, front);
    if (!await file.exists()) return null;
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {}
    return file;
  }

  /// Dépose le scellé d'une face et rend le fichier écrit.
  ///
  /// Écrit d'abord à côté puis renomme : sans ça, un téléchargement interrompu
  /// laisserait un fichier **tronqué** que `tryFace` rendrait ensuite comme
  /// valide, et la vibe deviendrait illisible sans qu'aucune erreur ne dise
  /// pourquoi.
  Future<File> store(
    String vibeId,
    Uint8List bytes, {
    required bool front,
  }) async {
    final target = await _file(vibeId, front);
    final temp = File('${target.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
    return target;
  }

  /// Oublie les deux faces d'une vibe — à la suppression, ou quand le serveur
  /// ne la sert plus.
  Future<void> purge(String vibeId) async {
    for (final front in [true, false]) {
      try {
        final file = await _file(vibeId, front);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  /// Ramène le cache sous [maxBytes], les scellés les moins récemment lus
  /// d'abord.
  Future<void> _enforceLimit() async {
    final dir = await _dir();
    final files = <File>[];
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      // Un `.part` est le reste d'un téléchargement interrompu : il ne sera
      // jamais lu, il part sans compter.
      if (entity.path.endsWith('.part')) {
        try {
          await entity.delete();
        } catch (_) {}
        continue;
      }
      files.add(entity);
      total += (await entity.stat()).size;
    }
    if (total <= maxBytes) return;

    final stats = <File, DateTime>{};
    for (final file in files) {
      stats[file] = (await file.stat()).modified;
    }
    files.sort((a, b) => stats[a]!.compareTo(stats[b]!));
    for (final file in files) {
      if (total <= maxBytes) break;
      total -= (await file.stat()).size;
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// Balayage de démarrage. N'échoue jamais : un cache est un confort.
  Future<void> sweep() async {
    try {
      await _enforceLimit();
    } catch (_) {}
  }

  /// Occupation actuelle, pour l'écran de gestion du stockage.
  Future<int> usageBytes() async {
    var total = 0;
    try {
      await for (final entity in (await _dir()).list()) {
        if (entity is File) total += (await entity.stat()).size;
      }
    } catch (_) {}
    return total;
  }

  Future<void> clear() async {
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

final libraryVaultCacheProvider = Provider((ref) => LibraryVaultCache());
