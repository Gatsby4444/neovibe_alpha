# NeoVibe — comment ça marche

*Le guide des règles de l'app, écrit pour les gens qui l'utilisent.*

> **⚠️ Note pour l'équipe, à retirer avant publication.** Ce document décrit
> **ce que le code fait réellement au 2026-08-27**, vérifié dans le code et en
> base — pas ce qu'on aimerait qu'il fasse. Chaque chiffre est relevé à la
> source. Les fonctionnalités non construites sont dans la dernière section,
> séparées du reste : un guide qui promet ce qui n'existe pas est pire qu'un
> guide absent. **Tenir ce fichier à jour à chaque changement de règle.**

---

## L'idée en une phrase

NeoVibe est un réseau social où **on ajoute les gens qu'on a vraiment
rencontrés**. Pas de recherche par nom, pas d'annuaire, pas de suggestions
d'inconnus : pour ajouter quelqu'un, il faut avoir été **physiquement à côté de
lui** — ou qu'un ami commun vous présente.

---

## 1. Devenir amis

Il y a **deux chemins, et seulement deux**.

> ⚠️ **Se parler ne suffit pas, et ne suffit plus.** Jusqu'au 28 août 2026, une
> troisième porte existait sans que personne ne la demande : dès que deux
> inconnus avaient échangé un message, l'app leur proposait de « confirmer la
> connexion ». Elle a été supprimée — deux portes vers la même chose, avec deux
> délais différents. **Discuter avec quelqu'un ne crée aucun lien** : il faut le
> demander, et l'autre doit accepter.

### a) Vous vous êtes croisés

Vos deux téléphones doivent s'être vus **en même temps, au même endroit**. Ce
n'est pas une question de « à peu près au même moment » : le serveur exige que
**chacun des deux** ait constaté l'autre. Si tu écoutes sans t'annoncer, tu
n'apparais chez personne — et personne n'apparaît chez toi.

Une fois que c'est constaté, tu as **10 minutes** pour envoyer une demande.

### b) Un ami commun vous présente

Quand une rencontre physique est impossible, un ami commun peut faire la
présentation. La demande voyage alors de toi → l'ami commun → la personne.

> **⚠️ À compléter avec Jay** : le plafond mensuel de recommandations est une
> décision produit inscrite dans `CLAUDE.md` (10 par mois), mais **je ne l'ai
> pas retrouvé dans le code au 2026-08-27**. À vérifier avant de l'écrire ici.

### La demande

Une demande envoyée **reste valable 7 jours**.

> **Tu peux répondre plus tard, même si la personne est repartie.** C'était
> impossible avant le 27 août 2026 : la réponse voyageait par Bluetooth, donc il
> fallait être de nouveau côte à côte. Ce n'est plus le cas — une demande reçue
> t'attend dans « Demandes & rencontres ».

Trois choses à savoir :

- **Insister ne sert à rien, et ne casse rien.** Redemander à quelqu'un qui n'a
  pas encore répondu ne crée pas une deuxième demande. Le bouton te montre où
  ça en est : un sablier veut dire « envoyée, en attente ».
- **Un refus se voit.** Si la personne dit non, le bouton te le dit — au lieu de
  te laisser croire que la demande s'est perdue.
- **Après un refus, tu peux redemander.** C'est autorisé.

---

## 2. Le ping — qui est autour de toi

Le ping se coupe et s'allume avec l'interrupteur **« Visible à proximité »**.
Éteint, tu ne vois personne et personne ne te voit.

### Ce que voit ton téléphone

| Qui | Comment | Ce que tu vois en plus |
|---|---|---|
| **Tes amis** | reconnus directement par le Bluetooth, **sans internet** | une **distance** (« tout près », « il se rapproche ») |
| **Les inconnus** | par le serveur, une fois la proximité prouvée des deux côtés | leur profil, sans distance |

### Comment on trouve les gens, en deux étapes

1. **Ta position sert à savoir dans quel quartier chercher.** Elle est arrondie
   à une case d'environ **1 km**. Ça ne sert qu'à ça — le serveur ne t'envoie
   jamais la distance ni la direction de qui que ce soit.
2. **C'est le Bluetooth qui prouve que vous êtes vraiment côte à côte** —
   environ **20 mètres**. Sans lui, rien n'est confirmé.

