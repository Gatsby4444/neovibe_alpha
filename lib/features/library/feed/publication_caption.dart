import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../album_editor/overlay_model.dart';
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
    required this.text,
    this.font,
    this.collapsedLines = 2,
  });

  final String text;

  /// Le nom d'une [OverlayFont] ; nul = la police du texte courant.
  final String? font;

  final int collapsedLines;

  @override
  State<PublicationCaption> createState() => _PublicationCaptionState();
}

class _PublicationCaptionState extends State<PublicationCaption> {
  var _deplie = false;

  /// La police choisie, si elle existe encore sous ce nom.
  OverlayFont? get _police {
    final nom = widget.font;
    if (nom == null) return null;
    for (final f in OverlayFont.values) {
      if (f.name == nom) return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final f = _police;
    final style = TextStyle(
      fontSize: 14,
      height: 1.35,
      color: p.ink,
      fontFamily: f?.family,
      fontWeight: f == null
          ? FontWeight.w400
          : FontWeight.values[(f.weight ~/ 100) - 1],
    );

    // Replié, le texte est mis à plat : les sauts de ligne d'une légende ne
    // doivent pas décider de la hauteur d'une cellule du fil.
    final texte = _deplie
        ? widget.text
        : widget.text.replaceAll(RegExp(r'\s*\n+\s*'), ' ').trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.md,
        NeoSpace.xs,
        NeoSpace.md,
        0,
      ),
      child: LayoutBuilder(
        builder: (context, contraintes) {
          final peintre = TextPainter(
            text: TextSpan(text: texte, style: style),
            maxLines: widget.collapsedLines,
            textDirection: Directionality.of(context),
          )..layout(maxWidth: contraintes.maxWidth);
          final deborde = peintre.didExceedMaxLines;
          peintre.dispose();

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: deborde || _deplie
                ? () => setState(() => _deplie = !_deplie)
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  texte,
                  style: style,
                  maxLines: _deplie ? null : widget.collapsedLines,
                  overflow: _deplie ? TextOverflow.clip : TextOverflow.ellipsis,
                ),
                if (deborde || _deplie)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _deplie ? 'moins' : 'plus',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: context.muted,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
