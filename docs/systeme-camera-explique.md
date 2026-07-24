# Le système caméra de NeoVibe, expliqué de zéro

> Document pédagogique. Objectif : que tu comprennes **comment marche la caméra
> de NeoVibe**, en particulier le fameux « double flux » (les deux caméras en
> même temps), **sans supposer aucune connaissance technique préalable**. On part
> vraiment de zéro, avec des images et des analogies. Les termes techniques sont
> expliqués la première fois qu'ils apparaissent, et repris dans un glossaire à
> la fin.

---

## 1. Ce qu'on essaie de faire (et pourquoi c'est dur)

NeoVibe a un type de carte appelé **Oneshot**. L'idée produit est forte : on
capture **les deux faces en même temps** — ce que tu vois (caméra arrière) ET ta
réaction (caméra avant, ton visage), au **même instant**. C'est ça qui fait la
valeur : impossible de tricher, de préparer sa tête, de refaire la prise. Un seul
instant, deux points de vue, simultanés.

Le problème : **un téléphone n'est pas conçu pour filmer avec ses deux caméras en
même temps.** La plupart des téléphones ouvrent une caméra à la fois. Quand
l'appli photo du constructeur (celle de Xiaomi sur ton Redmi, par exemple) fait
du « double », elle utilise des passages privés réservés au constructeur,
**inaccessibles aux autres applications**. Nous, application tierce, on n'a droit
qu'aux portes publiques d'Android — et ces portes disent souvent « non » au
double, même quand le matériel, lui, en serait capable.

Toute la difficulté du chantier caméra a été de **forcer poliment cette porte** :
obtenir les deux caméras en même temps alors qu'Android annonce que ce n'est pas
possible, **sans faire planter le téléphone**.

---

## 2. Le vocabulaire de base (à lire une fois)

Quelques mots reviennent partout. Voici les images mentales à garder :

- **Le capteur (sensor).** La petite puce derrière chaque objectif qui
  transforme la lumière en image. Un téléphone a plusieurs capteurs : au moins un
  à l'arrière, un à l'avant.

- **Une image / une « frame ».** Une photo unique. Une vidéo fluide, c'est
  simplement beaucoup d'images qui défilent : 30 images par seconde donne une
  impression de mouvement fluide.

- **Les FPS (images par seconde, « frames per second »).** Le nombre d'images
  affichées chaque seconde. Plus il est élevé, plus c'est fluide. 30 FPS = fluide,
  15 FPS = un peu saccadé, 5 FPS = diaporama. **C'est le cœur du problème n°1** de
  ce document.

- **Un flux (stream).** Un « tuyau » continu d'images qui sort d'une caméra.
  Quand tu vois l'aperçu à l'écran, il y a un flux qui coule du capteur vers ton
  écran. Retiens ce mot : **la contrainte centrale de tout le système, c'est le
  nombre de flux qu'on a le droit d'ouvrir.**

- **L'aperçu (preview).** L'image en direct affichée à l'écran avant que tu
  déclenches. Ce n'est pas encore une photo enregistrée, juste le flux qui coule
  en temps réel.

- **CameraX et Camera2.** Deux façons, dans Android, de parler à la caméra.
  - **Camera2** est le niveau « brut », bas niveau : puissant mais compliqué et
    plein de pièges (chaque téléphone se comporte différemment).
  - **CameraX** est une couche par-dessus, plus simple et plus sûre, qui gère à
    notre place des tonnes de détails pénibles (orientation, mise au point,
    encodage vidéo…). **On utilise CameraX partout où on peut**, et on ne descend
    au Camera2 brut **que** pour le double flux (le seul endroit où CameraX nous
    bloque artificiellement). C'est une décision d'architecture importante : ne
    pas tout réécrire en Camera2, ce serait multiplier les bugs.

- **Le HAL (couche d'abstraction matérielle).** Le logiciel intermédiaire, fourni
  par le constructeur, qui se trouve entre Android et l'électronique de la caméra.
  Quand on dit « le matériel accepte » ou « le matériel refuse », c'est en réalité
  ce HAL qui décide. Point crucial : **il peut dire « oui » puis ne rien livrer.**
  On y revient.

- **Une texture.** Une zone mémoire où on dépose une image pour que l'écran
  l'affiche. Quand Flutter (la partie « interface » de l'app) montre l'aperçu, il
  affiche en réalité une **texture** qu'on remplit d'images caméra.

