# Protocole de test — v0.9.142

## L'état de départ, relevé en base le 2026-08-28

| | |
|---|---|
| Charles et mimi | **amis** |
| Blocage | aucun |
| Demande en attente | aucune |
| Croisements enregistrés | **0** (effacés par le blocage du test précédent) |
| Clés publiées | **2** — les deux appareils sont reconnaissables |
| Balises actives | 0 — le ping est coupé des deux côtés |

---

# Étape 0 — Installer la v0.9.142 sur les deux appareils

Rien d'autre à préparer.

---

# Test 1 🔴 — LE test de cette version

**Ce qu'on vérifie** : quand tu ajoutes un ami, il est reconnu **tout de suite**.

Avant, la liste de codes que ton téléphone crie n'était refaite qu'une fois par
heure. Un ami tout juste accepté n'y était donc pas — et **aucun croisement
n'était possible pendant jusqu'à une heure, des deux côtés.**

## ⚠️ La consigne la plus importante de tout ce protocole

> **NE TOUCHE PAS à l'interrupteur « Visible à proximité » pendant ce test.**

Le rebasculer refaisait la liste — c'est ce que tu faisais sans le savoir. Si tu
y touches, tu ne testeras rien : le défaut sera masqué exactement comme avant.

## Ce qu'il faut faire

1. Sur **les deux** téléphones, active « Visible à proximité » **une fois, au
   début**. Puis oublie cet interrupteur jusqu'à la fin.
2. Sur le téléphone de **Charles** : profil de mimi → **retirer l'ami**.
   Vous redevenez inconnus.
3. Restez **côte à côte**. Attendez que chacun voie l'autre dans
   **« Autour de toi »** (10 à 20 secondes).
4. **Demander en ami**, et **accepter** sur l'autre appareil.
5. **Restez côte à côte deux bonnes minutes, les deux apps ouvertes**, sans rien
   toucher.

## Ce qui doit se produire

- ✅ la personne apparaît dans la liste **avec une distance** (« Tout près »,
  « À portée de bras »…) — **en moins d'une minute**, pas en une heure ;
- ✅ elle **quitte** « Autour de toi » (cette section ne montre que des inconnus).

**Si tu ne vois aucune distance au bout de deux minutes, arrête-toi là et
dis-le-moi** : ce serait que le correctif n'a pas pris.

**Ce que je vérifierai en base** : des constats de croisement apparaissent
**dans les deux sens**, et une ligne de croisement se crée.

---

# Test 2 — Le chat de proximité se ferme vraiment

**Ce qu'on vérifie** : ce qui restait de ton dernier test. Tu pouvais encore
écrire alors que tu étais parti.

**Il faut être INCONNUS** — donc fais ce test **avant** le Test 1, ou refais un
retrait d'ami après.

1. Côte à côte, appuie sur **« Écrire »** sur la tuile de l'autre.
2. Échangez deux ou trois messages **dans les deux sens**.
3. **L'un s'éloigne d'une trentaine de mètres.** L'autre **reste dans le chat**.
4. Attends **15 secondes sans toucher l'écran**.

## Ce qui doit se produire

- ✅ un bandeau : **« Canal fermé — vous n'êtes plus à proximité »** ;
- ✅ 🔴 **le champ de saisie devient inerte, la flèche d'envoi disparaît** —
  c'est le point qui avait échoué ;
- ✅ les messages **restent lisibles** (fermer n'est pas effacer) ;
- ✅ **en revenant à portée, tu peux réécrire.**

Puis **devenez amis** et regarde le bandeau : il doit dire **« Vous êtes
connectés »**, et ne plus jamais parler de distance.

---

# Test 3 — Disparaître, et « Croisés récemment »

**Toujours en inconnus.** L'un s'éloigne (ou coupe son Bluetooth), l'autre
**regarde l'écran Ping sans y toucher**.

- ✅ il quitte « Autour de toi » en **~10 secondes** ;
- ✅ il **réapparaît dans « Croisés récemment »**, avec « Croisé il y a… » ;
- ✅ sur cette tuile, **pas de bouton « écrire »** — seulement « demander en
  ami » ;
- ✅ **au bout de 10 minutes, il disparaît de cette section aussi** (au-delà, le
  serveur refuserait la demande — inutile d'afficher un bouton qui dit non).

---

# Test 4 — Le diagnostic ne compte plus double

*Réglages → Développeur → Diagnostic proximité*, avec **un seul** téléphone en
face.

- ✅ le titre dit maintenant **« Personnes reconnues (1) · annonces anonymes
  (1) »** ;
- ❌ **plus** « Appareils vus (2) » pour un seul téléphone.

**Pourquoi (1) et (1)** : un appareil crie **deux codes** — un pour ses amis, un
pour les inconnus — et il est **impossible** de savoir qu'ils viennent du même
téléphone. C'est voulu : c'est ce qui empêche qu'on te suive. On ne peut pas
corriger le compte, alors on dit ce qu'il compte.

---

# Test 5 — La nuit (le plus long, à faire en dernier)

**Ce qu'on vérifie** : que le croisement continue même si Android range l'app
pendant la nuit.

1. Vous êtes **amis** (après le Test 1).
2. Les deux téléphones **côte à côte**, ping actif, **apps fermées** (bouton
   accueil, pas balayées).
3. **Laisse-les ainsi toute la nuit.**
4. Le matin, **avant de rouvrir l'app** : regarde la notification NeoVibe —
   est-elle toujours là ?
5. Rouvre l'app et envoie-moi le diagnostic.

## ⚠️ Ce qu'il ne faut PAS faire

> **N'utilise pas « Forcer l'arrêt » dans les réglages Android.**

Ce n'est pas la même chose. Quand Android range une app **de lui-même**, il la
relance ensuite — c'est ce qu'on teste. Quand **toi** tu forces l'arrêt, Android
considère que tu ne veux plus de l'app et ne la relance **jamais**. Tu
conclurais à un échec alors que le test n'aurait pas eu lieu.

**Ce que je vérifierai** : `resumedFromDisk` dans le diagnostic. S'il est
**vrai**, c'est que le téléphone a été rangé par Android **et qu'il est reparti
tout seul** — exactement ce qu'on vient de construire.

⚠️ **Il peut très bien rester faux** : ça voudra dire qu'Android n'a pas eu
besoin de ranger l'app cette nuit-là. **Ce n'est pas un échec** — c'est une nuit
où le cas ne s'est pas présenté.

---

# Ce qu'il me faut à la fin

1. **le diagnostic des deux appareils** ;
2. **à quelle étape ça a cassé**, si ça casse, et ce que tu as vu à l'écran ;
3. **l'heure de début et de fin** — c'est la seule façon de mesurer les appels
   serveur dans les journaux, et c'est comme ça qu'on a trouvé la boucle de
   122 appels.
