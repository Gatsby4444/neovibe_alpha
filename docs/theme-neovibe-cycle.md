# Thème NeoVibe — le cycle de 24 h

Source de vérité des couleurs du **thème NeoVibe** (celui qui évolue avec
l'heure). Les thèmes **clair** et **sombre** ne sont pas concernés : ils restent
fixes et gardent la contrainte `R == G == B` de `NeoNeutrals`.

⚠️ **Le moteur est implémenté** (`lib/core/day_cycle.dart`, testé par
`test/day_cycle_test.dart`) **mais n'est branché sur aucun écran de l'app** :
seul l'aperçu développeur l'utilise. Ce document reste la source commune du
moteur et de la maquette Rive — sans lui, les deux dériveraient l'un de l'autre.

## Le principe

Le thème est une **fonction pure de l'heure**, `thème(t)`, `t` réel sur 24 h.
Pas d'états, pas de paliers, pas de fondu — on interpole la palette **par** `t`.

Trois conséquences, et c'est ce qui a fait choisir ce modèle :

1. **Aucune transition à concevoir** : le problème disparaît au lieu d'être
   résolu. Une transition, même longue, a un début et une fin — donc elle se
   remarque. Le soleil ne transitionne pas.
2. **Aucun instant où « ça change »**, puisque ça change en permanence.
   Mesure : ~**0,3° de teinte par minute**, soit moins d'un degré sur une
   session de deux minutes — sous le seuil de perception.
3. **Déterministe, donc testable exhaustivement** : on peut vérifier les 1440
   minutes de la journée et prouver qu'aucune ne casse le contraste.

## Interpolation : OkLab, jamais sRVB

Interpoler `#292F91` (bleu profond) vers `#FD8D67` (orange chaud) en RVB passe
par un **gris-brun mort**. En OkLab le chemin reste saturé.

C'est le seul endroit du chantier où il ne faut pas faire d'économie : c'est ce
qui sépare un rendu « cher » d'un rendu bricolé.

### La corde et l'arc — relevé du 2026-08-15

OkLab ne suffit pas à lui seul. Une interpolation linéaire dans le plan (a, b)
est une **corde** : elle coupe à travers le centre de la roue, c'est-à-dire à
travers le **gris**. Quand deux palettes voisines ont des teintes opposées, le
milieu du segment est plus terne que ses **deux** extrémités.

| Moment | Avant | Après | Vu au milieu |
|---|---|---|---|
| 12 h 30 | Jungle 0,075 | Cotton Candy 0,146 | **0,043** |
| 15 h | Cotton Candy 0,146 | Muted Olive 0,053 | **0,045** |
| 19 h 30 | Desert 0,164 | Lavender Dusk 0,081 | **0,074** |

Ces creux sont une bonne moitié des « gradients ternes » relevés par Jay, et ils
ne sont dans **aucune palette** — ils naissent du chemin.

L'**arc** fait tourner la teinte sur le chemin court et interpole la chroma
séparément : **+18 % de chroma sur la journée, aucune palette touchée**. Aux
heures d'ancrage la couleur est exactement celle du tableau.

✅ **Adopté définitivement par Jay le 2026-08-15**, après comparaison à l'œil
dans l'aperçu — *« l'arc me va nickel »*. La corde a été **retirée du chemin
temporel** ; il n'en reste que l'usage vertical.

**La propriété que cela garantit**, et que `day_cycle_test.dart` surveille
désormais : *le milieu d'un segment n'est jamais plus terne que sa borne la plus
terne.* Pire ratio mesuré **0,83 avec l'arc, contre 0,37 avec la corde** ; 11
segments sur 12 sont à 1,00 ou mieux.

⚠️ Ce test existe parce que le retour en arrière serait **invisible** : une
lettre changée dans `DayCycle.at`, aucune erreur, aucun avertissement — et un
défaut qu'on ne verrait qu'en ouvrant l'app à la bonne heure.

⚠️ **L'arc va sur le TEMPS, jamais sur la verticale du dégradé.** Le haut et le
bas d'un même dégradé passent, à certaines heures, par 180° d'écart : l'arc
court bascule alors de côté et la bande médiane saute à travers la roue —
mesuré **ΔE 0,29 sur 3 min**, quinze fois le seuil, contre 0,017 pour la corde.

## Les ancrages

**Version 3, du 2026-08-15.** Réorganisée selon l'**audience réelle** de chaque
heure, et non selon le réalisme du ciel — demande de Jay : *« certains gradients
sont ternes, et les plus colorés sont parfois mis la nuit pendant que personne
ne regarde. »*

**Ce que la v2 avait de faux, mesuré** : une anti-corrélation quasi parfaite
entre chroma et audience. Les deux palettes les plus colorées (Deep Ocean 0,159,
Velvet Sunset 0,157) étaient à 4 h et 6 h ; le pic du soir (19 h–22 h) tombait
sur les trois plus ternes — Lavender Dusk 0,081, Deep Forest 0,063, Nuit 0,032.

**Les deux décisions de Jay** : ① tout est décalé d'environ 2 h ; ② **Desert
quitte le soir pour la nuit**, juste après le vert sombre et avant Deep Ocean —
*« c'est un peu sombre pour l'après-midi et ne s'insère pas bien là où c'est
actuellement entre les autres palettes. »*

⚠️ **Contrepartie assumée, à ne pas oublier** : Desert est la seule palette à la
fois riche (0,164), chaude et mi-sombre — donc la seule qui cochait tout pour le
pic du soir. En la mettant à 6 h, plus rien dans le jeu ne tient ce rôle et le
pic plafonne autour de 0,06–0,12. C'est un arbitrage de **cohérence d'arc**
contre un arbitrage d'**audience** ; Jay a tranché pour le premier.

**La cadence n'est plus uniforme**, et c'est le sujet de cette version : chaque
segment reçoit la durée que sa distance de couleur exige, et le reste du budget
va là où il y a du monde. Mesuré : le minimum imposé par le seuil
d'imperceptibilité est de **~11 h sur 24** — il reste **13 h** à répartir.

| Heure | Haut | Bas | Palette | Dossier |
|---|---|---|---|---|
| 00 h 00 | `#034C36` | `#003332` | **Deep Forest** — nuit | soir |
| 01 h 30 | `#04150F` | `#06231D` | nuit — vert-noir | — |
| 03 h 30 | `#071512` | `#0C342C` | Jungle sombre | — |
| 06 h 00 | `#BC430D` | `#F09410` | **Desert** | soir |
| 08 h 00 | `#1B0B3D` | `#5B22C8` | **Deep Ocean** | matin |
| 10 h 00 | `#A92655` | `#FD8D67` | **Velvet Sunset** | matin |
| 11 h 30 | `#DD7A83` | `#E8BFC3` | **Blush Silk** | matin |
| 13 h 00 | `#292F91` | `#4CA8DD` | **Azuria** — lumière bleue | matin |
| 14 h 30 | `#076653` | `#E2FBCE` | **Jungle** | midi |
| 16 h 00 | `#708F96` | `#AA895F` | **Muted Olive Sky** | soir |
| 18 h 00 | `#7AABFF` | `#FF9AEF` | **Cotton Candy** | midi |
| 21 h 30 | `#6968A6` | `#CF9893` | **Lavender Dusk** | soir |
| 24 h 00 | = 00 h | = 00 h | boucle | — |

Les heures intermédiaires sont **calculées en OkLab** entre ces ancrages.

⚠️ **Le saut `Jungle sombre → Desert` (vert quasi noir → orange) est le plus
grand de l'arc.** Posé sur 1 h 30 il **faisait échouer** le test des 1440
minutes (0,0202 pour un seuil de 0,0200). Il lui faut 2 h 30 — ne pas le
resserrer.

**Bilan mesuré** — chroma moyenne *réellement vue*, pondérée par l'audience :

| | |
|---|---|
| v2 (corde) | 0,0771 |
| v3, corde seule | 0,0878 (+14 %) |
| v2 + arc seul | 0,0904 (+17 %) |
| **v3 + arc — livré** | **0,1031 (+34 %)** |

Les deux leviers pèsent autant et se cumulent.

**Les quatre creux que l'arc a supprimés** (milieu de segment plus terne que ses
deux bornes, avec la corde) :

