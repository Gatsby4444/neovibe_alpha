import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Rendu d'un placeholder de bibliothèque : **un vrai flou**, pas une mosaïque.
///
/// ─── Pourquoi ce widget existe ─────────────────────────────────────────────
///
/// Le placeholder stocké fait 20 px de large. Affiché tel quel dans une tuile
/// six fois plus grande, il donne de gros carrés nets — Jay, au test : « le
/// flou n'est pas suffisant, il est pixelisé et non fluide ». `FilterQuality`
/// n'y change pas grand-chose : l'interpolation bilinéaire lisse les bords mais
/// laisse la grille visible.
///
/// ─── Ce que j'avais confondu ───────────────────────────────────────────────
///
/// La **réduction** et le **flou** ne servent pas la même chose, et j'avais
/// laissé la première faire le travail des deux :
///
/// - la **réduction à 20 px détruit l'information** — c'est elle, et elle
///   seule, qui garantit qu'on ne reconstitue rien avant 18h30 ;
/// - le **flou est un habillage** — il ne protège rien, il rend joli.
///
/// Les appliquer tous les deux ne fait perdre aucune sécurité : **flouter une
/// image déjà détruite n'y réinjecte pas d'information.** On garde donc la
/// source minuscule, et on la donne à voir comme une nappe de couleurs
/// continue plutôt que comme un damier.
///
/// C'est aussi ce qui rend l'animation de reveal possible : un flou est un
/// paramètre continu, qu'on peut faire tomber à zéro en fondu — une mosaïque ne
/// se « dissipe » pas, elle saute d'une résolution à l'autre.
class MaskedPlaceholder extends StatelessWidget {
  const MaskedPlaceholder({
    super.key,
    required this.bytes,
    required this.sigma,
  });

  final Uint8List bytes;

  /// Rayon du flou, en pixels logiques. À accorder à la taille d'affichage :
  /// ~7 pour une tuile de grille, beaucoup plus en plein écran.
  final double sigma;

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        // `decal` évite que le flou aille chercher des pixels hors cadre et
        // laisse un liseré translucide sur les bords de la tuile.
        tileMode: TileMode.decal,
      ),
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        // Le lissage au grossissement reste utile : il donne au flou une base
        // continue plutôt qu'un damier à adoucir.
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
