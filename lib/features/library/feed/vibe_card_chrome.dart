import 'package:flutter/material.dart';

import '../../../core/typography.dart';

/// **Ce qui s'affiche sur la carte en plein écran — et qui lui appartient.**
///
/// Demande de Jay, 2026-09-16 : *« en plein écran ce serait bien d'incorporer
/// les boutons dans la card à droite, mais qu'ils bougent avec la card de
/// manière dynamique (les mêmes des deux côtés et mêmes états) […] mettre
/// toute la partie (PP, username, date, type) au-dessus et pas en dessous, et
/// de même incorporée à la card »*.
///
/// **Ce que ça change, et pourquoi c'est mieux** : tant que l'identité et les
/// actions vivaient *autour* de la carte, il fallait leur réserver de la place
/// — et la carte se retrouvait décalée, plus centrée à l'écran (ce que Jay a
/// vu sur la v0.9.191). Dedans, elles ne prennent aucune place : la carte
/// redevient centrée et prend tout l'écran.
///
/// Ce widget ne sait **rien** de ce qu'il pose (ni likes, ni profil, ni
/// suppression) : il reçoit trois morceaux déjà construits et décide seulement
/// où ils vont. C'est ce qui le rend mesurable seul
/// (`test/vibe_card_chrome_test.dart`), sans réseau ni clé.
class VibeCardChrome extends StatelessWidget {
  const VibeCardChrome({
    super.key,
    required this.header,
    required this.actions,
    this.caption,
  });

  /// L'identité : photo, pseudo, date, type. En haut.
  final Widget header;

  /// La colonne d'actions. À droite, en bas.
  final Widget actions;

  /// La légende, si elle existe. En bas à gauche, à côté des actions.
  final Widget? caption;

  /// ⚠️ **La bande du bas reste libre.** Une face vidéo y pose sa barre de
  /// lecture, déplaçable au doigt : poser une action dessus, c'est une barre
  /// qu'on n'attrape plus (`SealedVideoProgressBar` : 4 px de barre dans
  /// 10 px de marge haute et basse).
  static const barreDeLecture = 26.0;

  /// La place laissée en haut à droite pour la croix de fermeture, qui est
  /// une commande de l'ÉCRAN et reste donc fixe par-dessus.
  static const placeDeLaCroix = 44.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Les voiles : du texte blanc doit rester lisible sur une image
        // claire. Ils ne prennent aucun doigt.
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(child: _Voile(hauteur: 116, versLeBas: true)),
        ),
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(child: _Voile(hauteur: 200, versLeBas: false)),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              NeoSpace.md,
              NeoSpace.sm,
              placeDeLaCroix,
              0,
            ),
            child: header,
          ),
        ),
        Positioned(right: 0, bottom: barreDeLecture, child: actions),
        if (caption != null)
          Positioned(
            left: NeoSpace.md,
            // La colonne d'actions garde sa colonne : la légende s'arrête
            // avant, elle ne passe pas dessous.
            right: 56,
            bottom: barreDeLecture + NeoSpace.xs,
            child: caption!,
          ),
      ],
    );
  }
}

/// Un dégradé du noir vers le transparent, dans un sens ou dans l'autre.
class _Voile extends StatelessWidget {
  const _Voile({required this.hauteur, required this.versLeBas});

  final double hauteur;
  final bool versLeBas;

  @override
  Widget build(BuildContext context) {
    const noir = Color(0x8C000000); // noir à 55 %
    return Container(
      height: hauteur,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: versLeBas ? Alignment.topCenter : Alignment.bottomCenter,
          end: versLeBas ? Alignment.bottomCenter : Alignment.topCenter,
          colors: const [noir, Colors.transparent],
        ),
      ),
    );
  }
}
