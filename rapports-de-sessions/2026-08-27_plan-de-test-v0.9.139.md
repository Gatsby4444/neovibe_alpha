# Plan de test — v0.9.139

*Remplace le plan de la v0.9.136. Réordonné pour commencer par les tests
« inconnus », qui correspondent à l'état actuel des deux comptes.*

---

## L'état de départ, relevé en base

| | |
|---|---|
| Charles et mimi | **pas amis** |
| Blocage de Charles sur mimi | 🔴 **actif** |
| Demandes en attente | 0 |
| Constats, croisements, canaux | 0 |

---

## 🔴 Étape 0 — DÉBLOQUER (préalable bloquant)

**Tant que le blocage est actif, vous ne pouvez rien vous découvrir** : la liste
d'écoute du ping écarte les personnes bloquées, donc vos téléphones ne
s'entendent même plus.

**À faire, sur le téléphone de Charles** — *Réglages → Confidentialité →
Personnes bloquées → débloquer mimi*.

**Ce qui prouve** :

- ⚠️ **mimi doit APPARAÎTRE dans la liste** — c'était le défaut : la liste
  restait vide, et il n'y avait rien à débloquer ;
- le déblocage fonctionne.

**C'est un correctif serveur, déjà actif** — pas besoin d'installer quoi que ce
soit pour cette étape.

## Étape 0 bis — installer la v0.9.139 sur les deux

---

# A. Les tests INCONNUS

*C'est l'état actuel : profitez-en, ces trois-là n'ont jamais abouti.*

## A1 — Se découvrir

Côte à côte, ping actif sur les deux.

- chacun voit l'autre dans **« Autour de toi »**, avatar et nom, en **10 à
  20 secondes** ;
- ⚠️ **une seule tuile par personne**.

## A2 — 🔴 Le canal de proximité, et sa fermeture

**Le test le plus important : il n'a jamais été fait.** Tu es passé directement
de la découverte à la demande d'ami. C'est pourtant la plus grosse règle serveur
de la journée — jusqu'ici prouvée **en base seulement**.

1. côte à côte, **« Écrire »** sur la tuile de l'autre ;
2. échanger deux ou trois messages **dans les deux sens** ;
3. l'un s'éloigne d'une trentaine de mètres ;
4. essayer d'écrire.

**Ce qui prouve** :

- les messages passent dans les deux sens quand vous êtes ensemble ;
- en s'éloignant : bandeau **« Canal fermé — vous n'êtes plus à proximité. Tu
  peux relire, plus écrire. »** ;
- **le champ de saisie est inerte**, la flèche d'envoi a disparu ;
- **les messages restent lisibles** — fermer n'est pas effacer ;
- en revenant à portée, on peut réécrire.

## A3 — Disparaître en ~10 secondes

L'un s'éloigne (ou coupe le Bluetooth). L'autre regarde **sans toucher l'écran**.

- il quitte « Autour de toi » en **~10 s** ;
- il **réapparaît dans « Croisés récemment »** ;
- sur cette tuile, **pas de bouton « écrire »** — seulement « demander en ami » ;
- en revenant, il remonte dans « Autour de toi ».

---

# B. Les tests AMIS

## B1 — La demande, et son état

Côte à côte, **« Demander en ami »**.

- **le bouton devient un sablier** ;
- réappuyer redit l'état au lieu de renvoyer ;
- la demande apparaît chez l'autre dans « Demandes & rencontres ».

⚠️ **Éloignez-vous puis répondez plus tard** — la demande vit **7 jours** et
répondre ne demande plus d'être à portée.

## B2 — Accepter

- « Vous êtes connectés » ;
- la personne **quitte** « Autour de toi » (cette liste ne montre que des
  inconnus).

## B3 — 🔴 Le croisement d'amis — la moitié qui a manqué

La reconnaissance a marché (12 « presque »), mais **aucun constat de croisement**
n'a été enregistré : le blocage avait vidé les carnets au même moment.

Une fois amis, **restez côte à côte deux bonnes minutes**, apps ouvertes.

- la personne apparaît **instantanément**, avec une **distance** ;
- `advertMode` doit rester **`parallele`** (`advertTokensPerSlot : 2`) ;
- ⚠️ **coupez le Wi-Fi et les données sur les deux** : la reconnaissance doit
  continuer. C'est ce que le serveur ne saura jamais faire.

**Ce que je vérifierai en base** : `sightings` se remplit **dans les deux sens**,
et un `encounters` apparaît. C'est le seul point du test 7 jamais atteint.

---

# C. Les tests de rupture

## C1 — Bloquer, puis débloquer

Profil de l'autre → **« … » → Bloquer**.

- il disparaît des deux côtés ;
- il ne voit plus ton profil ni tes stories ;
- ⚠️ **puis débloque** — et vérifie que l'accès **revient**.

⚠️ **Regarde le diagnostic après** : la ligne « amis retirés du carnet » **ne
doit plus apparaître**. C'était le défaut de ce soir.

## C2 — Retirer l'ami

Vous redevenez inconnus, et le ping vous redécouvre comme en A1.

**Ce que je vérifierai** : `encounters` et `sightings` de la paire ont été
supprimés par le déclencheur.

🟡 Le profil restera visible entre vous **parce que vous partagez une
conversation** — question produit ouverte (`RAPPELS.md` #77).

---

## Ce qu'il me faut

1. **le diagnostic des deux appareils** à la fin ;
2. **à quelle étape ça a cassé**, et ce que tu as vu ;
3. **l'heure de début et de fin**, pour mesurer les appels serveur dans les
   journaux — c'est la seule preuve possible de l'économie, et c'est elle qui a
   déjà trouvé une boucle ce soir.
