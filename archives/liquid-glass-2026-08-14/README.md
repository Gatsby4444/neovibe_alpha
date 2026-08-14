# Pilote « liquid glass » — archivé le 2026-08-14

**Ce dossier ne fait PAS partie de l'app.** Rien ici n'est compilé, importé ni
embarqué : `archives/` est hors de `lib/` et hors de `assets/`. C'est un dépôt
de pièces, conservé à la demande de Jay — « garde le code quelque part au cas
où, dans un dossier poubelle totalement séparé de l'app mais auquel on pourra se
référer si je change d'avis ».

## Pourquoi c'est là et pas dans l'app

Jay, 2026-08-14 : « je pense que cela ne vaut pas le coup pour le moment, je
vais réfléchir à une autre DA ». **Décision de direction artistique, pas un
échec technique** — au moment de l'archivage, le shader compilait, se chargeait
et s'appliquait. Ce qui est en pause, c'est le parti pris visuel.

## Ce qu'il y a dedans

| Fichier | Ce que c'est | Où il vivait |
|---|---|---|
| `shaders/liquid_glass.frag` | Le shader de réfraction | `assets/shaders/` |
| `lib/glass_controls.dart` | `GlassRail`, `GlassCircleButton`, `GlassQuality`, `LiquidGlassProgram` | `lib/features/cards/` |
| `lib/frame_cost_trace.dart` | Mesure du coût d'affichage image par image | `lib/core/diagnostics/` |
| `points-de-branchement.diff` | **Le diff complet de l'intégration** (`471060d..96798ec`) | — |

Le `.diff` est la pièce importante : il contient tous les points de couture
dans l'app (rail, boutons, préférence, écran Développeur, section du
diagnostic, `pubspec.yaml`). Sans lui, remonter le pilote demanderait de
redeviner sept branchements.

## Pour le remonter

1. `assets/shaders/liquid_glass.frag`, et déclarer dans `pubspec.yaml` :
   ```yaml
   flutter:
     shaders:
       - assets/shaders/liquid_glass.frag
   ```
2. `lib/features/cards/glass_controls.dart` et
   `lib/core/diagnostics/frame_cost_trace.dart`.
3. Rejouer `points-de-branchement.diff` — ou le lire et refaire les coutures à
   la main si l'app a bougé entre-temps.

## Les trois faits vérifiés qui conditionnent tout

À revérifier avant de reprendre, car chacun peut avoir changé :

1. **L'aperçu caméra doit rester un `Texture`** (`native_camera.dart`, ligne
   ~511 au 2026-08-14). Une texture externe est composée **dans** la scène
   Flutter, donc un filtre s'y applique. Si l'aperçu passait un jour en
   `PlatformView`, il serait composé par le système sur une couche séparée et
   **rien de tout ceci ne fonctionnerait** — aucune erreur ne serait levée, le
   verre serait simplement vide.
2. **`ui.ImageFilter.shader` exige Impeller.** Vérifié à l'exécution par
   `ui.ImageFilter.isShaderFilterSupported`. Impeller est le défaut Android en
   Flutter 3.44.6 et n'était désactivé ni dans le manifeste ni dans
   `gradle.properties`.
3. **L'ordre des `setFloat` suit l'ordre de déclaration des uniformes** dans le
   `.frag`. Un décalage d'un cran ne lève **aucune erreur** : il donne un rendu
   absurde. Toute modification du shader oblige à rejouer cette liste dans
   `_liquidSurface`.

## La leçon, elle, ne s'archive pas

La v1 du pilote (v0.9.75) a été rejetée par Jay : « il n'y a pas l'effet liquid
glass ». Elle empilait un flou, une teinte et un **liseré irisé peint à la
main**. C'est du verre **dépoli** — le matériau d'iOS 7 à 18.

Le liquid glass est une **lentille** : ce qui le définit n'est pas le flou, mais
que le fond soit **réfracté**, courbé au bord et intact au centre. Son irisation
n'est pas une décoration, c'est la **dispersion chromatique** de cette
réfraction.

**Je peignais le symptôme à la place de la cause.** Aucun réglage du liseré
n'aurait pu sauver la v1 — c'est le modèle qui était faux, pas ses paramètres.
Voir `rapports-de-sessions/2026-08-14_16-30.md`.

## Versions concernées

- **v0.9.75** — pilote v1, verre dépoli. Rejeté.
- **v0.9.76** — v2, réfraction réelle par shader. Archivé ici.
