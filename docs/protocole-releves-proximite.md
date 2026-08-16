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
