# Protocole de test — v0.9.146

⚠️ **Cette version contient QUATRE lots jamais testés** (v0.9.143 à v0.9.146).
Le protocole est donc construit pour **isoler chaque lot** : si quelque chose
casse, on saura lequel.

## L'état de départ, relevé en base

| | |
|---|---|
| Charles et mimi | **amis** |
| Blocages | aucun |
| Demandes en attente | aucune |
| Croisements enregistrés | **0** |
| Clés publiées | **2** — les deux appareils sont reconnaissables |
| Balises actives | 0 — le ping est coupé des deux côtés |

---

# Étape 0 — Installer la v0.9.146 sur les deux appareils

**Sur les deux téléphones, avant de commencer** : Réglages → **Sécurité et
confidentialité** → vérifie que **« Croiser mes amis » est ALLUMÉ**.

C'est un réglage neuf. Il a repris ton réglage précédent, donc il devrait déjà
être allumé — mais **vérifie**, tout le reste en dépend.

---

# Test 1 🆕 — Les deux interrupteurs sont bien séparés

**Ce qu'on vérifie** : couper la découverte des inconnus ne coupe plus le
croisement de tes amis.

Avant, **un seul interrupteur commandait les deux** : refuser d'être découvrable
par des inconnus te faisait perdre tes streaks et le « presque ».

1. Sur **les deux** téléphones : « Visible à proximité » **allumé**, côte à côte.
2. Attends de voir l'autre apparaître **avec une distance**.
3. Sur le téléphone de **Charles** seulement : **coupe « Visible à proximité »**.

## Ce qui doit se produire

- ✅ chez Charles, la section **« Autour de toi » (inconnus)** dit d'activer la
  visibilité ;
- ✅ 🔴 **mimi reste visible dans la liste des AMIS, avec sa distance** — c'est
  le point du test ;
- ✅ chez mimi, Charles reste visible aussi.

4. Maintenant, chez Charles : Réglages → Sécurité et confidentialité → **coupe
   « Croiser mes amis »**.

- ✅ 🔴 **mimi disparaît alors de la liste des amis**, avec le message
  *« Le croisement de tes amis est coupé »*.

5. **Rallume les deux** avant de continuer.

**Si mimi disparaît dès l'étape 3, arrête-toi et dis-le-moi** : la séparation
n'aurait pas pris.

---

# Test 2 🆕 — Le ping marche sans ouvrir l'onglet Ping

**Ce qu'on vérifie** : avant, **rien ne démarrait** tant que tu n'avais pas
ouvert l'onglet Ping au moins une fois.

1. **Ferme complètement l'app** sur les deux téléphones (balaie-la).
2. Rouvre-la, et **NE VA PAS sur l'onglet Ping**. Reste sur l'onglet d'accueil.
3. **Attends deux minutes**, côte à côte.
4. **Ensuite seulement**, va sur l'onglet Ping.

## Ce qui doit se produire

- ✅ l'autre est **déjà là**, avec une distance — pas besoin d'attendre que
  l'écran « démarre » ;
- ✅ le bandeau ne dit pas « Démarrage… ».

**Ce que je vérifierai en base** : des constats de croisement datés **pendant les
deux minutes où l'écran Ping était fermé**.

---

# Test 3 🔴 — LE test en attente depuis trois versions

**Ce qu'on vérifie** : quand tu ajoutes un ami, il est reconnu **des deux
côtés**. Avant, seul **celui qui accepte** remplissait son carnet ; celui qui
avait *envoyé* la demande restait sourd.

## ⚠️ La consigne la plus importante

> **NE TOUCHE À AUCUN des deux interrupteurs pendant ce test.**

Les rebasculer refait tout, et masquerait le défaut exactement comme avant.

1. Les deux appareils côte à côte, les deux interrupteurs allumés.
2. Sur le téléphone de **Charles** : profil de mimi → **retirer l'ami**.
3. **Regarde le compteur d'amis sur ton profil.** 🆕 Il doit baisser **tout de
   suite**, sans redémarrer l'app.
4. Attendez d'être visibles l'un pour l'autre dans **« Autour de toi »**.
5. **C'est mimi qui demande**, et **Charles qui accepte**.
6. **Restez côte à côte deux minutes, sans rien toucher.**

## Ce qui doit se produire