- **Le service caméra d'Android.** Un programme d'Android, séparé de notre app,
  qui gère l'accès aux caméras pour toutes les applications. **On peut le faire
  tomber** si on le brutalise — et là, plus aucune caméra ne marche jusqu'au
  redémarrage de l'app. C'est arrivé, et ça a beaucoup guidé la conception.

---

## 3. Les deux « moteurs » caméra de l'app

NeoVibe utilise **deux moteurs** selon la situation :

| Situation | Moteur utilisé | Pourquoi |
|---|---|---|
| Photo/vidéo normale, une caméra à la fois (Mono, recto, verso, aperçu simple) | **CameraX** | Simple, fiable, gère tous les cas tordus par appareil |
| Double live Oneshot (les deux caméras ensemble) | **Camera2 brut** (`Camera2Dual.kt`) | CameraX refuse le double ; on contourne au niveau brut |

**Une seule pile caméra tourne à la fois.** Quand on ouvre le double flux, on
ferme d'abord complètement CameraX (et on **attend** qu'il ait vraiment rendu le
matériel) ; quand on quitte le double flux, on ferme Camera2 et on rouvre
CameraX. Deux moteurs qui toucheraient les caméras en même temps = conflit
garanti.

---

## 4. Le cœur du sujet : pourquoi « un seul flux par caméra »

C'est **la** contrainte qui explique presque tout le reste. Elle a été
**mesurée** sur ton Redmi Note 10 Pro (pas devinée), grâce à un journal de
diagnostic qui écrivait tout sur le disque du téléphone.

Voici ce qu'on a appris, dans l'ordre :

1. **Le téléphone accepte d'ouvrir les deux caméras** en même temps, à condition
   de ne demander **qu'un seul flux par caméra** (un seul tuyau d'images chacune),
   en résolution 720p. Les deux capteurs livrent alors des images en parallèle.
   ✅

2. **Si on demande deux flux par caméra** (par exemple : un flux pour l'aperçu +
   un flux séparé pour la photo), le matériel **fait semblant d'accepter** : la
   configuration passe, la demande est acceptée… puis la caméra avant ne livre
   **aucune image**. On appelle ça un **flux affamé** (« starved »). C'est le
   piège du HAL évoqué plus haut : **une configuration qui réussit ne prouve
   rien ; seules les images réellement reçues font foi.**

3. **Reconfigurer une caméra pendant que l'autre tourne casse tout.** Pire : un
   essai raté peut **tuer le service caméra d'Android**. Symptôme observé :
   ensuite `cameraIdList` (la liste des caméras) revient **vide**, et plus aucune
   caméra ne s'ouvre jusqu'au redémarrage de l'app. C'était la cause des « écrans
   noirs » et « chargements infinis » qui ont coûté plusieurs versions.

**Conclusion, gravée dans le code :**

> On n'a droit qu'à **UN seul flux par caméra**, ouvert **UNE seule fois**, et on
> ne **reconfigure jamais** rien ensuite. On ne « sonde » plus le matériel au
> moment de s'en servir : un test raté est trop dangereux.

---

## 5. L'astuce centrale : un flux qui sert à la fois d'aperçu ET de photo

On vient de le voir : on ne peut avoir **qu'un seul flux par caméra**. Or on veut
**deux choses** de chaque caméra : afficher l'aperçu en direct **et** prendre la
photo. Comment faire les deux avec un seul tuyau ?

**L'idée maligne :** ce flux unique déverse en continu des images brutes dans une
petite boîte mémoire (un composant appelé **ImageReader**). Et on fait **tout**
avec ce même flot d'images :

- **L'aperçu** = on prend chaque image qui arrive, on la retourne dans le bon sens,
  et on la **dessine** dans la texture affichée à l'écran. C'est l'aperçu en
  direct.

- **La photo** = c'est tout simplement **la dernière image reçue**. Au moment où
  tu déclenches, on garde la dernière image de la caméra arrière et la dernière
  image de la caméra avant. Comme les deux flux coulent en parallèle, ces deux
  images sont **du même instant** → capture **vraiment simultanée**, et
  **instantanée** (on ne redemande rien à la caméra, on prend ce qu'on a déjà).

C'est élégant : plus jamais besoin de reparler au service caméra après
l'ouverture. Rien ne peut plus le casser. **Mais cette astuce a un prix**, et
c'est exactement le problème n°1 des FPS. On y arrive au chapitre 7.

---

## 6. Le déroulé complet d'une session double flux

Voici, étape par étape, ce qui se passe quand tu appuies sur « Double live » :

1. **Fermer CameraX** et **attendre** qu'il ait vraiment rendu le matériel. (Si
   on rouvre trop tôt, on retombe sur « 0 caméra ».)

