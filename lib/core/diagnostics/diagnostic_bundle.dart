import 'dart:ui' show ImageFilter;

import 'package:flutter/services.dart';

import '../video/video_open_trace.dart';
import '../../features/cards/glass_controls.dart';
import '../../features/cards/native_camera.dart';
import 'app_log.dart';
import 'card_rules_trace.dart';
import 'frame_cost_trace.dart';

/// Tout ce qu'il faut pour diagnostiquer, en **un seul** copier-coller.
///
/// ### Pourquoi ça existe
///
/// Les traces vivent à quatre endroits — journal de l'app, journal caméra,
/// mesures d'ouverture vidéo, et l'appareil lui-même. Les relever un par un
/// demande quatre écrans, quatre boutons et autant d'occasions d'en oublier un
/// ou de coller le mauvais. Demande de Jay le 2026-08-13 : « un bouton
/// permettant de copier simultanément tous les logs et données de toutes les
/// parties, de sorte à ce que je te les renvoie ».
///
/// Chaque section est délimitée par un titre en clair : le résultat doit se
/// lire tel quel, sans être remis en forme.
///
/// ⚠️ **Outil de développement** — à retirer avec la section Développeur avant
/// la prod (voir `RAPPELS.md`).
class DiagnosticBundle {
  const DiagnosticBundle._();

  static const _channel = MethodChannel('neovibe/diag');

  /// L'appareil et la version installée.
  ///
  /// La version vient du **paquet Android**, pas d'une constante Dart : une
  /// version recopiée à la main finit toujours par mentir, et un mauvais
  /// numéro dans un rapport fait chercher le bug dans la mauvaise version.
  static Future<Map<String, String>> deviceInfo() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'deviceInfo',
      );
      return {
        for (final entry in (info ?? {}).entries) entry.key: '${entry.value}',
      };
    } catch (_) {
      // Un diagnostic qui échoue ne doit jamais empêcher de copier le reste.
      return const {};
    }
  }

  /// Les mesures d'ouverture vidéo, mises en forme.
  ///
  /// Le détail par étape est conservé : c'est lui qui dit **qui** a retardé la
  /// première image — un total seul ne permet aucune décision.
  static String videoTimings() {
    final records = VideoOpenTrace.records;
    if (records.isEmpty) return 'Aucune mesure.';

    final buffer = StringBuffer();
    for (final availability in MediaAvailability.values) {
      final group = records.where((r) => r.availability == availability);
      // `perceived` : pour une face préchargée, l'attente ne commence qu'à
      // l'affichage (voir [VideoOpenTrace.prefetched]).
      final totals =
          group.map((r) => r.perceived).whereType<Duration>().toList()..sort();
      if (totals.isEmpty) {
        buffer.writeln('${availability.label} : aucune mesure');
        continue;
      }
      final median = totals[totals.length ~/ 2];
      buffer
        ..writeln(
          '${availability.label} : médiane ${median.inMilliseconds} ms '
          'sur ${totals.length} — meilleure ${totals.first.inMilliseconds} ms, '
          'pire ${totals.last.inMilliseconds} ms',
        )
        ..writeln(_stepLines(group.toList()));
    }

    buffer.writeln('\n--- ouvertures, la plus récente d\'abord ---');
    for (final record in records) {
      buffer.writeln(
        '[${record.availability.name}]'
        '${record.prefetched ? '[préchargée]' : ''} ${record.id} : '
        '${record.perceived?.inMilliseconds ?? '—'} ms'
        '${record.prefetched ? ' (ouverte ${record.total?.inMilliseconds} ms avant)' : ''}',
      );
      for (final step in VideoOpenStep.values.skip(1)) {
        final spent = record.spentOn(step);
        if (spent != null) {
          buffer.writeln('    ${step.label} : +${spent.inMilliseconds} ms');
        }
      }
      for (final entry in record.detail.entries) {
        buffer.writeln('        ${entry.key} : ${entry.value} ms');
      }
    }
    return buffer.toString().trimRight();
  }

  static String _stepLines(List<VideoOpenTrace> group) {
    final buffer = StringBuffer();
    for (final step in VideoOpenStep.values.skip(1)) {
      final values = group
          .map((r) => r.spentOn(step))
          .whereType<Duration>()
          .map((d) => d.inMilliseconds)
          .toList();
      if (values.isEmpty) continue;
      values.sort();
      buffer.writeln('    ${step.label} : ${values[values.length ~/ 2]} ms');
    }
    // Les coûts parallèles, à part : les additionner n'aurait aucun sens.
    final labels = <String>{for (final r in group) ...r.detail.keys};
    for (final label in labels) {
      final values = group
          .map((r) => r.detail[label])
          .whereType<int>()
          .toList();
      if (values.isEmpty) continue;
      values.sort();
      buffer.writeln('        $label : ${values[values.length ~/ 2]} ms');
    }
    return buffer.toString().trimRight();
  }

  /// Le paquet complet, prêt à coller.
  ///
  /// [sections] permet d'en produire une partie seulement — l'écran des temps
  /// d'ouverture copie ses seules mesures.
  static Future<String> build({
    bool device = true,
    bool video = true,
    bool rules = true,
    bool appLog = true,
    bool cameraLog = true,
    bool frameCost = true,
  }) async {
    final buffer = StringBuffer()
      ..writeln('===== DIAGNOSTIC NEOVIBE =====')
      ..writeln('relevé le ${DateTime.now().toIso8601String()}');

    if (device) {
      final info = await deviceInfo();
      buffer.writeln(
        'app ${info['appVersion'] ?? '?'}+${info['appBuild'] ?? '?'} · '
        '${info['model'] ?? '?'} · Android ${info['android'] ?? '?'}',
      );
    }

    if (video) {
      buffer
        ..writeln('\n===== LECTURE VIDÉO — TEMPS D\'OUVERTURE =====')
        ..writeln(videoTimings());
    }

    if (frameCost) {
      buffer
        ..writeln('\n===== COÛT D\'AFFICHAGE — ÉCRAN DE CAPTURE =====')
        // Sans cette ligne, « le liquid glass ne fait rien » et « le shader
        // n'a jamais été chargé » sont indiscernables dans un rapport de test.
        ..writeln('shader liquid glass : ${LiquidGlassProgram.status}')
        ..writeln(
          'ImageFilter.shader supporté : '
          '${ImageFilter.isShaderFilterSupported}',
        )
        ..writeln(FrameCostTrace.report());
    }

    if (rules) {
      buffer.writeln('\n===== RÈGLES DES VIBES =====');
      final records = CardRulesTrace.records;
      buffer.writeln(
        records.isEmpty
            ? 'Aucune ouverture.'
            : records.map((r) => r.describe()).join('\n'),
      );
    }

    if (cameraLog) {
      buffer.writeln('\n===== JOURNAL CAMÉRA =====');
      try {
        final log = await NativeCameraController.readLog();
        buffer.writeln(log.trim().isEmpty ? '(vide)' : log.trim());
      } catch (e) {
        buffer.writeln('(illisible : $e)');
      }
    }

    if (appLog) {
      buffer.writeln('\n===== JOURNAL DE L\'APP =====');
      try {
        final log = await AppLog.instance.readAll();
        buffer.writeln(log.trim().isEmpty ? '(vide)' : log.trim());
      } catch (e) {
        buffer.writeln('(illisible : $e)');
      }
    }

    return buffer.toString();
  }
}
