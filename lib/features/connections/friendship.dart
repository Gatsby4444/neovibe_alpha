import 'package:flutter/material.dart';

import '../../core/palette.dart';

/// Le palier d'amitié — décision de Jay du 2026-08-29.
///
/// ## Ce qu'il est, et ce qu'il n'est pas
///
/// ⚠️ **Il n'y a AUCUNE règle dans ce fichier.** Les seuils, la fenêtre de
/// comptage et la façon dont on monte ou descend vivent en base, dans une seule
/// fonction SQL. Ici on ne sait que **lire** un palier déjà décidé, et lui
/// donner un nom et une couleur.
///
/// C'est volontaire : le jour où Jay changera « 5 jours » en « 7 jours », il y
/// aura **un** endroit à toucher. Recopier le seuil ici pour afficher « encore
/// 3 jours » aurait fait deux définitions de la même règle — et celle de
/// l'écran aurait menti sans lever d'erreur.
///
/// ## ⚠️ Ce n'est pas non plus « comment on est lié »
///
/// Jay décrit deux échelles, et elles ne se mélangent pas :
///
/// | | comment on est lié | à quel point on est proche |
/// |---|---|---|
/// | exemples | inconnu → croisé → même soirée → ami | ami → proche → inséparable |
/// | nature | **un fait** vérifiable | **une intensité** qui se gagne |
/// | durée | temporaire (24 h, 7 jours…) | durable, mais réversible |
///
/// La première vit déjà ailleurs (`encounters`, `recommendations`). Celle-ci
/// est la seconde, et elle ne concerne QUE des gens déjà amis.
enum FriendshipTier {
  /// Tout le monde à qui l'on est connecté. Le point de départ.
  friend('Ami'),

  /// On se croise pour de vrai, régulièrement.
  close('Proche'),

  /// On se voit presque tous les jours.
  inner('Inséparable');

  const FriendshipTier(this.label);

  /// Le nom montré à l'utilisateur.
  ///
  /// ⚠️ Ces trois mots sont **à valider par Jay** : ils n'ont pas été choisis
  /// par lui, et un palier se nomme une seule fois — le renommer plus tard
  /// après que les gens s'y sont attachés est un changement produit, pas un
  /// changement de libellé.
  final String label;

  /// Lu depuis la base. Toute valeur inconnue retombe sur [friend].
  ///
  /// ⚠️ **Le repli est le palier le plus BAS, jamais le plus haut.** Une valeur
  /// ajoutée en base et pas encore connue de l'app ne doit jamais ouvrir un
  /// droit : elle doit le refuser jusqu'à ce que l'app sache ce qu'elle lit.
  static FriendshipTier fromKey(String? value) => switch (value) {
    'close' => FriendshipTier.close,
    'inner' => FriendshipTier.inner,
    _ => FriendshipTier.friend,
  };

  /// Position dans l'échelle — pour comparer deux paliers.
  int get rang => index;

  bool atteint(FriendshipTier minimum) => rang >= minimum.rang;

  /// L'anneau qui entoure la photo de profil.
  ///
  /// ⚠️ **La couleur vient de la palette, jamais d'un hexadécimal écrit ici.**
  /// Sinon les paliers seraient magenta sur les cinq identités, y compris celle
  /// en beige — et la direction artistique se déferait par cet endroit-là.
  ///
  /// La progression est **une montée en intensité, pas trois couleurs au
  /// hasard** : un accent calme, un accent vif, puis le dégradé complet. Seul
  /// le palier le plus haut a droit à la signature de l'identité — c'est ce qui
  /// fait qu'on le remarque.
  Gradient anneau(NeoPalette p) => switch (this) {
    FriendshipTier.friend => LinearGradient(colors: [p.cool, p.cool]),
    FriendshipTier.close => LinearGradient(colors: [p.warm, p.action]),
    FriendshipTier.inner => p.signature,
  };

  /// Le palier le plus bas mérite-t-il un anneau ?
  ///
  /// Non : si tout le monde en a un, l'anneau ne dit plus rien. Il n'apparaît
  /// qu'à partir de « Proche », et c'est ce qui en fait une distinction.
  bool get porteUnAnneau => this != FriendshipTier.friend;
}

