import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../supabase_providers.dart';

/// Chemin de l'avatar dans le bucket, à partir de ce qui est stocké dans
/// `profiles.avatar_url`.
///
/// Tolère les deux formes, parce que la base contient les deux :
/// - le **chemin** (`<uid>/avatar.jpg`), ce qu'on enregistre depuis le
///   2026-08-10 ;
/// - une ancienne **URL publique** complète, éventuellement suivie d'un
///   `?v=…` de contournement de cache.
String? avatarPath(String? stored) {
  if (stored == null || stored.isEmpty) return null;
  var value = stored;
  const marker = '/avatars/';
  final at = value.indexOf(marker);
  if (at != -1) value = value.substring(at + marker.length);
  final query = value.indexOf('?');
  if (query != -1) value = value.substring(0, query);
  return value.isEmpty ? null : value;
}

// ⚠️ `avatarUrlProvider` a été SUPPRIMÉ le 2026-08-13. Il signait une URL
// valable une heure, que `NetworkImage` allait chercher à chaque démarrage sur
// une douzaine d'écrans. Il est remplacé par [avatarFileProvider], qui
// télécharge une fois et garde le fichier — voir [AvatarFileCache] pour la
// raison qui rend ce cache sûr.
//
// Le coffre `avatars` reste **privé** (« contrôle total de l'écosystème ») :
// le téléchargement passe toujours par la politique `avatars_read_via_profile`,
// qui vérifie que l'appelant a le droit de voir ce profil. Ce qui change est le
// nombre d'allers-retours, pas la règle.

/// Les avatars déjà téléchargés, sur le disque.
///
/// ### Pourquoi un cache, et pourquoi il est sûr ici
///
/// Un avatar s'affiche sur une douzaine d'écrans, dès l'ouverture de l'app.
/// Sans cache, chacun coûtait **un aller-retour pour signer l'URL, puis un
/// téléchargement** — à chaque démarrage, pour une image de quelques dizaines
/// de kilo-octets qui ne change presque jamais. C'est exactement ce que la
/// consigne « l'affichage de MES contenus ne doit jamais attendre le réseau »
/// proscrit, étendu ici aux avatars des autres, qui sont dans le même cas.
///
/// ⚠️ **Un cache d'avatar est d'ordinaire un piège** : l'image change, le nom
/// ne change pas, et l'ancienne photo reste affichée pour toujours. Il est sûr
/// ici **parce que le chemin est versionné** depuis le 2026-08-13
/// (`avatar_<horodatage>.png`, voir `AvatarService.upload`). Deux images
/// différentes ne portent jamais le même nom, donc une entrée de cache ne peut
/// pas devenir fausse — elle devient seulement inutile, et le balayage s'en
/// charge.
///
/// C'est la même idée que partout ailleurs dans ce projet : on ne garde pas un
/// cache correct à coups de vérifications, on rend l'erreur impossible à
/// représenter.
class AvatarFileCache {
  AvatarFileCache();

  /// Un avatar pèse quelques dizaines de Ko : 200 suffisent largement à couvrir
  /// un cercle d'amis et les profils croisés.
  static const _maxEntries = 200;

  Directory? _root;

  Future<Directory> _dir() async {
    _root ??= await getApplicationSupportDirectory();
    final dir = Directory('${_root!.path}${Platform.pathSeparator}avatars');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Le chemin de stockage (`<uid>/avatar_<n>.png`) devient un nom de fichier
  /// plat : la barre oblique ne peut pas servir de séparateur de dossier ici.
  Future<File> _file(String path) async => File(
    '${(await _dir()).path}${Platform.pathSeparator}'
    '${path.replaceAll('/', '_')}',
  );

  Future<File?> get(String path) async {
    try {
      final file = await _file(path);
      return await file.exists() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// Écrit en `.part` puis renomme : un téléchargement coupé ne doit pas
  /// laisser une image tronquée que [get] rendrait ensuite comme valide.
  Future<File?> put(String path, List<int> bytes) async {
    try {
      final target = await _file(path);
      final temp = File('${target.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
      return target;
    } catch (_) {
      return null;
    }
  }

  Future<void> purge(String? stored) async {
    final path = avatarPath(stored);
    if (path == null) return;
    try {
      final file = await _file(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Balayage de démarrage : les entrées les moins récemment lues d'abord.
  Future<void> sweep() async {
    try {
      final files = <File>[];
      await for (final entity in (await _dir()).list()) {
        if (entity is! File) continue;
        if (entity.path.endsWith('.part')) {
          try {
            await entity.delete();
          } catch (_) {}
          continue;
        }
        files.add(entity);
      }
      if (files.length <= _maxEntries) return;
      final stats = <File, DateTime>{};
      for (final file in files) {
        stats[file] = (await file.stat()).modified;
      }
      files.sort((a, b) => stats[a]!.compareTo(stats[b]!));
      for (final file in files.take(files.length - _maxEntries)) {
        try {
          await file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

final avatarFileCacheProvider = Provider((ref) => AvatarFileCache());

/// Le fichier local d'un avatar : rendu depuis le disque s'il y est, sinon
/// téléchargé une fois puis conservé.
///
/// Nul est un cas **normal** — profil hors de portée, avatar absent, réseau
/// coupé — et l'appelant retombe alors sur l'initiale.
final avatarFileProvider = FutureProvider.family<File?, String>((
  ref,
  stored,
) async {
  final path = avatarPath(stored);
  if (path == null) return null;

  final cache = ref.watch(avatarFileCacheProvider);
  final cached = await cache.get(path);
  if (cached != null) return cached;

  try {
    final bytes = await ref
        .watch(supabaseProvider)
        .storage
        .from('avatars')
        .download(path);
    return cache.put(path, bytes);
  } catch (_) {
    return null;
  }
});

/// Photo de profil, ronde, avec repli.
///
/// Point de passage **unique** pour tout affichage d'avatar. Sans cela, rendre
/// le bucket privé aurait imposé de retoucher treize écrans — et le prochain
/// changement de règle en imposerait treize de plus.
class Avatar extends ConsumerWidget {
  const Avatar({
    super.key,
    required this.stored,
    this.radius = 20,
    this.fallback,
    this.backgroundColor,
  });

  /// Valeur brute de `profiles.avatar_url`.
  final String? stored;
  final double radius;

  /// Affiché tant qu'il n'y a pas d'image : initiale, icône…
  final Widget? fallback;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = stored == null
        ? null
        : ref.watch(avatarFileProvider(stored!)).value;
    return CircleAvatar(
      radius: radius,
      backgroundColor:
          backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
      backgroundImage: file == null ? null : FileImage(file),
      child: file == null ? fallback : null,
    );
  }
}

/// Avatar qui **remplit** son parent, pour les cas où la forme est déjà donnée
/// par le conteneur — typiquement l'anneau dégradé des stories, qui découpe
/// lui-même son enfant.
class AvatarFill extends ConsumerWidget {
  const AvatarFill({super.key, required this.stored, required this.fallback});

  final String? stored;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = stored == null
        ? null
        : ref.watch(avatarFileProvider(stored!)).value;
    if (file == null) return fallback;
    return Image.file(file, fit: BoxFit.cover);
  }
}
