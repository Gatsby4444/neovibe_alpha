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

/// **Le flux de la boussole, UN SEUL pour toute l'app.**
///
/// 🔴 **Pourquoi un seul, et créé une fois** — 2026-09-26, vérifié dans la
/// source de Flutter (`platform_channel.dart`, `receiveBroadcastStream`) :
/// chaque flux ouvert sur un canal INSTALLE le récepteur du canal à son
/// ouverture, et le RETIRE à sa fermeture. Deux flux sur le même canal se
/// marchent dessus : si l'ancien se ferme après que le nouveau s'est ouvert
/// (écran refermé puis rouvert vite, fournisseur recréé), sa fermeture retire
/// le récepteur du nouveau — la flèche se fige, sans aucune erreur.
///
/// Un flux unique, partagé : ouvert au premier auditeur, fermé au dernier,
/// jamais doublé. Reproduit : `test/heading_source_test.dart`.
final Stream<HeadingReading> headingStream =
    const EventChannel('neovibe/heading/events').receiveBroadcastStream().map((
      e,
    ) {
      final m = Map<String, Object?>.from(e as Map);
      if (m['absent'] == true) return const HeadingReading.absent();
      return HeadingReading(
        degrees: (m['deg'] as num).toDouble(),
        reliability: (m['fiabilite'] as num).toInt(),
      );
    });

/// **La boussole** (2026-09-25), pour la flèche de mon point sur la carte.
///
/// La **cuisine** : chaque mesure du capteur, telle quelle, une quinzaine de
/// fois par seconde (`HeadingSensor.kt`). Rien n'est lissé ici — adoucir la
/// flèche est une décision d'affichage, prise par qui la dessine.
///
/// Le capteur n'écoute que tant que quelqu'un écoute ce flux : fermé avec
/// la carte, il ne coûte plus rien (`autoDispose`).
final headingProvider = StreamProvider.autoDispose<HeadingReading>(
  (ref) => headingStream,
);
