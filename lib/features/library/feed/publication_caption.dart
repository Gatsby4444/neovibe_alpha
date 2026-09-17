import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../core/typography.dart';

/// **La limite d'une légende : 500 signes, espaces et sauts de ligne
/// compris** (Jay, 2026-09-17). Il n'y en avait aucune en base — seulement un
/// plafond de saisie à 2200, qu'un client modifié pouvait ignorer.
const kCaptionMax = 500;

/// **La légende d'une publication.**
///
/// Jay, 2026-09-17 : *« la description n'est pas bien intégrée à l'UI, je
/// propose que tu restylises cette partie pour mieux la démarquer et la mettre
/// en valeur »*, avec un bouton discret **plus** / **moins** quand le texte
/// est trop long.
///
/// Ce qui la démarque : un bloc posé sur une surface à peine plus claire que
/// le fond, coins arrondis, à la largeur du média. Le texte cesse d'être une
/// ligne perdue sous une image — il devient une **zone**, qui commence et qui
/// finit.
///
/// ⚠️ **Le bouton n'apparaît que s'il sert.** Un « plus » sous un texte de
/// deux mots dit à l'utilisateur qu'il rate quelque chose ; on mesure donc le
/// texte à la largeur réelle (`TextPainter.didExceedMaxLines`) avant de
/// l'afficher. Une limite en nombre de caractères se tromperait à chaque
/// changement de police ou de largeur d'écran.
class PublicationCaption extends StatefulWidget {
  const PublicationCaption({
    super.key,
    required this.author,
    required this.text,
    this.collapsedLines = 3,
  });

  final String? author;
  final String text;
  final int collapsedLines;

  @override
  State<PublicationCaption> createState() => _PublicationCaptionState();
}

class _PublicationCaptionState extends State<PublicationCaption> {
  var _deplie = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(fontSize: 14, height: 1.35, color: p.ink);
    final gras = style.copyWith(fontWeight: FontWeight.w700);
    final auteur = widget.author;

    final span = TextSpan(
      style: style,
      children: [
        if (auteur != null && auteur.isNotEmpty)
          TextSpan(text: '$auteur ', style: gras),
        TextSpan(text: widget.text),
      ],
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(
        NeoSpace.md,
        NeoSpace.sm,
        NeoSpace.md,
        0,
      ),
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.md,
        NeoSpace.sm + 2,
        NeoSpace.md,
        NeoSpace.sm + 2,
      ),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: LayoutBuilder(
        builder: (context, contraintes) {
          // Est-ce que ça dépasse vraiment ? On mesure, on ne devine pas.
          final peintre = TextPainter(
            text: span,
            maxLines: widget.collapsedLines,
            textDirection: Directionality.of(context),
          )..layout(maxWidth: contraintes.maxWidth);
          final deborde = peintre.didExceedMaxLines;
          peintre.dispose();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Le texte entier reste tapable : c'est le geste le plus
              // naturel pour déplier, le bouton n'est là que pour le dire.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: deborde
                    ? () => setState(() => _deplie = !_deplie)
                    : null,
                child: RichText(
                  text: span,
                  maxLines: _deplie ? null : widget.collapsedLines,
                  overflow: _deplie ? TextOverflow.clip : TextOverflow.ellipsis,
                ),
              ),
              if (deborde)
                Padding(
                  padding: const EdgeInsets.only(top: NeoSpace.xs),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _deplie = !_deplie),
                    child: Text(
                      _deplie ? 'moins' : 'plus',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: context.muted,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