2. **Vérifier que le service caméra est vivant** : si la liste des caméras est
   vide, on ne tente même rien (le service est tombé).

3. **Ouvrir la caméra arrière, seule d'abord.** Puis **attendre les premières
   images** — pas « attendre 600 ms », mais **attendre le fait** que des images
   arrivent réellement. (Une caméra froide peut mettre plus d'une seconde à
   démarrer. Un délai fixe trop court annonçait « appareil non compatible » à
   tort — c'était un vrai bug remonté.)

4. **Ouvrir ensuite la caméra avant.** (Ouvrir les deux exactement en même temps
   fait « évincer » la première : il faut les mettre en route l'une après
   l'autre.)

5. **Vérifier que les DEUX livrent des images en même temps** pendant un court
   instant. Si l'une s'affame → échec propre, on referme tout et on revient à la
   vue simple. Aucun état « zombie » laissé derrière.

6. **Ça tourne :** les deux aperçus s'affichent (l'un en grand, l'autre en
   vignette dans le coin — tu peux échanger d'un tap).

7. **Tu déclenches :** on prend les deux dernières images, on les enregistre en
   parallèle, on les recadre au format des cartes. Fini.

8. **Tu quittes :** on ferme Camera2, on **attend la confirmation** que le
   matériel est rendu, puis CameraX peut reprendre.

Chaque « attendre » ici n'est pas de la prudence excessive : chacun corrige un
bug précis qui a réellement eu lieu.

---

## 7. Pourquoi le double live est moins fluide que l'appli native (problème des FPS)

C'est **le** point que tu as ressenti : le double live marche, mais il est moins
fluide que l'appli caméra de ton téléphone. Il y a **deux causes distinctes**, et
il est important de les séparer.

### Cause A — le capteur n'est pas forcé à tourner vite

Chaque caméra a une **plage de vitesse** (par exemple « entre 15 et 30 images par
seconde »). Par défaut, l'auto-exposition d'Android est libre de choisir le bas
de la plage — surtout **en intérieur**, où elle ralentit le capteur pour laisser
entrer plus de lumière (image plus claire, mais plus saccadée). Résultat : en
intérieur, le capteur peut se contenter de 15 images/s alors qu'il pourrait en
faire 30.

L'appli native, elle, **force** explicitement la plage haute. Nous, pour
l'instant, on ne le fait pas. → **C'est un réglage à ajouter**, à faible risque,
et c'est probablement le gain le plus direct.

### Cause B — on dessine l'aperçu « à la main » (logiciel), pas via la carte graphique (matériel)

C'est la conséquence de l'astuce du chapitre 5, et c'est plus fondamental.

- L'**appli native** envoie le flux caméra **directement à l'écran via la puce
  graphique (GPU)**. C'est le chemin « matériel » : ultra rapide, quasiment gratuit
  en énergie de calcul. Le processeur principal (CPU) n'a presque rien à faire.

- **Nous**, on ne peut pas faire ça, parce qu'on n'a droit qu'à **un seul flux
  par caméra** et qu'on a réservé ce flux à un format « brut » (pour pouvoir en
  extraire la photo). Du coup, pour chaque image, on doit la **transformer nous-
  mêmes, avec le processeur** : convertir son format, la retourner, la redimen-
  sionner, la dessiner. Et ça, **pour les deux caméras à la fois**. Le processeur
  n'arrive à traiter qu'un certain nombre d'images par seconde → on **saute** les
  images en trop → l'aperçu paraît moins fluide.

Autrement dit : **le natif fait faire le travail à la carte graphique ; nous, on
le fait faire au processeur, parce que c'est le seul moyen d'avoir aussi la photo
avec un flux unique.** C'est un **compromis assumé**, pas un oubli.

> **Ce qu'il faut retenir honnêtement :** tant qu'on est contraints à un seul flux
> par caméra, on **ne pourra pas égaler** la fluidité de l'appli native, qui a
> accès aux passages privés du constructeur. On peut **s'en rapprocher** (forcer
> la vitesse du capteur, alléger le travail de dessin, ne dessiner que l'aperçu
> visible et pas la vignette cachée), mais il restera un écart structurel.

---

## 8. Le Oneshot « normal » (vue simple) et pourquoi les deux prises ne sont pas simultanées

Quand le double live **n'est pas** activé (le mode par défaut, celui qui marche à
tous les coups), le Oneshot fonctionne autrement : il n'a **qu'une seule caméra
ouverte** à la fois. Alors il fait :