Entre les deux, le serveur applique un **rayon de 300 mètres au minimum**. S'il
sait mal où vous êtes, ce rayon s'élargit automatiquement de l'incertitude des
deux téléphones — sinon deux personnes réellement côte à côte pourraient ne
jamais se voir, juste parce que le GPS s'est trompé.

> **⚠️ Si tu n'autorises que la position approximative**, Android répond à
> environ 3 km près : la découverte d'inconnus ne fonctionne alors **pas du
> tout**, pas même mal. L'app te le dit avec un bandeau.

### Ton identité pendant le ping

Ton téléphone n'émet **jamais ton nom ni ton compte**. Il émet un identifiant qui
**change toutes les 15 minutes**, et que personne ne peut relier à toi sans être
physiquement là et sans que le serveur ne l'ait confirmé des deux côtés.

Pour tes amis, c'est encore plus fermé : le code que ton téléphone crie **pour un
ami donné** n'est lisible que par **lui**. Tes autres amis ne le comprennent pas.

### Quand quelqu'un disparaît de l'écran

Il reste affiché **une dizaine de secondes** après le dernier signe de vie.
C'est voulu : le Bluetooth perd des signaux en permanence, et une porte qui
s'ouvre suffit à couper le contact une seconde. Sans ce délai, les gens
clignoteraient.

Ton téléphone en juge **tout seul** : il entend l'autre, ou il ne l'entend plus.
Il ne demande rien au serveur pour ça — c'est ce qui rend le ping économe en
batterie et en données.

---

## 3. S'écrire

| Avec qui | Où ça se passe |
|---|---|
| **un ami** | votre conversation habituelle |
| **un inconnu prouvé à côté de toi** | une conversation de proximité, ouverte depuis l'écran Ping |

Les messages disparaissent au bout de **24 heures**.

### La conversation de proximité se ferme quand vous vous quittez

Elle n'existe **que tant que vous êtes ensemble**. Dès que vous vous séparez,
elle passe en **lecture seule** : tu peux relire ce qui s'est dit, tu ne peux
plus écrire. Si vous vous recroisez, elle se rouvre.

Et **24 heures après le dernier message**, quand il n'y a plus rien dedans, elle
disparaît de ta liste.

> **Pourquoi** : ce n'est pas une messagerie, c'est une conversation de moment.
> Pour continuer à se parler après, il faut s'ajouter en ami — et c'est
> exactement le choix que l'app te demande de faire.

---

## 4. Les « presque »

Quand un ami passe tout près de toi sans que vous vous croisiez vraiment, l'app
te le dit : **« Le presque… — X est passé tout près de toi »**.

- **Le délai dépend de votre palier d'amitié** (voir la section suivante) :
  tout de suite pour un **Inséparable**, 15 minutes pour un **Proche**,
  45 minutes pour un **Ami**. Te prévenir en direct pour tout le monde te
  ferait courir après les gens toute la journée.
- Tu peux forcer le **temps réel pour tout le monde** dans les réglages : ce
  choix-là l'emporte toujours sur le palier.
- **Une seule par personne toutes les 2 heures** — sinon un ami dans le même
  bâtiment que toi te notifierait toute la journée.

---

## 5. Les croisements

Quand deux amis se croisent, l'app l'enregistre — c'est ce qui alimentera les
**streaks de proximité**.

- Un croisement n'existe que si **les deux téléphones se sont vus**. Un seul ne
  suffit pas : c'est ce qui empêche quelqu'un de te suivre sans que tu le saches.
- Il faut un contact **continu**, pas une apparition d'une seconde — sinon
  chaque passant deviendrait une rencontre.
- Les croisements sont oubliés au bout de **24 heures**.

---

## 5 bis. Les paliers d'amitié

Tes amis ne sont pas tous au même niveau, et **ce n'est pas toi qui les ranges**.
L'app compte simplement les jours où vous vous êtes croisés pour de vrai.

| Palier | Comment on y arrive |
|---|---|
| **Ami** | dès que vous êtes connectés |
| **Proche** | vous vous êtes croisés **5 jours** sur les **30 derniers** |
| **Inséparable** | **15 jours** sur les **30 derniers** |

- **Ça redescend aussi.** La fenêtre de 30 jours avance chaque nuit : si vous
  cessez de vous voir, le compte baisse et le palier retombe. Une amitié se
  garde, elle ne se gagne pas une fois pour toutes.
- **Un croisement ne compte que s'il est mutuel.** Les deux téléphones doivent
  s'être vus. Personne ne peut faire monter un palier en te suivant.
