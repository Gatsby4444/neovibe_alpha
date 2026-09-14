import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme.dart';
import '../../../core/utils/ids.dart';
import '../../cards/native_media.dart';
import 'album_draft.dart';

/// **Choisir** les médias d'un album : la galerie (plusieurs, photos et
/// vidéos), l'appareil photo, ou la caméra du téléphone.
///
/// Rend des [AlbumDraftMedia] déjà **sondés** (dimensions après rotation,
/// durée) — le brouillon n'a pas à ouvrir les fichiers. Une vidéo trop longue
/// est proposée à la **découpe** (Jay : *« la découper et répartir
/// automatiquement sur plusieurs contenus du carrousel »*) ; refusée, elle est
/// gardée en un seul média rogné à ses 60 premières secondes.
///
/// La galerie et l'appareil sont ceux du système (`image_picker`, déjà utilisé
/// pour l'avatar et l'import d'une face) : c'est la seule étape où un composant
/// tiers voit une image, et il ne fait que la **rendre** — tout ce qui suit
/// (recadrage, filtres, export) est chez nous, comme le recadreur d'avatar.
abstract final class AlbumPicker {
  /// Ouvre le choix de la source, puis rend les médias retenus — vide si
  /// l'utilisateur renonce. [freeSlots] borne ce qui est gardé.
  static Future<List<AlbumDraftMedia>> pick(
    BuildContext context, {
    required int freeSlots,
  }) async {
    if (freeSlots <= 0) return const [];
    final source = await showModalBottomSheet<_Source>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galerie'),
              subtitle: Text(
                'Photos et vidéos, jusqu\'à $freeSlots',
                style: TextStyle(color: context.muted),
              ),
              onTap: () => Navigator.pop(context, _Source.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(context, _Source.photo),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Filmer'),
              subtitle: Text(
                '1 minute au plus',
                style: TextStyle(color: context.muted),
              ),
              onTap: () => Navigator.pop(context, _Source.video),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return const [];

    final picker = ImagePicker();
    final files = <XFile>[];
    switch (source) {
      case _Source.gallery:
        files.addAll(
          await picker.pickMultipleMedia(
            limit: freeSlots,
            // Les photos sont ramenées à une taille raisonnable AVANT de nous
            // arriver : l'éditeur n'a pas besoin de 12 Mpx pour sortir 1080 px.
            maxWidth: 2160,
            maxHeight: 2160,
            imageQuality: 92,
          ),
        );
      case _Source.photo:
        final f = await picker.pickImage(
          source: ImageSource.camera,
          maxWidth: 2160,
          maxHeight: 2160,
          imageQuality: 92,
        );
        if (f != null) files.add(f);
      case _Source.video:
        final f = await picker.pickVideo(
          source: ImageSource.camera,
          maxDuration: const Duration(milliseconds: kAlbumMaxVideoMs),
        );
        if (f != null) files.add(f);
    }
    if (files.isEmpty || !context.mounted) return const [];

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
            source: File(f.path),
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
        source: File(f.path),
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
      // Trop longue : proposer la découpe.
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

enum _Source { gallery, photo, video }
