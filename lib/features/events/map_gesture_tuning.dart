import 'package:flutter/services.dart';

import '../../core/diagnostics/app_log.dart';

/// **Régler les gestes dans le moteur de la carte** (2026-09-26) — le côté
/// Dart de `MapGestureTuner.kt`. Voir ce fichier pour le pourquoi : les
/// gestes restent à Mapbox, qui lit les doigts sans détour ; on n'y change
/// que les seuils écrits en dur dans son code.
abstract final class MapGestureTuning {
  static const _canal = MethodChannel('neovibe/map_gestures');

  /// L'angle avant qu'une rotation parte (Mapbox : 3°).
  static const rotateDeg = 10.0;

  /// Jusqu'où les doigts peuvent être de travers pour incliner (Mapbox : 45°).
  static const shoveMaxDeg = 60.0;

  /// Inclinaison deux fois plus vive que chez Mapbox : ~1,5 cm de course
  /// pour 60° (Jay : « 3 cm, c'est trop »).
  static const pitchBoost = 2.0;

  /// Règle les cartes à l'écran pas encore réglées. Rend combien ont été
  /// trouvées et réglées, écrit au journal — un zéro se voit, il ne se
  /// devine pas (mode « écran virtuel » : carte introuvable, seuils de
  /// Mapbox d'origine).
  static Future<({int trouvees, int reglees})> tune() async {
    try {
      final r = await _canal.invokeMapMethod<String, int>('tune', {
        'rotateDeg': rotateDeg,
        'shoveMaxDeg': shoveMaxDeg,
        'pitchBoost': pitchBoost,
      });
      final res = (trouvees: r?['trouvees'] ?? 0, reglees: r?['reglees'] ?? 0);
      AppLog.instance.app(
        'Carte',
        'gestes réglés : ${res.reglees} (cartes trouvées : ${res.trouvees})',
      );
      return res;
    } catch (e) {
      AppLog.instance.error('Carte', 'réglage des gestes impossible : $e');
      return (trouvees: 0, reglees: 0);
    }
  }
}
