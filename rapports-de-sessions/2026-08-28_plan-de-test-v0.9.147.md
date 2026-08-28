# Protocole de test — v0.9.147

## Ce qui est DÉJÀ validé, et qu'on ne refait pas

Prouvé en base au test de la v0.9.146 :

- ✅ le croisement d'amis **aboutit**, avec des constats des deux côtés ;
- ✅ un ami accepté est reconnu en **2 secondes** ;
- ✅ le carnet d'amis se remplit **des deux côtés** ;
- ✅ la localisation : **même carreau**, ± 57 m et ± 20 m ;
- ✅ les deux interrupteurs sont bien séparés ;
- ✅ le compteur d'amis se met à jour tout de suite.

**Ce protocole ne teste donc que ce qui reste**, plus les deux correctifs de la
v0.9.147.

## L'état de départ, relevé en base

| | |
|---|---|
| Charles et mimi | **amis** |
| Blocages | aucun |
| **Demande en attente** | **1** — de Charles vers mimi, jamais acceptée |
| Croisements enregistrés | 1 |

---

# Étape 0 — Préparer (2 minutes)

1. Installer la **v0.9.147** sur les deux appareils.
2. Sur **les deux** : Réglages → Sécurité et confidentialité → **« Croiser mes
   amis » ALLUMÉ**.
3. Sur **les deux** : écran Ping → **« Visible à proximité » ALLUMÉ**.
4. Côte à côte, laisse tourner **une minute** sans rien toucher.

---

# Test 1 — Le doublon a disparu *(30 secondes)*

C'est ce que ta capture montrait : mimi affichée **deux fois**.

Vous êtes **déjà amis**. Regarde l'écran Ping.

| ✅ Ce qui doit être vrai | ❌ Ce qui serait un échec |
|---|---|
| mimi apparaît **une seule fois**, avec sa distance | mimi apparaît deux fois |
| la section « Autour de toi » (inconnus) est **vide** | mimi y figure encore |

---

# Test 2 — Le ping marche sans ouvrir l'onglet Ping *(3 minutes)*

Avant la v0.9.146, **rien ne démarrait** tant que tu n'avais pas ouvert cet
onglet une fois.

1. **Ferme complètement l'app** sur les deux téléphones (balaie-la de la liste
   des applis récentes).
2. Rouvre-la. **NE VA PAS sur l'onglet Ping.**
3. Reste sur l'onglet d'accueil, côte à côte, **deux minutes**.
4. **Ensuite seulement**, va sur l'onglet Ping.

| ✅ | ❌ |
|---|---|
| l'autre est **déjà là avec une distance**, immédiatement | il faut attendre que ça « démarre » |
| pas de bandeau « Démarrage… » | |

---

# Test 3 🔴 — Le blocage *(5 minutes)*

**Le test le plus important de cette série.** Le blocage est passé côté serveur :
avant, c'est le téléphone qui l'appliquait.

**Il faut être INCONNUS.**

1. Sur le téléphone de **Charles** : profil de mimi → **retirer l'ami**.
2. Attendez de vous voir dans **« Autour de toi »** (10 à 20 secondes).
3. Sur le téléphone de **mimi** : profil de Charles → **Bloquer**.
4. Attends **deux minutes**, toujours côte à côte, sans rien toucher.

| ✅ | ❌ |
|---|---|
| Charles disparaît de l'écran de mimi | |
| 🔴 **mimi disparaît AUSSI de l'écran de Charles** | mimi reste visible chez Charles |
| le compteur « N personnes ont le ping actif » tombe à **0** des deux côtés | il reste à 1 |

5. **Débloque.** Vérifie que vous vous revoyez dans la minute.

---

# Test 4 — Le chat de proximité *(5 minutes)*

**Toujours en inconnus** (après le déblocage).

1. Côte à côte, appuie sur **« Écrire »** sur la tuile de l'autre.
2. Échangez **deux ou trois messages dans les deux sens**.
3. **L'un s'éloigne d'une trentaine de mètres** (une autre pièce ne suffit pas —
   il faut vraiment sortir de portée). L'autre **reste dans le chat**.
4. ⚠️ **Attends DEUX MINUTES sans toucher l'écran.**

> **Deux minutes, pas quinze secondes.** Il existe un filet de sécurité de 2 min.
> La dernière fois tu avais conclu trop tôt.

| ✅ | ❌ |
|---|---|
| bandeau **« Canal fermé — vous n'êtes plus à proximité »** | rien ne change |
| le champ de saisie devient **inerte**, la flèche d'envoi disparaît | on peut encore écrire |
| les messages **restent lisibles** | ils disparaissent |
| en revenant à portée, **tu peux réécrire** | |

---

# Test 5 — Redevenir amis, et le compteur *(2 minutes)*

1. Côte à côte, **demandez-vous en ami** et acceptez.
2. Regarde ton **compteur d'amis** sur ton profil.

| ✅ | ❌ |
|---|---|
| l'autre apparaît **avec une distance en moins d'une minute** | il faut redémarrer l'app |
| le compteur monte **tout de suite**, des deux côtés | il faut redémarrer l'app |
| l'autre **quitte** « Autour de toi » (sans doublon) | il reste dans les deux listes |

---

# Test 6 — La nuit *(à faire en dernier)*

1. Vous êtes **amis**, les deux interrupteurs allumés.
2. Les deux téléphones **côte à côte**, **apps fermées** — bouton accueil,
   **PAS balayées**.
3. **Toute la nuit.**
4. Le matin, **avant de rouvrir l'app** : la notification NeoVibe est-elle
   toujours là ?
5. Rouvre l'app et envoie-moi le diagnostic.

## ⚠️ Ce qu'il ne faut surtout PAS faire

> **N'utilise pas « Forcer l'arrêt » dans les réglages Android.**

Quand Android range une app **de lui-même**, il la relance ensuite — c'est ce
qu'on teste. Quand **toi** tu forces l'arrêt, Android ne la relance **jamais** :
tu conclurais à un échec alors que le test n'aurait pas eu lieu.

---

# 🆕 Ce que je te demande de regarder TOI-MÊME dans le diagnostic

Deux lignes, et elles répondent à des questions précises.

### 1. `incidents consignés`

**Doit valoir 0, ou presque.** Au dernier test il valait **318 et 485**, ce qui
saturait le journal et en chassait tout le reste.

### 2. `carreau`

Elle finit par `best`, `network` ou `lastKnown` :

| Ce que tu lis | Ce que ça veut dire |
|---|---|
| `best ± 20 m` | parfait |
| `best ± 400 m` | on a demandé le meilleur, l'intérieur ne l'a pas donné |
| `network ± …` | les satellites n'ont pas répondu du tout |
| `lastKnown ± …` | on publie un vieux point, faute de mieux |

---

# Ce qu'il me faut à la fin

1. **le diagnostic des DEUX appareils** ;
2. **à quel test ça a cassé**, si ça casse, et **ce que tu as vu à l'écran** ;
3. **l'heure de début et de fin.**

---

# Connu et non corrigé — ne le prends pas pour un bug

| | |
|---|---|
| un appel natif toutes les 2 s même ping coupé | coût seulement, corrigé après ce test |
| le cri public peut durer **75 min** après qu'Android range l'app | au lieu de 12 h avant aujourd'hui |
