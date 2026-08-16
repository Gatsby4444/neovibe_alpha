import 'dart:math' as math;

/// Ce qu'on peut honnêtement dire de la distance entre deux appareils.
///
/// # Pourquoi ce fichier n'affiche pas de mètres
///
/// Demande de Jay, 2026-08-16 : *« une fonctionnalité qui permet de détecter la
/// distance en temps réel entre deux utilisateurs, à la place de l'indicateur
/// proche / très proche »*.
///
/// La conversion existe, et elle est simple — c'est le **modèle de perte en
/// espace libre** :
///
/// ```
/// distance = 10 ^ ((puissance_émise − puissance_reçue) / (10 × n))
/// ```
///
/// Le problème n'est pas la formule. Il est dans ce qu'on y injecte.
///
/// ## Les trois inconnues, et laquelle on vient de supprimer
///
/// 1. **La puissance émise.** Elle varie de plusieurs dB d'un appareil à
///    l'autre. ✅ **Supprimée le 2026-08-16** : l'annonce la transporte
///    désormais ([RadioScan.txPower]).
/// 2. **L'exposant `n`.** Il vaut 2 en espace libre, 2,7 à 4 en intérieur, et
///    on ne peut pas le connaître : il dépend de la pièce, des murs, du
///    mobilier. On prend [pathLossExponent], et on assume que c'est une
///    hypothèse.
/// 3. **Le bruit.** Un corps humain entre les deux appareils absorbe **10 à
///    20 dB**. Un téléphone dans une poche, une main sur l'antenne, une
///    réflexion sur un mur : autant de dizaines de dB.
///
/// ## Ce que ce bruit fait à un affichage en mètres
///
/// Avec `n = 2,5`, une erreur de RSSI de `x` dB multiplie ou divise la distance
/// par `10^(x/25)` :
///
/// | Erreur de RSSI | Facteur sur la distance | « 3 m » devient réellement |
/// |---|---|---|
/// | 6 dB (bruit ordinaire) | ×1,7 | 1,8 m à 5,2 m |
/// | 15 dB (un corps) | ×4,0 | 0,75 m à 12 m |
///
/// **Afficher « 3,2 m » serait donc fabriquer une précision qui n'existe pas.**
/// C'est exactement ce que la spec 4.2 interdit — *« seuil RSSI grossier,
/// jamais de distance précise »* — et pour deux raisons qui se renforcent :
/// c'est faux, et une distance au mètre près transforme une app de rencontre
/// en outil de traque. *« Il est à 2 m derrière toi »* n'est pas une
/// fonctionnalité sociale.
///
/// ## Ce qu'on rend à la place, et qui est vrai
///
/// - **Quatre bandes** au lieu de deux, avec hystérésis sur chaque frontière ;
/// - **une tendance** — se rapproche, s'éloigne, stable — qui est **beaucoup
///   plus robuste que la distance absolue**, parce que les erreurs
///   systématiques (puissance, exposant, obstacle fixe) **s'annulent dans la
///   dérivée**. Un corps qui bloque décale le niveau ; il ne change pas le
///   signe de la pente ;
/// - **une fourchette** en mètres — jamais un nombre unique — réservée à
///   l'écran de diagnostic, pour que Jay juge sur pièce.
enum ProximityBand {
  /// À portée de bras. On se voit, on se parle.
  contact,

  /// Quelques pas. Même table, même file d'attente.
  close,

  /// Même pièce, ou de l'autre côté du couloir.
  room,

  /// Détecté, mais loin. Le signal passe encore, c'est tout.
  far;

  String get label => switch (this) {
    contact => 'À portée de bras',
    close => 'Tout près',
    room => 'Dans le coin',
    far => 'Plus loin',
  };
}

enum ProximityTrend {
  approaching,
  stable,
  leaving;

  String get label => switch (this) {
    approaching => 'se rapproche',
    stable => '',
    leaving => 's\'éloigne',
  };
}

/// L'estimation complète, telle qu'on la garde pour un pair.
class DistanceEstimate {
  const DistanceEstimate({
    required this.band,
    required this.trend,
    required this.smoothedRssi,
    required this.minMeters,
    required this.maxMeters,
    required this.calibrated,
  });

  final ProximityBand band;
  final ProximityTrend trend;
  final double smoothedRssi;

  /// La fourchette plausible, en mètres. **Jamais réduite à un seul nombre.**
  ///
  /// L'écart entre les deux bornes est l'information la plus honnête de tout
  /// ce fichier : c'est lui qui dit à quel point la valeur centrale ne veut
  /// rien dire.
  final double minMeters;
  final double maxMeters;

  /// Vrai si le pair a annoncé sa puissance d'émission. Sinon la fourchette
  /// est encore plus large, et il faut le dire.
  final bool calibrated;

  /// L'estimation centrale, en mètres.
  ///
  /// ⚠️ **À ne jamais montrer seule.** Elle n'existe que pour être comparée à
  /// une distance réelle pendant les relevés : c'est le seul usage où un
  /// nombre unique est légitime, parce qu'on connaît la vérité à côté. Dès
  /// qu'on la montre sans sa fourchette, on prétend une précision qui n'existe
  /// pas — voir le tableau en tête de fichier.
  double get meters => math.sqrt(minMeters * maxMeters);

  /// Le nombre à comparer avec le mètre ruban, pendant les relevés.
  String get metersLabel => meters < 10
      ? '${meters.toStringAsFixed(1)} m'
      : '${meters.toStringAsFixed(0)} m';