| Heure | Trajet | Corde | Arc |
|---|---|---|---|
| 07 h 00 | Desert → Deep Ocean | 0,086 | **0,178** |
| 12 h 20 | Blush Silk → Azuria | 0,069 | **0,120** |
| 13 h 50 | Azuria → Jungle | 0,076 | **0,099** |
| 22 h 45 | Lavender Dusk → Deep Forest | **0,024** | **0,064** |

Celui de 22 h 45 tombait à une heure de **pic d'audience**, à 0,024 — soit
pratiquement du gris pur.

Restent inutilisées : **Glacium** (`#085078 → #9AE4CB`) et **champigreen**.
Glacium a été testée en remplacement de Muted Olive Sky (la plus terne du
jour) : **gain net +0,002, nul** — ça ne vaut pas de changer une palette.

## L'accent, et la règle de contraste

L'accent (boutons) **suit l'heure mais reste borné** :

1. On prend la **teinte du haut** du dégradé de l'heure courante.
2. On fixe une chroma tenue (OkLab C = 0,15) pour que l'accent reste franc.
3. On **descend la luminance** jusqu'à garantir **4,5:1 avec du texte blanc**.

La couleur suit l'heure ; la lisibilité ne se négocie pas.

⚠️ **Pourquoi le HAUT et pas le bas** : à 08 h le bas du dégradé est presque
gris (`#C6D2C7`), et une teinte extraite d'un gris est **instable** — l'accent
y virait au vert sans raison. Le haut reste franc toute la journée.

