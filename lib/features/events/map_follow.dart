/// **Ce que fait la carte avec mon point** — le bouton « recentrer » à la
/// façon de Google Maps (Jay, 2026-09-26 : *« le premier clic sert à
/// recentrer la map sur le point si ce n'est pas déjà centré, et le deuxième
/// sert à orienter la carte dans la direction dans laquelle on regarde »*).
enum MapFollow {
  /// La carte est libre : on la déplace à la main, elle ne suit personne.
  libre,

  /// La carte suit mon point, nord en haut.
  centre,

  /// La carte suit mon point ET tourne avec moi : ce qui est devant moi est
  /// en haut de l'écran.
  boussole;

  /// Le mode après un appui sur le bouton.
  ///
  /// libre → centré → boussole → centré… Sans boussole sur l'appareil, le
  /// deuxième appui ne peut rien orienter : on reste centré.
  MapFollow afterTap({required bool hasHeading}) => switch (this) {
    MapFollow.libre => MapFollow.centre,
    MapFollow.centre => hasHeading ? MapFollow.boussole : MapFollow.centre,
    MapFollow.boussole => MapFollow.centre,
  };

  /// Le mode après que l'utilisateur a DÉPLACÉ la carte à la main : elle
  /// cesse de le suivre — sinon elle lui reprendrait la carte sous le doigt.
  MapFollow get afterPan => MapFollow.libre;

  /// La carte bouge-t-elle avec mon point ?
  bool get follows => this != MapFollow.libre;
}