1. Photographier avec la caméra **arrière**.
2. **Basculer** de caméra (fermer l'arrière, ouvrir l'avant) — c'est
   l'opération lente : plusieurs centaines de millisecondes.
3. Photographier avec la caméra **avant**.

Entre l'étape 1 et l'étape 3, il s'écoule donc un **délai visible** (le temps de
la bascule). C'est ce que tu as remarqué : l'écart est **assez grand pour
tricher** — changer ce qu'on montre, refaire sa tête. Ce n'est plus vraiment
« un seul instant ».

**Et c'est structurel** : avec **une seule caméra** ouverte, il est **impossible**
de capturer les deux faces au même moment. La simultanéité exige que **les deux
caméras soient ouvertes en même temps** — c'est-à-dire… le double flux du chapitre
5. La vraie capture simultanée n'existe donc aujourd'hui **que** dans le double
live.

→ D'où la question qui reste à trancher au niveau produit : faut-il que le
Oneshot **ouvre par défaut les deux caméras** (pour garantir la simultanéité),
quitte à n'afficher qu'une face à l'aperçu pour garder de la fluidité ? C'est un
arbitrage entre **simultanéité garantie** et **simplicité/robustesse du mode par
défaut**.

---

## 9. La grande leçon du chantier (l'histoire en bref)

Ce système n'est pas né d'un coup. Il a fallu **9 versions** (v0.7 → v0.9.2) et
beaucoup d'essais ratés. Les leçons, utiles bien au-delà de la caméra :

1. **Instrumenter AVANT de corriger.** On a perdu trois versions à corriger « à
   l'aveugle » des symptômes vus à l'œil (« c'est noir », « ça plante »). Dès
   qu'on a écrit un **journal** qui note tout sur le disque du téléphone (et qui
   **survit même à un plantage**), la cause a sauté aux yeux en une lecture.

2. **Une configuration qui réussit ne prouve rien.** Sur Camera2, la caméra peut
   accepter une demande puis ne rien livrer. **Seules les images réellement
   reçues** font foi.

3. **Ne jamais tester le matériel au moment de s'en servir.** Un essai raté peut
   tuer le service caméra d'Android jusqu'au redémarrage de l'app. On a donc figé
   **une seule configuration**, celle qui marche, ouverte une seule fois.

4. **Attendre un fait, jamais un chronomètre.** « 0 image après 600 ms » annonçait
   un faux échec : la caméra mettait parfois près d'une seconde à démarrer. On
   attend désormais que **les images arrivent**, pas que le temps passe.

5. **Une décision se fige au moment de l'acte.** Le type d'une carte (Oneshot,
   Mono…) est décidé **au déclenchement**, pas relu après coup — sinon on
   fabriquait des objets impossibles (une carte Mono avec deux faces, bug réel).

---

## 10. Glossaire express

- **Capteur (sensor)** : la puce qui transforme la lumière en image.
- **Image / frame** : une photo unique ; une vidéo = beaucoup d'images à la suite.
- **FPS** : images par seconde ; mesure la fluidité (30 = fluide, 15 = saccadé).
- **Flux (stream)** : un tuyau continu d'images sortant d'une caméra. **On n'a
  droit qu'à un seul par caméra en double.**
- **Aperçu (preview)** : l'image en direct à l'écran, avant de déclencher.
- **CameraX** : la façon simple et sûre de parler à la caméra (utilisée partout
  sauf le double flux).
- **Camera2** : la façon brute et puissante (utilisée seulement pour le double
  flux, là où CameraX bloque).
- **HAL** : le logiciel du constructeur entre Android et l'électronique caméra ;
  il peut dire « oui » puis ne rien livrer.
- **ImageReader** : la petite boîte mémoire où le flux brut dépose ses images ;
  on y puise l'aperçu ET la photo.
- **Texture** : la zone mémoire où on dépose une image pour que l'écran l'affiche.
- **Rendu logiciel / matériel** : dessiner l'image avec le **processeur (CPU)**
  (ce qu'on fait, plus lent) ou avec la **carte graphique (GPU)** (ce que fait le
  natif, plus rapide).
- **Flux affamé (starved)** : une caméra qui accepte la demande mais ne livre
  aucune image.
- **Service caméra** : le programme d'Android qui gère les caméras ; fragile, on
  peut le faire tomber.
- **Éviction** : quand ouvrir une deuxième caméra « éjecte » la première.

---

*Document maintenu au fil du chantier caméra. Si le système évolue (par exemple :
Oneshot simultané par défaut, ou amélioration des FPS), mettre ce fichier à
jour.*