Contraste mesuré sur les 24 h : **pire cas 4,50:1**.

## Les surfaces

Le dégradé est un **fond d'écran**, pas une surface. Tout ce qui porte du texte
reste **neutre** (`NeoNeutrals`), posé en voile translucide par-dessus. Le texte
a donc toujours son fond garanti, quelle que soit l'heure — le contraste est
assuré **par construction**, pas par calcul.

## Le test — et le piège qu'il a révélé

`test/day_cycle_test.dart` vérifie les **1440 minutes** de la journée.

Sa première version comparait deux minutes **consécutives** et échouait à 5 h.
Mauvaise raison : à cette heure le fond est très sombre, et dans les tons
sombres **un seul cran de quantification 8 bits** pèse plus lourd en ΔE que le
déplacement réel de la palette. Le test mesurait la **résolution de l'écran**,
pas la conception.

Mesuré : à 1 minute le pire cas tombe à 5,27 h (quantification) ; dès 3 minutes
il se déplace à 21,8 h, qui est le vrai segment le plus rapide.

La bonne formulation compare donc **sur une fenêtre de session** (3 minutes) et
exige que la dérive reste sous **0,02 ΔE** — l'écart juste perceptible *côte à
côte*. Autrement dit : une session entière change moins que ce que l'œil
distingue avec les deux couleurs sous les yeux en même temps, alors qu'ici il
n'a aucune référence.

## La maquette Rive

`Cycle 24h`, artboard 390 × 844, animation `24h` :

- **1440 images à 60 i/s** — 1 image = 1 minute, 1 seconde = 1 heure, la
  journée en **24 s**, en boucle.
- Clés **toutes les 60 images** (une par heure), en interpolation **linéaire**.
- Contenu : le fond dégradé, une surface neutre avec trois barres de texte, deux
  **sondes** (un disque blanc et un disque noir posés directement sur le
  dégradé — le cas de nos boutons caméra sans fond), un bouton d'accent, et
  l'**horloge**.
- **L'horloge** (demandée par Jay le 2026-08-15) : un cadran de 24 h,
  **midi en haut, minuit en bas**. L'aiguille suit donc la course du soleil —
  elle se lève à gauche (06 h), culmine au sommet (12 h), se couche à droite
  (18 h). Traits longs aux quarts de journée (0/6/12/18 h), courts aux 3 h.
  Une seule rotation linéaire, 180° → 540° sur les 1440 images.

  ⚠️ Pas d'affichage **numérique** : le MCP Rive n'expose aucun outil de
  création de *text run*. Un cadran était la seule option, et c'est de toute
  façon le plus lisible en lecture continue.

**Pourquoi une clé par heure et pas par ancrage** : Rive interpole en **RVB**.
Des segments d'une heure sont assez courts pour que le chemin RVB colle au
chemin OkLab. Conséquence : **ce qui est validé dans Rive est ce que l'app
produira.**

⚠️ **À refaire avant de rouvrir la maquette (2026-08-15).** Elle a été construite
sur la v2, dont tous les ancrages tombaient sur des heures rondes. La v3 en pose
trois sur des **demi-heures** (01 h 30, 03 h 30, 21 h 30) : une grille de clés
horaire les **manquerait** et couperait l'angle exactement là où la couleur
change de direction. Il faut donc des clés **toutes les 30 images** (une par
demi-heure), ou des clés posées sur les ancrages eux-mêmes. Sans ça, la maquette
et l'app diront deux choses différentes — et c'est précisément ce que ce
document sert à empêcher.

**Pourquoi l'interpolation est linéaire** : toute accélération créerait un
rythme horaire, et un rythme se remarque. Le soleil n'accélère pas.

⚠️ Le `.riv` est un **instrument de choix**, pas l'implémentation. Le moteur
Flutter calculera `thème(t)` ; Rive ne saurait pas piloter les couleurs des
widgets.