/// Ce que l'app sait d'une amitié, tel que le serveur le publie.
///
/// ⚠️ **Tous les nombres sont calculés en base.** L'app n'en dérive aucun :
/// elle affiche `joursAvantSuivant`, elle ne le soustrait pas elle-même.
@immutable
class Friendship {
  const Friendship({
    required this.peerId,
    required this.tier,
    required this.joursCroises,
    required this.joursAvantSuivant,
    required this.serie,
  });

  factory Friendship.fromJson(Map<String, dynamic> json) => Friendship(
    peerId: json['peer_id'] as String,
    tier: FriendshipTier.fromKey(json['tier'] as String?),
    joursCroises: (json['tier_days'] as num?)?.toInt() ?? 0,
    joursAvantSuivant: (json['days_to_next'] as num?)?.toInt(),
    serie: (json['streak'] as num?)?.toInt() ?? 0,
  );

  final String peerId;
  final FriendshipTier tier;

  /// Jours de croisement dans la fenêtre glissante — ce qui porte le palier.
  final int joursCroises;

  /// Ce qu'il reste à faire pour monter. `null` = déjà au sommet.
  final int? joursAvantSuivant;

  /// La série : la longueur de la suite de jours en cours.
  ///
  /// ⚠️ **Ce n'est pas [joursCroises].** L'un est borné par la fenêtre de
  /// comptage (donc réversible, c'est le palier), l'autre peut atteindre 100
  /// (c'est l'échelle de série). Les confondre plafonnerait la série.
  final int serie;

  /// ⚠️ **L'égalité de valeur est obligatoire.** Sans elle, toute vue dérivée
  /// (`DerivedList`, `ValueList`) est inopérante EN SILENCE : elle réveille
  /// l'écran à chaque publication, même identique. C'est ce qui manquait à tous
  /// les modèles avant le 2026-08-25.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Friendship &&
          other.peerId == peerId &&
          other.tier == tier &&
          other.joursCroises == joursCroises &&
          other.joursAvantSuivant == joursAvantSuivant &&
          other.serie == serie;

  @override
  int get hashCode =>
      Object.hash(peerId, tier, joursCroises, joursAvantSuivant, serie);
}

/// L'échelle de la SÉRIE : à quel palier de série correspond un nombre de jours.
///
/// Inspiration validée par Jay le 2026-08-29 (l'échelle œuf → poussin → …).
///
/// ⚠️ **Ce qui fait marcher cette mécanique, ce sont les paliers VERROUILLÉS
/// qu'on voit devant soi**, pas ceux qu'on a franchis. Une échelle qui ne
/// montrerait que le palier courant n'aurait aucune raison d'exister : c'est
/// « 30 jours » grisé qui donne envie du trentième jour.
///
/// ⚠️ **Et notre série n'est pas celle des autres apps.** Ailleurs elle se
/// garde en PUBLIANT tous les jours ; ici elle se garde en **se voyant**. Le
/// même ressort de rétention, mais qui pousse vers le réel au lieu de pousser
/// vers l'écran — c'est la thèse du produit sous forme de jeu.
@immutable
class PalierDeSerie {
  const PalierDeSerie(this.jours, this.emoji, this.nom);

  final int jours;
  final String emoji;
  final String nom;

  /// L'échelle complète, du départ au sommet.
  static const echelle = <PalierDeSerie>[
    PalierDeSerie(0, '🥚', 'Œuf'),
    PalierDeSerie(1, '🐣', 'Éclosion'),
    PalierDeSerie(3, '🐥', 'Poussin'),
    PalierDeSerie(5, '🦎', 'Lézard'),
    PalierDeSerie(7, '🐢', 'Tortue'),
    PalierDeSerie(10, '🦖', 'Dino'),
    PalierDeSerie(14, '🐠', 'Poisson'),
    PalierDeSerie(20, '🐬', 'Dauphin'),
    PalierDeSerie(30, '🐋', 'Baleine'),
    PalierDeSerie(50, '🦄', 'Licorne'),
    PalierDeSerie(75, '🔥', 'Braise'),
    PalierDeSerie(100, '💎', 'Diamant'),
  ];

  /// Le palier atteint avec [jours] jours de série.
  static PalierDeSerie pour(int jours) {
    var atteint = echelle.first;
    for (final p in echelle) {
      if (jours >= p.jours) atteint = p;
    }
    return atteint;
  }

  /// Le palier suivant, ou `null` au sommet — c'est lui qu'on montre verrouillé.
  static PalierDeSerie? suivant(int jours) {
    for (final p in echelle) {
      if (p.jours > jours) return p;
    }
    return null;
  }
}
