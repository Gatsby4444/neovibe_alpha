# Relevés à faire — proximité

Ce qu'il faut mesurer pour les tests restants, et **ce qui doit être envoyé**
via Réglages → Développeur → *Mise à jour et rapports* → **Tout envoyer**.

> ⚠️ **Toujours remplir la note avant d'envoyer.** Le rapport porte déjà sa date,
> sa version et son appareil ; la note est la seule chose qu'il ne peut pas
> deviner — **ce que tu étais en train de faire**. Sans elle, deux rapports
> identiques à cinq minutes d'écart ne se distinguent plus.

---

## Ce qui est déjà validé, et n'a plus besoin d'être relevé

| Sujet | Preuve |
|---|---|
| Bluetooth éteint / rallumé, permissions, redémarrage de l'app | série 1, validée au test |
| Localisation Android ≤ 11 | tablette passée de 0 à 166 annonces NeoVibe |
| Reconnaissance silencieuse des amis | 2 waves en base, dans les deux sens, à la même seconde |
| Certificat de croisement co-signé | `encounters.last_seen_at` mis à jour à 21 h 46 |
| Chat ping | validé par Jay (lent, à mesurer plus tard) |
| Coupures Bluetooth / Wi-Fi / app fermée | série 3, validée |

**Ne pas les refaire** tant que rien ne les remet en cause. Un test qu'on rejoue
sans hypothèse ne produit qu'un rapport de plus.

---

# Série v0.9.131 — à faire en premier (2026-08-26)

> Cette série remplace tout ce qui suit tant qu'elle n'est pas passée. Cinq
> correctifs y sont livrés d'un coup, et **trois d'entre eux se prouvent par un
> chiffre du diagnostic**, pas par une impression.

## ⚠️ Prérequis — sans lui, tous les relevés sont ininterprétables

**Le protocole d'annonce passe de 4 à 5. Un appareil en v4 et un en v5 ne se
voient pas du tout.**

| À vérifier | Où | Attendu |
|---|---|---|
| Les deux appareils sont en v0.9.131 | en-tête du diagnostic | `app 0.9.131+3005` |
| Ils parlent la même version de protocole | section proximité | `protocolVersion : 5` **des deux côtés** |

Si l'un des deux est resté en 4, `otherVersionScans` montera et `neoScans`
restera à zéro — et le diagnostic écrira lui-même la phrase qui le dit.

---

## Relevé 1 — le croisement d'amis (le correctif principal)

**Geste** : les deux appareils côte à côte, ping activé des deux côtés, attendre
une minute sur l'écran Ping.

**Ce qu'on regarde à l'écran** : la section *Autour de toi — ancien chemin
(BLE seul)*.

| | Avant (v0.9.130) | Attendu maintenant |
|---|---|---|
| Affichage | « 6 appareils détectés — Vérification chiffrée en cours… » | **le nom de l'autre**, directement |

**Le chiffre qui tranche**, dans le diagnostic : `selfScans`.

- Il valait **317** (téléphone) et **710** (tablette) — soit la moitié de
  `neoScans`. C'était le jeton de l'ami, jeté comme s'il était le nôtre.
- Attendu maintenant : **proche de zéro**.
- ⚠️ S'il est encore à ~50 % de `neoScans`, le jeton directionnel n'a pas pris,
  et le diagnostic l'écrira en toutes lettres (ligne `LECTURE`).

---

## Relevé 2 — un appareil ne doit plus en valoir six

**Même geste que le relevé 1.**

Attendu : au maximum **« Un appareil détecté »**, et le chiffre ne doit plus
sauter d'une seconde à l'autre.

Si le compte dépasse 2 avec un seul autre téléphone en face : **noter le chiffre
dans la note du rapport**. C'est la seule chose que le diagnostic ne sait pas
mesurer tout seul.

---

## Relevé 3 — le mode d'émission ⭐

