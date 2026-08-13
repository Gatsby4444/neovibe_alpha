import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/diagnostic_bundle.dart';
import '../../core/video/video_open_trace.dart';

/// Temps d'ouverture des vidéos, mesurés sur l'appareil.
///
/// **Outil de développement** — à retirer avec la section Développeur avant la
/// prod (voir `RAPPELS.md`).
///
/// La cible fixée par Jay le 2026-08-12 : **moins de 300 ms** sur un contenu
/// préchargé ou déjà en cache, **moins d'une seconde** sur un contenu froid.
///
/// Les mesures sont réparties en **trois** seaux, pas deux (voir
/// [MediaAvailability]). Le relevé du 2026-08-13 n'en avait que deux, et le
/// premier mélangeait les vraies lectures locales avec des vidéos à peine
/// entamées : médiane 761 ms, pire mesure 16 s — un chiffre qui ne pouvait
/// rien décider. « Partiel » est la population qui les séparait.
class VideoTimingScreen extends StatefulWidget {
  const VideoTimingScreen({super.key});

  @override
  State<VideoTimingScreen> createState() => _VideoTimingScreenState();
}

class _VideoTimingScreenState extends State<VideoTimingScreen> {
  /// Copie les mesures **et l'appareil** : une médiane sans savoir sur quel
  /// téléphone elle a été relevée ne veut pas dire grand-chose (voir
  /// `RAPPELS.md`, avant-prod #8 — on ne teste que sur un seul appareil).
  Future<void> _copy() async {
    final text = await DiagnosticBundle.build(
      video: true,
      device: true,
      rules: false,
      appLog: false,
      cameraLog: false,
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Mesures copiées')));
  }

  @override
  Widget build(BuildContext context) {
    final records = VideoOpenTrace.records;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lecture vidéo — temps d\'ouverture'),
        actions: [
          IconButton(
            tooltip: 'Copier les mesures',
            icon: const Icon(Icons.copy_all),
            onPressed: records.isEmpty ? null : _copy,
          ),
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
                // Trois seaux, pas deux : « partiel » est précisément la
                // population qui rendait la mesure du 2026-08-13 illisible —
                // des vidéos vues quelques secondes, comptées comme étant en
                // cache alors que leurs blocs restaient à télécharger.
                for (final availability in MediaAvailability.values) ...[
                  _Summary(
                    availability: availability,
                    records: records
                        .where((r) => r.availability == availability)
                        .toList(),
                  ),
                  const SizedBox(height: 8),
                ],
                const Divider(height: 24),
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
Duration? _median(List<Duration> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

int? _medianInt(List<int> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

/// Les libellés de détail rencontrés, dans l'ordre où ils ont été consignés.
///
/// Ils ne sont pas connus d'avance : le détail dépend du chemin suivi (un
/// contenu à moi n'appelle pas le serveur pour sa clé), et une mesure absente
/// vaut mieux qu'une ligne à zéro qui laisserait croire qu'un travail a eu lieu.
List<String> _detailLabels(List<VideoOpenTrace> records) {
  final labels = <String>{};
  for (final record in records) {
    labels.addAll(record.detail.keys);
  }
  return labels.toList();
}

class _Summary extends StatelessWidget {
  const _Summary({required this.availability, required this.records});

  final MediaAvailability availability;
  final List<VideoOpenTrace> records;

  /// Les cibles fixées par Jay le 2026-08-12.
  ///
  /// [MediaAvailability.partiel] n'en a pas, volontairement : ce seau ne
  /// correspond à **aucune promesse**. Il dit qu'une lecture a dû compléter son
  /// cache en cours de route — ni le cas préchargé, ni un vrai démarrage à
  /// froid. Lui donner une cible reviendrait à recréer le mélange qu'il sert
  /// justement à défaire.
  Duration? get _target => switch (availability) {
    MediaAvailability.complet => const Duration(milliseconds: 300),
    // Le seau qui juge le préchargement : tout ce qui coûte cher — clé, URL,
    // premier bloc — y a déjà été fait d'avance. Il doit donc tenir la même
    // cible qu'un contenu entièrement présent.
    MediaAvailability.amorce => const Duration(milliseconds: 300),
    MediaAvailability.partiel => null,
    MediaAvailability.froid => const Duration(seconds: 1),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // `perceived` et non `total` : pour une face préchargée, l'attente ne
    // commence qu'à l'affichage. Confondre les deux, c'est chronométrer le
    // temps que l'utilisateur passe à regarder autre chose.
    final totals = records
        .map((r) => r.perceived)
        .whereType<Duration>()
        .toList();
    final median = _median(totals);
    final target = _target;
    final ok = median != null && target != null && median <= target;
    final sorted = [...totals]..sort();

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  median == null
                      ? Icons.remove
                      : target == null
                      ? Icons.info_outline
                      : ok
                      ? Icons.check_circle
                      : Icons.error_outline,
                  color: median == null || target == null
                      ? null
                      : ok
                      ? Colors.green
                      : Colors.orange,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    availability.label,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  median == null ? '—' : '${median.inMilliseconds} ms',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              median == null
                  ? 'aucune mesure'
                  : 'sur ${totals.length}'
                        '${target == null ? ' — pas de cible' : ' — cible ${target.inMilliseconds} ms'}'
                        ' · meilleure ${sorted.first.inMilliseconds} ms'
                        ' · pire ${sorted.last.inMilliseconds} ms',
              style: theme.textTheme.bodySmall,
            ),
            // La médiane par ÉTAPE est ce qui décide du chantier suivant : elle
            // dit qui retarde la première image. Le total seul ne dit que
            // qu'elle est en retard.
            if (median != null) ...[
              const SizedBox(height: 8),
              for (final step in VideoOpenStep.values.skip(1))
                if (_median(
                      records
                          .map((r) => r.spentOn(step))
                          .whereType<Duration>()
                          .toList(),
                    )
                    case final spent?)
                  Text(
                    '${step.label} : ${spent.inMilliseconds} ms',
                    style: theme.textTheme.bodySmall,
                  ),
              // Les coûts qui ne tiennent pas sur la frise : les deux travaux
              // menés en parallèle, et le détail interne du natif. Les lire
              // comme des étapes successives serait un contresens — ils se
              // recouvrent.
              if (_detailLabels(records) case final labels
                  when labels.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'détail (parallèle — ne s\'additionne pas)',
                  style: theme.textTheme.labelSmall,
                ),
                for (final label in labels)
                  if (_medianInt(
                        records
                            .map((r) => r.detail[label])
                            .whereType<int>()
                            .toList(),
                      )
                      case final ms?)
                    Text('$label : $ms ms', style: theme.textTheme.bodySmall),
              ],
            ],
          ],
        ),
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
              Icon(switch (record.availability) {
                MediaAvailability.complet => Icons.sd_storage,
                MediaAvailability.amorce => Icons.rocket_launch,
                MediaAvailability.partiel => Icons.downloading,
                MediaAvailability.froid => Icons.cloud_download,
              }, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  record.id,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (record.prefetched)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.bolt, size: 14, color: Colors.amber),
                ),
              Text(
                record.perceived == null
                    ? '—'
                    : '${record.perceived!.inMilliseconds} ms',
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
          // Une face préchargée : dire ce que le total brut recouvre, sinon
          // l'écart entre les deux nombres passe pour une incohérence.
          if (record.prefetched && record.total != null)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                'préchargée — ouverte ${record.total!.inMilliseconds} ms avant '
                'la première image, dont ${record.displayedAt?.inMilliseconds ?? 0} ms '
                'hors attente',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          // Sans « + » : ces coûts se recouvrent, ils ne s'ajoutent pas aux
          // précédents.
          for (final entry in record.detail.entries)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 2),
              child: Text(
                '${entry.key} : ${entry.value} ms',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
