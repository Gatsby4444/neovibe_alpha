import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/crypto/sealed_bytes.dart';
import 'admin_repository.dart';

/// **Voir la preuve d'un signalement** (2026-09-25) — le média tel que son
/// auteur l'a déposé, gardé sous scellé tant que le signalement est ouvert
/// (`supabase/migrations/20260925120000_le_scelle_de_moderation.sql`), même si
/// l'auteur a supprimé sa Vibe entre-temps.
///
/// Déchiffré **en mémoire**, dans le navigateur ([SealedBytes]) : rien n'est
/// écrit, et fermer la fenêtre l'oublie.
Future<void> showEvidence(
  BuildContext context, {
  required String kind,
  required String reportId,
}) => showDialog<void>(
  context: context,
  builder: (_) => _EvidenceDialog(kind: kind, reportId: reportId),
);

class _Face {
  const _Face({required this.bytes, required this.isVideo, required this.rang});
  final Uint8List bytes;
  final bool isVideo;
  final int rang;
}

final _evidenceProvider = FutureProvider.autoDispose
    .family<List<_Face>, ({String kind, String id})>((ref, r) async {
      final repo = ref.read(adminRepositoryProvider);
      final rows = await repo.evidence(r.kind, r.id);
      return [
        for (final row in rows)
          _Face(
            bytes: await SealedBytes.open(
              await repo.heldBytes(
                row['bucket_id'] as String,
                row['object_name'] as String,
              ),
              row['media_key'] as String?,
            ),
            isVideo: row['is_video'] as bool? ?? false,
            rang: (row['rang'] as num).toInt(),
          ),
      ];
    });

class _EvidenceDialog extends ConsumerWidget {
  const _EvidenceDialog({required this.kind, required this.reportId});
  final String kind;
  final String reportId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final faces = ref.watch(_evidenceProvider((kind: kind, id: reportId)));
    return AlertDialog(
      title: const Text('Preuve du signalement'),
      content: SizedBox(
        width: 720,
        height: 560,
        child: faces.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Illisible : $e')),
          data: (list) => list.isEmpty
              ? const Center(
                  child: Text(
                    'Aucun média sous scellé pour ce signalement.',
                    textAlign: TextAlign.center,
                  ),
                )
              : Row(
                  children: [
                    for (final f in list)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Column(
                            children: [
                              Text(
                                list.length > 2
                                    ? 'Diapo ${f.rang + 1}'
                                    : (f.rang == 0 ? 'Recto' : 'Verso'),
                              ),
                              const SizedBox(height: 6),
                              Expanded(
                                child: f.isVideo
                                    ? _Video(bytes: f.bytes)
                                    : Image.memory(
                                        f.bytes,
                                        fit: BoxFit.contain,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}

/// Une vidéo déchiffrée en mémoire, lue par le navigateur depuis ses octets.
class _Video extends StatefulWidget {
  const _Video({required this.bytes});
  final Uint8List bytes;

  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  late final VideoPlayerController _c = VideoPlayerController.networkUrl(
    Uri.dataFromBytes(widget.bytes, mimeType: 'video/mp4'),
  );

  @override
  void initState() {
    super.initState();
    _c.initialize().then((_) {
      if (mounted) setState(() {});
      _c.setLooping(true);
      _c.play();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _c.value.isInitialized
      ? AspectRatio(aspectRatio: _c.value.aspectRatio, child: VideoPlayer(_c))
      : const Center(child: CircularProgressIndicator());
}
