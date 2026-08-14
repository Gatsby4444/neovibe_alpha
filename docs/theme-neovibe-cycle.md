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

Tirés des palettes fournies par Jay (`docs/images/`). Les heures intermédiaires
sont **calculées en OkLab** entre ces ancrages.

| Heure | Haut | Bas | Palette d'origine |
|---|---|---|---|
| 00 h | `#010030` | `#160078` | Deep ocean — nuit profonde |
| 03 h | `#0B0A3A` | `#2A1A66` | nuit |
| 05 h | `#6968A6` | `#CF9893` | **Lavender Dusk** — aube |
| 07 h | `#3F6FA8` | `#E8BFC3` | lever (Blush Silk en bas) |
| 09 h | `#085078` | `#9AE4CB` | **Glacium** — matin |
| 12 h | `#292F91` | `#4CA8DD` | **Azuria** — midi, lumière bleue |
| 15 h | `#2A5C9B` | `#8FC7E8` | après-midi |
| 18 h | `#A92655` | `#FD8D67` | **Velvet Sunset** — coucher |
| 20 h | `#5E1B3A` | `#C4573F` | soir chaud |
| 22 h | `#2A0F2E` | `#5E1B3A` | nuit tombée |
| 24 h | = 00 h | = 00 h | boucle |

L'arc suit la logique circadienne demandée par Jay : **bleu et vif le matin
pour éveiller, chaud le soir pour ne pas fatiguer les yeux.**

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
  dégradé — le cas de nos boutons caméra sans fond), et un bouton d'accent.

**Pourquoi une clé par heure et pas par ancrage** : Rive interpole en **RVB**.
Des segments d'une heure sont assez courts pour que le chemin RVB colle au
chemin OkLab. Conséquence : **ce qui est validé dans Rive est ce que l'app
produira.**

**Pourquoi l'interpolation est linéaire** : toute accélération créerait un
rythme horaire, et un rythme se remarque. Le soleil n'accélère pas.

⚠️ Le `.riv` est un **instrument de choix**, pas l'implémentation. Le moteur
Flutter calculera `thème(t)` ; Rive ne saurait pas piloter les couleurs des
widgets.
