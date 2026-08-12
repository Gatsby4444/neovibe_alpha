import 'package:flutter/material.dart';

import '../../core/video/video_open_trace.dart';

/// Temps d'ouverture des vidéos, mesurés sur l'appareil.
///
/// **Outil de développement** — à retirer avec la section Développeur avant la
/// prod (voir `RAPPELS.md`).
///
/// La cible fixée par Jay le 2026-08-12 : **moins de 300 ms** sur un contenu
/// préchargé ou déjà en cache, **moins d'une seconde** sur un contenu froid.
/// Les deux sont distinguées ici — une moyenne des deux ne voudrait rien dire.
class VideoTimingScreen extends StatefulWidget {
  const VideoTimingScreen({super.key});

  @override
  State<VideoTimingScreen> createState() => _VideoTimingScreenState();
}

class _VideoTimingScreenState extends State<VideoTimingScreen> {
  @override
  Widget build(BuildContext context) {
    final records = VideoOpenTrace.records;
    final cached = records.where((r) => r.cached).toList();
    final cold = records.where((r) => !r.cached).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lecture vidéo — temps d\'ouverture'),
        actions: [
          IconButton(
            tooltip: 'Vider',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(VideoOpenTrace.clear),
          ),
          IconButton(
            tooltip: 'Rafraîchir',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: records.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Aucune mesure.\n\nOuvre une story, une publication ou une '
                  'Vibe vidéo, puis reviens ici.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _Summary(
                  title: 'Déjà sur l\'appareil',
                  target: const Duration(milliseconds: 300),
                  records: cached,
                ),
                const SizedBox(height: 8),
                _Summary(
                  title: 'À froid (téléchargé)',
                  target: const Duration(seconds: 1),
                  records: cold,
                ),
                const Divider(height: 32),
                Text(
                  'Les ${records.length} dernières ouvertures',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (final record in records) _Record(record: record),
              ],
            ),
    );
  }
}

/// Médiane plutôt que moyenne : une seule ouverture lente (réseau qui hoquette)
/// déplacerait la moyenne et ferait croire à une régression.
class _Summary extends StatelessWidget {
  const _Summary({
    required this.title,
    required this.target,
    required this.records,
  });

  final String title;
  final Duration target;
  final List<VideoOpenTrace> records;

  @override
  Widget build(BuildContext context) {
    final totals = records.map((r) => r.total).whereType<Duration>().toList()
      ..sort();
    final median = totals.isEmpty ? null : totals[totals.length ~/ 2];
    final ok = median != null && median <= target;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          median == null
              ? Icons.remove
              : ok
              ? Icons.check_circle
              : Icons.error_outline,
          color: median == null
              ? null
              : ok
              ? Colors.green
              : Colors.orange,
        ),
        title: Text(title),
        subtitle: Text(
          median == null
              ? 'aucune mesure'
              : 'médiane ${median.inMilliseconds} ms sur ${totals.length} — '
                    'cible ${target.inMilliseconds} ms\n'
                    'meilleure ${totals.first.inMilliseconds} ms · '
                    'pire ${totals.last.inMilliseconds} ms',
        ),
        isThreeLine: median != null,
      ),
    );
  }
}

class _Record extends StatelessWidget {
  const _Record({required this.record});

  final VideoOpenTrace record;

  @override
  Widget build(BuildContext context) {
    final steps = VideoOpenStep.values.skip(1); // « demande » vaut zéro
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                record.cached ? Icons.sd_storage : Icons.cloud_download,
                size: 14,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  record.id,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Text(
                record.total == null
                    ? '—'
                    : '${record.total!.inMilliseconds} ms',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          // Le détail par étape est l'intérêt principal de l'écran : il dit
          // QUI a retardé la première image, donc quel chantier engager.
          for (final step in steps)
            if (record.spentOn(step) case final spent?)
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 2),
                child: Text(
                  '${step.label} : +${spent.inMilliseconds} ms',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
        ],
      ),
    );
  }
}