  String get range => maxMeters >= 30
      ? 'plus de ${minMeters.toStringAsFixed(0)} m'
      : '${minMeters.toStringAsFixed(minMeters < 10 ? 1 : 0)} à '
            '${maxMeters.toStringAsFixed(maxMeters < 10 ? 1 : 0)} m';
}

/// Le calcul, isolé pour être testable sans radio ni appareil.
class DistanceModel {
  const DistanceModel._();

  /// Exposant de perte. 2 en espace libre, 2,7 à 4 en intérieur.
  ///
  /// 2,5 est un compromis entre les deux — et c'est **une hypothèse**, pas une
  /// mesure. Le relevé B (`docs/protocole-releves-proximite.md`) est fait pour
  /// le calibrer sur les vrais appareils, intérieur et extérieur.
  static const pathLossExponent = 2.5;

  /// Puissance supposée quand le pair ne l'annonce pas.
  ///
  /// `ADVERTISE_TX_POWER_MEDIUM` correspond à peu près à −7 dBm mesuré à 1 m
  /// sur la plupart des appareils. Une supposition, et elle est signalée comme
  /// telle par [DistanceEstimate.calibrated].
  static const assumedTxPower = -7;

  /// Incertitude retenue pour la fourchette, en dB.
  ///
  /// 6 dB en temps normal ; **15 dB** dès qu'on ne peut pas exclure un corps
  /// entre les deux — c'est-à-dire toujours, dans la vraie vie. On prend donc
  /// le cas défavorable : une fourchette trop large est honnête, une
  /// fourchette trop étroite est un mensonge.
  static const uncertaintyDb = 15.0;

  /// Seuils d'entrée dans chaque bande, en dBm de RSSI lissé.
  ///
  /// Calibrés sur les valeurs usuelles, **à revoir après le relevé B**.
  static const enterContact = -55;
  static const enterClose = -70;
  static const enterRoom = -85;

  /// Marge d'hystérésis : il faut redescendre de tant pour quitter une bande.
  ///
  /// ⚠️ Sans elle, un appareil posé pile sur un seuil bascule à chaque mesure.
  /// C'est ce qui sépare une information d'un scintillement.
  static const hysteresisDb = 6;

  static double metersFor(double rssi, int txPower) {
    final ratio = (txPower - rssi) / (10 * pathLossExponent);
    return math.pow(10, ratio).toDouble();
  }

  /// La bande, en tenant compte de celle où l'on se trouve déjà.
  static ProximityBand bandFor(double rssi, ProximityBand? current) {
    // Pour MONTER d'une bande il faut franchir le seuil ; pour en DESCENDRE il
    // faut le franchir de [hysteresisDb] de plus.
    double seuil(int base, ProximityBand cible) =>
        (current != null && current.index <= cible.index)
        ? base - hysteresisDb.toDouble()
        : base.toDouble();

    if (rssi >= seuil(enterContact, ProximityBand.contact)) {
      return ProximityBand.contact;
    }
    if (rssi >= seuil(enterClose, ProximityBand.close)) {
      return ProximityBand.close;
    }
    if (rssi >= seuil(enterRoom, ProximityBand.room)) return ProximityBand.room;
    return ProximityBand.far;
  }

  /// Au-delà de cette pente, en dB par seconde, le mouvement est réel.
  ///
  /// En dessous, c'est du bruit : un appareil immobile dérive facilement de
  /// 1 dB/s sans que personne n'ait bougé.
  static const trendThresholdDbPerSecond = 1.5;

  /// La tendance, à partir de deux mesures lissées espacées dans le temps.
  ///
  /// ⚠️ **Bien plus robuste que la distance absolue.** La puissance d'émission,
  /// l'exposant de perte et un obstacle fixe décalent tous le NIVEAU ; aucun
  /// des trois ne change le SIGNE de la pente. C'est pourquoi on peut dire
  /// « il se rapproche » avec confiance là où « il est à 3 m » serait faux.
  static ProximityTrend trendFor(
    double previousRssi,
    double currentRssi,
    Duration elapsed,
  ) {
    final seconds = elapsed.inMilliseconds / 1000;
    if (seconds <= 0) return ProximityTrend.stable;
    final slope = (currentRssi - previousRssi) / seconds;
    if (slope >= trendThresholdDbPerSecond) return ProximityTrend.approaching;
    if (slope <= -trendThresholdDbPerSecond) return ProximityTrend.leaving;
    return ProximityTrend.stable;
  }

  /// L'estimation complète.
  static DistanceEstimate estimate({
    required double smoothedRssi,
    required int txPower,
    required ProximityBand? currentBand,
    required ProximityTrend trend,
  }) {
    final calibrated = txPower != 127;
    final tx = calibrated ? txPower : assumedTxPower;
    // La fourchette vient de l'incertitude EN dB, convertie en distance : c'est
    // la seule façon honnête de la présenter, parce que l'erreur est
    // multiplicative, jamais additive.
    final near = metersFor(smoothedRssi + uncertaintyDb, tx);
    final far = metersFor(smoothedRssi - uncertaintyDb, tx);
    return DistanceEstimate(
      band: bandFor(smoothedRssi, currentBand),
      trend: trend,
      smoothedRssi: smoothedRssi,
      minMeters: near,
      maxMeters: far,
      calibrated: calibrated,
    );
  }
}
