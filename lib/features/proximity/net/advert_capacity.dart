/// Le résultat d'une mesure du plafond d'annonces simultanées.
///
/// Deux issues, et **elles ne se confondent pas** : ou bien la sonde a mesuré
/// ([AdvertCapacity]), ou bien elle n'a pas pu ([AdvertCapacityRefus]).
sealed class AdvertCapacityResult {
  const AdvertCapacityResult();
}

/// Ce que la puce a **accepté** quand on lui a demandé plusieurs annonces.
///
/// ## Pourquoi cet objet existe — 2026-09-01
///
/// Le mode « parallèle » donne à chaque ami son propre jeu d'annonces, en l'air
/// tout le temps. Au-delà d'un certain nombre, le contrôleur refuse, et l'app
/// retombe en mode « cycle » : chaque jeton n'est alors en l'air que 1/N du
/// temps, et quelqu'un croisé trois secondes peut n'être jamais vu.
///
/// Ce nombre était **supposé** (6) faute d'API pour le demander (`RAPPELS.md`
/// #113). [AdvertCapacityProbe] côté natif le mesure ; cette classe transporte
/// le constat, sans le juger.
///
/// ⚠️ **Des faits, pas un verdict.** [acceptes] est ce que la pile a accordé sur
/// [demandes] tentatives ; [plafondCourant] est ce que l'app s'autorise
/// aujourd'hui. Les rapprocher est une décision produit, pas une conversion.
class AdvertCapacity extends AdvertCapacityResult {
  const AdvertCapacity({
    required this.acceptes,
    required this.demandes,
    required this.plafondCourant,
    required this.plafondRetenu,
    required this.codeRefus,
    required this.expire,
    required this.extendedSupporte,
    required this.tailleMaxAnnonce,
    required this.appareil,
    required this.sdk,
  });

  /// Combien de jeux d'annonces le contrôleur a démarré **avec succès**.
  final int acceptes;

  /// Combien on lui en a demandé au maximum. [acceptes] == [demandes] veut dire
  /// que la sonde a atteint sa propre borne, pas celle de la puce.
  final int demandes;

  /// L'hypothèse de départ de l'app (`BleEngine.PLAFOND_DE_DEPART`), utilisée
  /// tant que cet appareil n'a rien appris.
  final int plafondCourant;

  /// Ce que **cet appareil** a retenu de sa puce, ou 0 s'il n'a rien appris.
  ///
  /// ⚠️ C'est lui qui compte à l'exécution : le moteur d'annonces lit cette
  /// valeur, et retombe sur [plafondCourant] seulement quand elle vaut 0.
  final int plafondRetenu;

  /// Le code du refus qui a arrêté la montée, s'il y en a eu un.
  /// `-1` = la pile a levé avant de répondre.
  final int? codeRefus;

  /// La pile n'a **pas répondu** dans le temps imparti. Ce n'est pas un refus :
  /// c'est une absence de réponse, et les deux ne se corrigent pas pareil.
  final bool expire;

  final bool extendedSupporte;
  final int tailleMaxAnnonce;
  final String appareil;
  final int sdk;

  /// La sonde a-t-elle touché la limite de la puce, ou la sienne ?
  bool get borneParLaSonde => acceptes >= demandes;

  static AdvertCapacityResult fromMap(Map<Object?, Object?> raw) {
    if (raw['ok'] != true) {
      return AdvertCapacityRefus(raw['raison'] as String? ?? 'raison inconnue');
    }
    int lire(String cle) => (raw[cle] as num?)?.toInt() ?? 0;
    return AdvertCapacity(
      acceptes: lire('acceptes'),
      demandes: lire('demandes'),
      plafondCourant: lire('plafondCourant'),
      plafondRetenu: lire('plafondRetenu'),
      codeRefus: (raw['codeRefus'] as num?)?.toInt(),
      expire: raw['expire'] == true,
      extendedSupporte: raw['extendedSupporte'] == true,
      tailleMaxAnnonce: lire('tailleMaxAnnonce'),
      appareil: raw['appareil'] as String? ?? '',
      sdk: lire('sdk'),
    );
  }

  // ⚠️ **Égalité de valeur obligatoire** : sans elle, tout affichage dérivé se
  // reconstruirait à chaque mesure identique (règle du 2026-08-25).
  @override
  bool operator ==(Object other) =>
      other is AdvertCapacity &&
      other.acceptes == acceptes &&
      other.demandes == demandes &&
      other.plafondCourant == plafondCourant &&
      other.plafondRetenu == plafondRetenu &&
      other.codeRefus == codeRefus &&
      other.expire == expire &&
      other.extendedSupporte == extendedSupporte &&
      other.tailleMaxAnnonce == tailleMaxAnnonce &&
      other.appareil == appareil &&
      other.sdk == sdk;

  @override
  int get hashCode => Object.hash(
    acceptes,
    demandes,
    plafondCourant,
    plafondRetenu,
    codeRefus,
    expire,
    extendedSupporte,
    tailleMaxAnnonce,
    appareil,
    sdk,
  );
}

/// La sonde n'a pas pu mesurer, et elle dit **pourquoi**.
///
/// ⚠️ Un refus n'est pas un zéro. Rendre `acceptes: 0` quand le Bluetooth est
/// éteint ferait lire « cette puce ne tient aucun jeu » — un zéro imposé par la
/// forme de l'instrument, pas mesuré.
class AdvertCapacityRefus extends AdvertCapacityResult {
  const AdvertCapacityRefus(this.raison);
  final String raison;
}
