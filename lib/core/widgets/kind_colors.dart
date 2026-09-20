import 'package:flutter/material.dart';

import '../models/library_item.dart';

/// **Le liseré d'une mini-card dit la NATURE du contenu** (Jay, 2026-09-20 :
/// *« un code couleur du contour de sorte qu'on puisse visuellement
/// distinguer les vibes, les flows et les publications »*).
///
/// Trois couleurs, une par nature — et rien d'autre sur ce trait : le type
/// d'une Vibe (Standard, Oneshot, BeReal) se dit par sa pastille seule.
/// Deux codes sur le même liseré, c'est zéro code. Valables dans le feed
/// **et** dans la grille du profil : *« tout dans l'affichage de la
/// bibliothèque doit être identique »*.
///
/// ⚠️ Valeurs de départ, à faire valider par Jay — une seule définition,
/// ici, pour qu'un changement soit une ligne.
abstract final class KindColors {
  static const vibe = Color(0xFFE64B8A); // rose — la marque
  static const flow = Color(0xFF3F8CFF); // bleu — la vidéo qui coule
  static const publication = Color(0xFF34B27B); // vert — l'album

  static Color of(LibraryKind kind) => switch (kind) {
    LibraryKind.card => vibe,
    LibraryKind.flow => flow,
    LibraryKind.album => publication,
  };

  static String label(LibraryKind kind) => switch (kind) {
    LibraryKind.card => 'Vibe',
    LibraryKind.flow => 'Flow',
    LibraryKind.album => 'Publication',
  };
}