- **Un seul croisement par jour compte.** Passer la journée à côté de quelqu'un
  ne vaut pas dix jours.
- À partir de **Proche**, un **anneau de couleur** entoure la photo de la
  personne.

### Ce que ça change

- **Les stories réservées** : tu peux publier une story que seuls tes Proches
  ou tes Inséparables verront.
- **La vitesse du « presque »** : tu es prévenu tout de suite pour un
  Inséparable, plus tard pour les autres.
- *(À venir : seuls tes Proches pourront t'envoyer un Rush.)*

### La série

En plus du palier, chaque ami a une **série** : le nombre de jours d'affilée où
vous vous êtes croisés. Elle survit à **deux jours** manqués — un week-end ne la
casse pas — et elle fait évoluer un emoji, de l'œuf 🥚 au diamant 💎.

⚠️ **Notre série ne se garde pas en publiant, elle se garde en se voyant.**
C'est toute la différence avec les autres apps.

> **Ces chiffres sont provisoires.** Ils n'ont encore été confrontés à aucun
> usage réel et seront ajustés. Les règles exactes, et où elles se changent,
> sont dans `docs/paliers-d-amitie.md`.

---

## 6. Ce qui disparaît, et quand

| Quoi | Durée de vie |
|---|---|
| Un message | 24 heures |
| Une story | 24 heures |
| Une Vibe | 24 heures |
| Un croisement | 24 heures |
| Le **jour** où vous vous êtes croisés | gardé — c'est ce qui porte les paliers et les séries |
| Une demande d'ami | **7 jours** |
| Une recommandation | 14 jours |
| Ta position sur le serveur | **15 minutes** |

---

## 7. Ta vie privée

**Ce que le serveur sait :** ton profil, tes amis, tes conversations, et — tant
que le ping est allumé — ta position, effacée au bout de **15 minutes**.

**Ce qu'il ne fait pas :** il ne t'envoie jamais la distance ni la direction de
quelqu'un. C'est délibéré. Une app qui répond « cette personne est à 43 mètres »
permet à quelqu'un de mentir trois fois sur sa position et d'en déduire ton
adresse. NeoVibe ne rend jamais ce chiffre.

**Ce que les autres voient de toi :**

- **Tes amis** : ton profil, tes stories, ta présence à proximité.
- **Quelqu'un que tu viens de croiser** : ton profil, le temps que l'app garde le
  croisement.
- **Tout le monde d'autre** : rien.

### Les captures d'écran

L'app rend les captures **coûteuses et visibles** — elle ne prétend pas les
rendre impossibles. Personne ne peut honnêtement le promettre : il restera
toujours un deuxième téléphone pour photographier le premier. Ce qu'on garantit,
c'est que ce n'est ni discret ni gratuit.

---

## 8. Ce qui n'existe pas encore

Écrit ici pour ne rien promettre qui ne soit construit, au **2026-08-27** :

- **Les streaks de proximité** — les croisements sont enregistrés, la mécanique
  de paliers et de couleurs reste à faire.
- **Le feed local** (ta ville, ta région) — décidé, pas construit.
- **Les quiz et mini-jeux entre amis** — décidés, pas construits.
- **Le ping quand l'app est fermée** — le croisement entre amis fonctionne app
  fermée ; la découverte d'inconnus s'arrête.
- **Les paliers de relation** — décidés le 28 août 2026, pas construits.
  Aujourd'hui il n'y a qu'un seul niveau : ami ou pas. Demain, des cercles à
  plusieurs paliers donneront accès à plus ou moins de choses sur quelqu'un.
  ⚠️ Ce chantier **ne touchera pas au ping** : le ping prouve une rencontre, il
  ne décide d'aucun palier.

---

## ⚠️ Deux points à trancher avant de publier ce guide

*(section interne — à retirer)*

1. **Retirer un ami ne coupe pas immédiatement son accès.** Vérifié en base le
   2026-08-27 en exécutant les fonctions : 13 heures après un retrait d'ami,
   l'ex-ami voyait **encore** le profil et les stories publiques, parce que la
   ligne de croisement lui survit jusqu'à 24 h. Tant que ce n'est pas tranché,
   **ne rien écrire ici sur le retrait d'ami**. Voir `RAPPELS.md` #77.
2. **Le plafond de recommandations** (10/mois dans `CLAUDE.md`) n'a pas été
   retrouvé dans le code. À vérifier avant de l'annoncer.
