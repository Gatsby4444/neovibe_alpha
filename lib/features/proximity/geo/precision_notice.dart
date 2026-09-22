/// **Ce qu'on dit quand Android ne donne qu'une position approximative — et on
/// le dit au même endroit, une seule fois.**
///
/// ## 🔴 Le défaut relevé le 2026-09-22 au soir
///
/// Diagnostic de Jay, `app 0.9.247+5121`, lu en base :
///
/// ```
/// finesse       : approximate
/// carreau       : carreau(5061, 312) ± 2000 m · best
/// repli haut    : aucun échec
/// convergence   : aucun relevé en 10 s
/// ```
///
/// Il n'avait accordé que la position **approximative**. Android brouille
/// alors volontairement à environ deux kilomètres — le point de la carte était
/// à trois kilomètres de l'endroit réel. `repli haut : aucun échec` établit que
/// **rien n'était en panne** : le meilleur palier répondait, et rendait
/// fidèlement ce qu'Android acceptait de dire.
///
/// L'écran du ping l'annonçait depuis le 2026-08-26. **La carte, arrivée
/// après, ne l'annonçait pas** — et c'est elle qu'on regarde pour juger si la
/// position est juste. Deux écrans pour un même fait, un seul le disait.
///
/// ## ⚠️ Pourquoi un fichier, pour trois phrases
///
/// Parce que la deuxième copie d'un texte est celle qu'on oublie de corriger.
/// Le jour où la formulation change — ou le jour où Android change le nom du
/// réglage — il doit y avoir **un** endroit à modifier, pas deux écrans à
/// retrouver. Règle de `CLAUDE.md` : *scalable veut dire le coût d'ajouter le
/// prochain cas.*
library;

import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// Le titre. **Il nomme la cause, pas le symptôme.**
///
/// ⚠️ Ni « position imprécise » ni « GPS faible » : ce serait accuser le
/// téléphone d'un réglage. Ce qui se passe est qu'Android **a reçu l'ordre**
/// de ne pas en dire plus, et ça se répare en un geste.
const titrePositionApprochee = 'Position approximative autorisée';

/// Le détail, en français de tous les jours.
///
/// ⚠️ Il dit **le chiffre** (2 km), parce que sans lui l'utilisateur ne fait
/// pas le lien avec le point qu'il voit à trois rues de là ; et il dit ce que
/// ça **ne** casse **pas**, parce que la thèse du produit repose sur le
/// Bluetooth, pas sur le GPS.
const detailPositionApprochee =
    "Tu as autorisé NeoVibe à connaître ta position « approximative » : "
    "Android répond alors volontairement à environ 2 km près, et le point sur "
    "la carte peut tomber à plusieurs rues d'ici. Ce n'est pas une panne, et "
    "ça se change en une fois.\n\n"
    "La position sert seulement à savoir OÙ chercher. Qui est vraiment à 20 m, "
    "c'est le Bluetooth qui le prouve — et lui n'est pas concerné.";

/// L'action. **Un verbe, et ce qu'on obtient.**
const actionPositionApprochee = 'Autoriser la position précise';

/// L'avertissement **posé sur une carte**.
///
/// ⚠️ Il ne réutilise pas le bandeau de l'écran du ping, et c'est volontaire :
/// là-bas c'est une carte dans une liste qui pousse le reste vers le bas ; ici
/// il flotte au-dessus des tuiles, donc il lui faut son propre fond opaque —
/// sur une carte, un texte sans fond est illisible une fois sur deux.
/// Ce qui ne doit pas être dupliqué, c'est le **texte**, et il ne l'est pas.
class BandeauPositionApprochee extends StatelessWidget {
  const BandeauPositionApprochee({super.key, required this.onAutoriser});

  final VoidCallback onAutoriser;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      color: p.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.blur_on, size: 18, color: p.inkMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    titrePositionApprochee,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              detailPositionApprochee,
              style: TextStyle(color: p.inkMuted, fontSize: 12),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onAutoriser,
                child: const Text(actionPositionApprochee),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
