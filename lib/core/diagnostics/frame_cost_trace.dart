import 'package:flutter/scheduler.dart';

/// Coût d'affichage relevé **image par image**, pour trancher une question de
/// rendu par la mesure au lieu de l'impression.
///
/// ### Pourquoi ça existe
///
/// Le verre dépoli de l'écran de capture (`glass_controls.dart`) repose sur un
/// `BackdropFilter`, qui force un `saveLayer` et relit le tampon d'affichage à
/// chaque image — par-dessus un aperçu caméra déjà vivant. Personne ne peut
/// savoir d'avance si l'appareil de Jay tient la cadence : ça se mesure, sur
/// son téléphone, dans la vraie scène.
///
/// ### Ce que cet instrument peut, et ce qu'il ne peut pas
///
/// Il mesure le temps que **Flutter** passe à construire puis à rastériser
/// chaque image. C'est le bon instrument ici, et pour une raison précise :
/// l'aperçu caméra est un `Texture` — une texture externe composée **dans** la
/// scène Flutter. Le coût du flou qui la recouvre tombe donc bien dans
/// `rasterDuration`. (Si l'aperçu était une `PlatformView`, il serait composé
/// par le système sur une couche séparée : le flou n'aurait aucun effet et
/// cette mesure ne verrait rien. Vérifié le 2026-08-14 —
/// `native_camera.dart:511` utilise bien `Texture`.)
///
/// Ce qu'il ne dit **pas** : la cadence de la caméra elle-même. Si le capteur
/// tombe à 20 i/s pour une raison qui lui est propre, ces chiffres resteront
/// bons. Ils répondent à « est-ce que NOTRE rendu tient ? », pas à « est-ce que
/// l'aperçu est fluide ? ».
///
/// ### Comment lire le résultat
///
/// **Le nombre qui décide est le pourcentage d'images hors budget**, pas la
/// médiane. Une médiane excellente avec 15 % d'images à 40 ms donne un aperçu
/// qui saccade visiblement ; c'est la queue de distribution qui se voit à
/// l'œil, pas le centre. Les deux sont donc rapportés, avec le pire cas.
///
/// ⚠️ **Outil de développement** — à retirer avec la section Développeur avant
/// la prod (voir `RAPPELS.md`).
class FrameCostTrace {
  FrameCostTrace._();

  /// Budget d'une image à 60 Hz. Les appareils à 90 ou 120 Hz ont un budget
  /// PLUS COURT : le pourcentage rapporté est donc un minorant du problème,
  /// jamais un majorant. On préfère cette erreur-là.
  static const budgetMicros = 16667;

  /// Images ignorées après chaque `start` : la première image d'un écran paie
  /// la compilation des shaders et le premier remplissage des caches. La
  /// compter reviendrait à imputer au verre un coût qui n'est pas le sien.
  static const _warmupFrames = 12;

  static final Map<String, List<int>> _raster = {};
  static final Map<String, List<int>> _build = {};

  static String? _label;
  static int _skipped = 0;
  static bool _installed = false;

  /// Plafond par échantillon : une session de capture longue ne doit pas faire
  /// grossir la mémoire indéfiniment. On garde les 3000 dernières images
  /// (≈ 50 s à 60 i/s), largement assez pour une distribution.
  static const _maxSamples = 3000;

  /// Y a-t-il au moins une mesure ?
  static bool get hasSamples => _raster.values.any((l) => l.isNotEmpty);

  /// Commence à relever sous [label]. Les relevés d'un même label
  /// s'accumulent : Jay peut faire plusieurs passages sans tout perdre.
  static void start(String label) {
    _install();
    _label = label;
    _skipped = 0;
    _raster.putIfAbsent(label, () => <int>[]);
    _build.putIfAbsent(label, () => <int>[]);
  }

  static void stop() => _label = null;

  static void clear() {
    _raster.clear();
    _build.clear();
    _label = null;
  }

  static void _install() {
    if (_installed) return;
    _installed = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  static void _onTimings(List<FrameTiming> timings) {
    final label = _label;
    if (label == null) return;
    final raster = _raster[label]!;
    final build = _build[label]!;
    for (final timing in timings) {
      if (_skipped < _warmupFrames) {
        _skipped++;
        continue;
      }
      raster.add(timing.rasterDuration.inMicroseconds);
      build.add(timing.buildDuration.inMicroseconds);
      if (raster.length > _maxSamples) {
        raster.removeAt(0);
        build.removeAt(0);
      }
    }
  }

  /// Le relevé mis en forme, prêt à coller dans le diagnostic.
  static String report() {
    if (!hasSamples) return 'Aucune mesure.';
    final buffer = StringBuffer()
      ..writeln('budget d\'une image à 60 Hz : 16,7 ms')
      ..writeln('le chiffre qui décide est « hors budget », pas la médiane\n');
    for (final label in _raster.keys) {
      final raster = _raster[label]!;
      if (raster.isEmpty) {
        buffer.writeln('$label : aucune mesure');
        continue;
      }
      buffer
        ..writeln('--- $label — ${raster.length} images ---')
        ..writeln('  rastérisation : ${_describe(raster)}')
        ..writeln('  construction  : ${_describe(_build[label]!)}')
        ..writeln('  hors budget   : ${_overBudget(raster)}');
    }
    return buffer.toString().trimRight();
  }

  static String _describe(List<int> values) {
    if (values.isEmpty) return '—';
    final sorted = [...values]..sort();
    String ms(int micros) => (micros / 1000).toStringAsFixed(1);
    return 'médiane ${ms(sorted[sorted.length ~/ 2])} ms · '
        'p90 ${ms(sorted[(sorted.length * 9 / 10).floor().clamp(0, sorted.length - 1)])} ms · '
        'pire ${ms(sorted.last)} ms';
  }

  static String _overBudget(List<int> values) {
    if (values.isEmpty) return '—';
    final over = values.where((v) => v > budgetMicros).length;
    final doubled = values.where((v) => v > budgetMicros * 2).length;
    final pct = (over * 100 / values.length).toStringAsFixed(1);
    final pctDoubled = (doubled * 100 / values.length).toStringAsFixed(1);
    return '$over/${values.length} ($pct %) au-dessus de 16,7 ms · '
        '$pctDoubled % au-dessus de 33 ms';
  }
}