**C'est la mesure qu'on attend depuis le 2026-08-20** (`RAPPELS.md` #54) : on ne
savait pas ce que les appareils acceptent, et la sonde n'atteignait aucun
rapport. Elle y est maintenant.

**Rien à faire** : ping activé, puis envoyer le rapport. Trois lignes nouvelles :

| Ligne | Ce qu'elle dit |
|---|---|
| `advertMode` | `parallele` = tous les jetons en l'air en même temps ⭐ · `cycle` = le repli s'est déclenché |
| `multipleAdvertisement` | ce que la puce **annonce** savoir faire |
| `advertTokensPerSlot` | combien de jetons sont à crier |

⚠️ **`cycle` n'est pas une panne** : c'est une réponse. Elle voudra dire que
l'appareil refuse les annonces simultanées, et le rapport dira alors le coût
exact (« chacun n'est en l'air qu'environ N % du temps »). **Envoyer le rapport
tel quel dans les deux cas.**

---

## Relevé 4 — le bandeau qui clignotait

**Geste** : ping activé, rester **30 secondes** sur l'écran Ping sans rien faire.

Attendu : **aucun** bandeau « Tu n'es pas annoncé » qui apparaît et disparaît. Il
clignotait deux fois et demie par seconde.

S'il apparaît **et reste**, c'est un vrai refus du système — et là il faut le
signaler, parce que ce n'est plus le même problème.

---

## Relevé 5 — le ping v2, la vraie cible ⭐⭐

**C'est le test qui compte.** Aucune rencontre n'a jamais été produite par cette
chaîne : la table des paires est à **zéro** depuis le début du chantier.

**Geste, dans l'ordre** :

1. Ping activé des deux côtés, les deux appareils **au même endroit**.
2. Regarder la section *Autour de toi* (celle du haut, sans « ancien chemin »).
3. S'il y a un bandeau sur la position : appuyer sur **« Autoriser la position
   précise »**. ⚠️ Ce bouton a changé — il **redemande** à Android au lieu de
   renvoyer vers des réglages où il n'y avait rien à trouver.
4. **Attendre deux minutes.** Chaque appareil republie toutes les 60 s, et il
   faut que les deux aient déposé pour que la rencontre naisse.

Attendu : **l'autre apparaît avec son nom** dans *Autour de toi*.

**Ce que tu peux lire toi-même**, section *POSITION — CE QU'ANDROID A ACCORDÉ* :

| Ligne | Attendu |
|---|---|
| `service actif` | `true` |
| `blocage` | `aucun` |
| `finesse` | `precise` — et si c'est `approximate`, ce n'est plus bloquant |
| `carreau` | `carreau(x, y) ± N m` — **si N dépasse ~500, c'est là qu'est le problème** |

**Le chiffre qui tranche est en base**, et je le lirai : le jour où la table des
paires contient **une ligne**, la chaîne est validée. Dis-moi simplement quand
le test est fait.

---

## Relevé 6 — la position approximative (si le temps le permet)

**Geste** : réglages Android → NeoVibe → Position → passer sur
**« Approximative »**, revenir dans l'app.

Attendu : un bandeau qui **s'ajoute** à la liste **sans la remplacer** — la
découverte continue de tourner, en moins bien. Avant, c'était un mur qui
empêchait toute publication.

---

## Ce qu'il faut envoyer

**Un rapport depuis CHAQUE appareil** (Réglages → Développeur → *Tout envoyer*),
avec dans la note :

1. le **numéro du relevé** ;
2. ce que tu as **vu à l'écran**, dans tes mots ;
3. le **chiffre** si le relevé en demande un (relevé 2).

> ⚠️ Deux rapports envoyés à la même minute sans note ne se distinguent plus.
> C'est arrivé le 2026-08-26 : c'est la note qui a permis de savoir lequel était
> la tablette et ce qu'elle affichait.

## Relevé A — l'étiquette de proximité ne doit pas clignoter

**Ce qui est en cause** : le lissage du RSSI et l'hystérésis. Ils existent et
sont testés en unitaire, mais **jamais sur du signal réel** — et le bruit d'une
vraie pièce ne ressemble à aucun bruit simulé.

**Protocole**

1. Les deux appareils visibles, à **2 mètres**, posés et immobiles.
2. Ouvre **Diagnostic proximité** sur l'un des deux.
3. Ne touche à rien pendant **2 minutes**.
4. Note ce que tu vois : est-ce que la bande change ? combien de fois ?

**À envoyer** — note : `relevé A · 2 m immobile · 2 min · N changements`

**Ce que le rapport doit montrer** : un RSSI lissé stable, et **zéro** bascule
de bande. Une seule bascule sur deux minutes immobiles suffit à condamner les
seuils actuels.

## Relevé B — la marche d'approche

**Ce qui est en cause** : la tendance (« se rapproche / s'éloigne ») et les
bandes de distance. C'est le relevé qui décidera si on peut afficher autre chose
qu'une étiquette figée.

**Protocole**

1. Un appareil posé sur une table, visible. L'autre dans ta main.
2. Pars à **10 mètres**, hors de vue directe si possible.
3. Approche-toi **lentement et régulièrement** jusqu'à toucher le premier.
4. Attends 10 s, puis repars à 10 m au même rythme.
5. Recommence **trois fois**.

**À envoyer** — note : `relevé B · marche 10 m ↔ contact · 3 aller-retours`

**Ce que le rapport doit montrer** : un RSSI qui monte et descend de façon
lisible, des bandes qui changent **dans le bon ordre**, et une tendance qui
suit le mouvement sans s'inverser à contretemps.

⚠️ **Fais-le une fois en intérieur et une fois dehors.** Les murs changent tout :
c'est la comparaison des deux qui dira si des mètres sont envisageables ou si
seules des bandes le sont.

## Relevé C — le corps humain

**Ce qui est en cause** : la plus grosse source d'erreur, et celle qu'on ne peut
pas corriger. Un corps entre deux téléphones absorbe 10 à 20 dB.

**Protocole**

1. Deux appareils à **3 mètres**, immobiles, en vue directe.
2. Relève la bande affichée.
3. **Mets-toi entre les deux**, sans bouger les appareils. Attends 15 s.
4. Relève à nouveau.

**À envoyer** — note : `relevé C · 3 m · avant/après interposition`

**Ce que ça décidera** : si l'étiquette change alors que **rien n'a bougé**,
c'est la preuve chiffrée qu'une distance en mètres serait fausse — et la
question de l'afficher sera close.

## Relevé D — le délai de grâce au départ

**Ce qui est en cause** : les 25 secondes avant qu'un pair disparaisse.

**Protocole**

1. Les deux visibles, côte à côte.
2. Emporte l'un des deux **dans une autre pièce**, porte fermée.
3. Chronomètre : au bout de combien de temps disparaît-il de la liste ?
4. Reviens : au bout de combien de temps réapparaît-il ?

**À envoyer** — note : `relevé D · départ pièce fermée · disparu à Xs · revenu à Ys`

**Ce que le rapport doit montrer** : une disparition **autour de 25 s**, pas
immédiate. Un pair qui s'efface en 3 s clignoterait à chaque annonce manquée ;
un pair qui reste 2 minutes ment sur qui est là.

---

## Le relevé de la campagne complète, plus tard

Jay veut refaire, **sur une base propre**, le parcours entier d'inconnu à ami en
conditions pseudo-réelles — **après** la refonte de l'interface. À ce
moment-là :

- **repartir de zéro** : désinstaller sur les deux appareils (le carnet de clés
  et le journal du ping sont des fichiers locaux qui survivent à une mise à
  jour), et supprimer la connexion `Charles ↔ mimi` en base ;
- sans quoi les deux comptes se reconnaîtront **silencieusement** et le parcours
  « inconnu → révélation → demande d'ami » ne sera **jamais** exercé — il ne l'a
  d'ailleurs encore jamais été.

⚠️ C'est le seul morceau du système qui n'a **jamais** tourné entre deux vrais
appareils. Tout ce qui a été validé aujourd'hui l'a été entre deux comptes déjà
amis.
