# Thème NeoVibe — le cycle de 24 h

Source de vérité des couleurs du **thème NeoVibe** (celui qui évolue avec
l'heure). Les thèmes **clair** et **sombre** ne sont pas concernés : ils restent
fixes et gardent la contrainte `R == G == B` de `NeoNeutrals`.

⚠️ **Rien n'est encore implémenté côté Flutter.** Ce document existe pour que la
maquette Rive et le futur moteur partagent les mêmes nombres — sans lui, les
deux dériveraient l'un de l'autre.

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

## Les ancrages

**Version 2, du 2026-08-15.** Jay a trié lui-même les palettes en `matin`,
`midi` et `soir` (`docs/images/`), après avoir rejeté la v1 : *« le tout premier
gradient bleu ne me plaît pas […] ce que je veux c'est une atmosphère qui a
l'air premium et naturelle, qui respire, il y a beaucoup de bleu, souvent
présent. »*

**Ce que sa répartition change, et c'est l'essentiel** : il met du **vert au
cœur de la journée** (Jungle à midi). Ce n'est pas un détail de teinte — ça
déplace la référence du **ciel** vers la **végétation**. C'est ça, « naturelle
qui respire », et c'est ce qui règle le « trop de bleu » : la v1 racontait un
ciel du matin au soir, la v2 raconte un paysage.

La **nuit n'est plus bleue** non plus : elle est vert-noir, dans la continuité
de Deep Forest.

| Heure | Haut | Bas | Palette | Dossier |
|---|---|---|---|---|
| 00 h | `#04150F` | `#06231D` | nuit — vert-noir | — |
| 03 h | `#071512` | `#0C342C` | Jungle sombre | — |
| 05 h | `#1B0B3D` | `#5B22C8` | **Deep Ocean** — avant-aube | matin |
| 06 h | `#A92655` | `#FD8D67` | **Velvet Sunset** — lever | matin |
| 08 h | `#DD7A83` | `#E8BFC3` | **Blush Silk** | matin |
| 10 h | `#292F91` | `#4CA8DD` | **Azuria** | matin |
| 12 h | `#076653` | `#E2FBCE` | **Jungle** — midi | midi |
| 14 h | `#7AABFF` | `#FF9AEF` | **Cotton Candy** | midi |
| 16 h | `#708F96` | `#AA895F` | **Muted Olive Sky** | soir |
| 18 h | `#BC430D` | `#F09410` | **Desert** — coucher | soir |
| 20 h | `#6968A6` | `#CF9893` | **Lavender Dusk** — crépuscule | soir |
| 22 h | `#034C36` | `#003332` | **Deep Forest** — nuit tombée | soir |
| 24 h | = 00 h | = 00 h | boucle | — |

Les heures intermédiaires sont **calculées en OkLab** entre ces ancrages.

Restent inutilisées pour l'instant : **Glacium** (`#085078 → #9AE4CB`) et
**champigreen**, faute de place dans l'arc — à ressortir si Jay veut remplacer
un ancrage.

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

**Pourquoi l'interpolation est linéaire** : toute accélération créerait un
rythme horaire, et un rythme se remarque. Le soleil n'accélère pas.

⚠️ Le `.riv` est un **instrument de choix**, pas l'implémentation. Le moteur
Flutter calculera `thème(t)` ; Rive ne saurait pas piloter les couleurs des
widgets.