- ✅ la personne apparaît **avec une distance**, **en moins d'une minute** ;
- ✅ elle **quitte** « Autour de toi » (cette section ne montre que des inconnus) ;
- ✅ 🆕 le compteur d'amis remonte tout de suite, des deux côtés.

**Ce que je vérifierai en base** : des constats **dans les deux sens**, et une
ligne de croisement.

---

# Test 4 🆕 — Le blocage tient même si le téléphone triche

**Ce qu'on vérifie** : le blocage est passé **côté serveur**. Avant, c'est le
téléphone qui l'appliquait — et un client modifié le contournait entièrement.

**Il faut être INCONNUS** : refais un retrait d'ami avant.

1. Côte à côte, ping actif des deux côtés, attendez de vous voir.
2. Sur le téléphone de **mimi** : ouvre le profil de Charles → **Bloquer**.
3. Attends **deux minutes**, toujours côte à côte.

## Ce qui doit se produire

- ✅ Charles disparaît de l'écran de mimi ;
- ✅ 🔴 **mimi disparaît aussi de l'écran de Charles** ;
- ✅ le compteur « N personnes ont le ping actif » retombe à **0** des deux côtés.

4. **Débloque**, et vérifiez que vous vous revoyez au bout d'une minute.

**Ce que je vérifierai en base** : **aucune** paire ping créée pendant le
blocage.

---

# Test 5 — Le chat de proximité

**Toujours en inconnus.**

1. Côte à côte, appuie sur **« Écrire »** sur la tuile de l'autre.
2. Échangez deux ou trois messages **dans les deux sens**.
3. **L'un s'éloigne d'une trentaine de mètres.** L'autre **reste dans le chat**.
4. **Attends au moins deux minutes** sans toucher l'écran.

⚠️ **Deux minutes, pas quinze secondes** : quand la balise d'en face a expiré, il
existe un filet de **2 minutes** avant qu'on déclare la personne partie. La
dernière fois tu avais conclu trop tôt.

## Ce qui doit se produire

- ✅ un bandeau : **« Canal fermé — vous n'êtes plus à proximité »** ;
- ✅ le champ de saisie devient inerte, la flèche d'envoi disparaît ;
- ✅ les messages **restent lisibles** ;
- ✅ **en revenant à portée, tu peux réécrire.**

---

# Test 6 — La nuit (le plus long, à faire en dernier)

1. Vous êtes **amis** (après le Test 3).
2. Les deux téléphones **côte à côte**, les deux interrupteurs allumés,
   **apps fermées** (bouton accueil, **pas balayées**).
3. **Laisse-les ainsi toute la nuit.**
4. Le matin, **avant de rouvrir l'app** : la notification NeoVibe est-elle
   toujours là ?
5. Rouvre l'app et envoie-moi le diagnostic.

## ⚠️ Ce qu'il ne faut PAS faire

> **N'utilise pas « Forcer l'arrêt ».**

Quand Android range une app **de lui-même**, il la relance ensuite — c'est ce
qu'on teste. Quand **toi** tu forces l'arrêt, Android ne la relance **jamais** :
tu conclurais à un échec alors que le test n'aurait pas eu lieu.

---

# Ce qu'il me faut à la fin

1. **le diagnostic des deux appareils** — 🆕 il dit maintenant **quel palier de
   localisation a répondu** (`best` / `network` / `lastKnown`) et **les deux
   intentions** séparément ;
2. **à quelle étape ça a cassé**, si ça casse, et ce que tu as vu à l'écran ;
3. **l'heure de début et de fin.**

## 🆕 Ce que je te demande de regarder toi-même, dans le diagnostic

La ligne **`carreau`**. Elle finit maintenant par `best`, `network` ou
`lastKnown`, et donne l'incertitude en mètres.

- `best ± 20 m` → parfait
- `best ± 400 m` → on a demandé le meilleur, l'intérieur ne l'a pas donné
- `network ± …` → les satellites n'ont pas répondu du tout

**C'est cette ligne qui manquait pour comprendre la panne de ce matin.**

---

# Ce qui reste connu et non corrigé — pour que tu ne le prennes pas pour un bug

| | |
|---|---|
| l'app fait un appel natif toutes les 2 s même ping coupé | coût seulement, corrigé **après** ce test |
| le cri public peut durer jusqu'à **75 min** après qu'Android range l'app | au lieu de 12 h avant aujourd'hui |
