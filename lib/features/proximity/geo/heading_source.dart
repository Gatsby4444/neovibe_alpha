import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **Une mesure de la boussole** : vers où pointe le haut du téléphone.
class HeadingReading {
  const HeadingReading({required this.degrees, required this.reliability});

  /// L'appareil n'a pas le capteur : pas de flèche, et on le sait.
  const HeadingReading.absent() : degrees = null, reliability = 0;

  /// Angle par rapport au nord, 0..360, dans le sens des aiguilles ; nul si
  /// l'appareil n'a pas de boussole.
  final double? degrees;

  /// Ce que le téléphone dit de sa fiabilité : 0 = inutilisable (à
  /// recalibrer en faisant des « 8 »), 3 = haute. Niveaux d'Android.
  final int reliability;

  bool get absent => degrees == null;

  @override
  bool operator ==(Object other) =>
      other is HeadingReading &&
      other.degrees == degrees &&
      other.reliability == reliability;

  @override
  int get hashCode => Object.hash(degrees, reliability);
}

/// **La boussole** (2026-09-25), pour la flèche de mon point sur la carte.
///
/// La **cuisine** : chaque mesure du capteur, telle quelle, une quinzaine de
/// fois par seconde (`HeadingSensor.kt`). Rien n'est lissé ici — adoucir la
/// flèche est une décision d'affichage, prise par qui la dessine.
///
/// Le capteur n'écoute que tant que quelqu'un écoute ce flux : fermé avec
/// la carte, il ne coûte plus rien (`autoDispose`).
final headingProvider = StreamProvider.autoDispose<HeadingReading>((ref) {
  const channel = EventChannel('neovibe/heading/events');
  return channel.receiveBroadcastStream().map((e) {
    final m = Map<String, Object?>.from(e as Map);
    if (m['absent'] == true) return const HeadingReading.absent();
    return HeadingReading(
      degrees: (m['deg'] as num).toDouble(),
      reliability: (m['fiabilite'] as num).toInt(),
    );
  });
});
