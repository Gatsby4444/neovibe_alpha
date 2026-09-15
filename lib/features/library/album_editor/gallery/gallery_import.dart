import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/utils/ids.dart';
import '../../../cards/native_media.dart';
import '../album_draft.dart';
import 'native_gallery.dart';

/// **De la galerie au brouillon** : copie un média dans notre cache, le sonde
/// (dimensions après rotation, durée), et le transforme en [AlbumDraftMedia].
/// Une vidéo trop longue est proposée à la **découpe** (Jay : *« la découper
/// et répartir automatiquement sur plusieurs contenus du carrousel »*) ;
/// refusée, elle est gardée en un seul média rogné à ses 60 premières secondes.
abstract final class GalleryImport {
  /// Copie [entry] dans le cache de l'app et rend le fichier.
  static Future<File> copy(GalleryEntry entry) async {
    final temp = await getTemporaryDirectory();
    final ext = entry.isVideo ? 'mp4' : 'jpg';
    final dest = File('${temp.path}/gallery_${newUuid()}.$ext');
    await NativeGallery.copy(entry.uri, dest.path);
    return dest;
  }

  /// Les médias retenus, dans l'ordre de sélection, bornés par [freeSlots].
  /// Demande la découpe des vidéos longues ; dit ce qui n'a pas été gardé.
  static Future<List<AlbumDraftMedia>> toDraftMedia(
    BuildContext context,
    List<GalleryEntry> entries, {
    required int freeSlots,
  }) async {
    final files = <File>[];
    for (final e in entries) {
      try {
        files.add(await copy(e));
      } catch (_) {
        // Un fichier illisible n'arrête pas les autres.
      }
    }
    if (!context.mounted) return const [];
    return fromFiles(context, files, freeSlots: freeSlots);
  }

  /// Des fichiers locaux (copies de la galerie, ou prises de l'appareil
  /// photo) → des médias de brouillon, sondés.
  static Future<List<AlbumDraftMedia>> fromFiles(
    BuildContext context,
    List<File> files, {
    required int freeSlots,
  }) async {
    final out = <AlbumDraftMedia>[];
    var illisibles = 0;
    for (final f in files) {
      if (out.length >= freeSlots) break;
      final MediaProbe probe;
      try {
        probe = await NativeMedia.probe(f.path);
      } catch (_) {
        illisibles += 1;
        continue;
      }
      if (!probe.isVideo) {
        out.add(
          AlbumDraftMedia(
            id: newUuid(),
            source: f,
            isVideo: false,
            srcWidth: probe.width,
            srcHeight: probe.height,
            rotation: probe.rotation,
          ),
        );
        continue;
      }
      final duration = probe.durationMs ?? 0;
      AlbumDraftMedia video(VideoTrim? trim) => AlbumDraftMedia(
        id: newUuid(),
        source: f,
        isVideo: true,
        srcWidth: probe.width,
        srcHeight: probe.height,
        rotation: probe.rotation,
        durationMs: duration,
        trim: trim,
      );
      if (duration <= kAlbumMaxVideoMs) {
        out.add(video(null));
        continue;
      }
      final places = freeSlots - out.length;
      final parts = AlbumDraft.splitPlan(duration, freeSlots: places);
      if (!context.mounted) return out;
      final decoupe =
          parts.length > 1 &&
          await _proposerDecoupe(
            context,
            duration: duration,
            parts: parts.length,
            tout: parts.last.endMs >= duration - 999,
          );
      if (decoupe) {
        out.addAll(parts.map(video));
      } else {
        out.add(video(VideoTrim(startMs: 0, endMs: kAlbumMaxVideoMs)));
      }
    }
    if (!context.mounted) return out;
    final ignores = files.length - out.length - illisibles;
    if (ignores > 0 || illisibles > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            [
              if (ignores > 0)
                '$ignores média${ignores > 1 ? 's' : ''} non gardé'
                    '${ignores > 1 ? 's' : ''} : $kAlbumMaxMedia au plus.',
              if (illisibles > 0)
                '$illisibles fichier${illisibles > 1 ? 's' : ''} illisible'
                    '${illisibles > 1 ? 's' : ''}.',
            ].join(' '),
          ),
        ),
      );
    }
    return out;
  }

  /// L'appareil photo du téléphone : une photo, ou une vidéo d'une minute
  /// au plus. Rend le fichier, ou nul si l'utilisateur renonce.
  static Future<File?> capture(BuildContext context) async {
    final video = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.photo_camera_outlined,
                color: Colors.white,
              ),
              title: const Text(
                'Prendre une photo',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(context, false),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined, color: Colors.white),
              title: const Text(
                'Filmer',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                '1 minute au plus',
                style: TextStyle(color: Colors.white54),
              ),
              onTap: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (video == null) return null;
    final picker = ImagePicker();
    final XFile? f;
    if (video) {
      f = await picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(milliseconds: kAlbumMaxVideoMs),
      );
    } else {
      f = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 2160,
        maxHeight: 2160,
        imageQuality: 92,
      );
    }
    return f == null ? null : File(f.path);
  }

  static Future<bool> _proposerDecoupe(
    BuildContext context, {
    required int duration,
    required int parts,
    required bool tout,
  }) async {
    final minutes = duration ~/ 60000;
    final secondes = (duration % 60000) ~/ 1000;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vidéo trop longue'),
        content: Text(
          'Cette vidéo dure $minutes min ${secondes.toString().padLeft(2, '0')} s. '
          'Un média dure au plus 1 minute.\n\n'
          'La découper en $parts morceaux qui se suivent dans la publication'
          '${tout ? '' : ' (le reste ne tiendra pas)'} ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Garder la 1re minute'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Découper'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}
