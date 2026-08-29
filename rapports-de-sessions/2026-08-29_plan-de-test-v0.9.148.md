# Protocole de test — v0.9.148

⚠️ **Installe la v0.9.148 sur les DEUX appareils avant de commencer.** Elle
contient les trois correctifs, dont deux ne peuvent pas se tester sur l'ancienne.

## Ce qui est déjà validé, et qu'on ne refait pas

- ✅ le **doublon** de mimi a disparu *(confirmé par toi, hier soir)* ;
- ✅ `incidents consignés` retombé à **0** et **1**, contre 318 et 485 avant ;
- ✅ la localisation : **même carreau**, ± 33 m et ± 36 m, en `best` ;
- ✅ le croisement d'amis aboutit, un ami accepté est reconnu en 2 secondes ;
- ✅ les deux interrupteurs sont bien séparés.

## L'état de départ, relevé en base

| | |
|---|---|
| Charles et mimi | **amis** (depuis hier 17:34) |
| Blocages | aucun |
| Demandes en attente | aucune |
| Croisements enregistrés | 0 — *effacés par le retrait d'ami d'hier, c'est normal* |

⚠️ **Fais les tests DANS L'ORDRE.** Chacun laisse l'état dont le suivant a
besoin : amis → inconnus → amis.

---

# Étape 0 — Préparer *(2 minutes)*

Sur **les deux** appareils :

1. Installer la **v0.9.148**.
2. Réglages → Sécurité et confidentialité → **« Croiser mes amis » ALLUMÉ**.
3. Écran Ping → **« Visible à proximité » ALLUMÉ**.
4. Réglages → Développeur → **effacer le journal** (« nouveau test »).
5. Côte à côte, laissez tourner **une minute** sans rien toucher.

---

# Test A — Le ping marche sans ouvrir l'onglet Ping *(4 minutes)*

**Ce qu'on vérifie :** avant la v0.9.146, rien ne démarrait tant que tu n'avais
pas ouvert cet onglet **une fois**. Comme tu l'ouvrais toujours en premier, le
trou ne pouvait pas se voir.

1. Sur les deux : **balaie l'app** de la liste des applis récentes.
2. Rouvre-la. 🔴 **NE VA PAS sur l'onglet Ping.** Reste sur l'accueil.
3. Posez les deux téléphones côte à côte, **deux minutes**, sans y toucher.
4. **Ensuite seulement**, ouvre l'onglet Ping.

| ✅ | ❌ |
|---|---|
| l'autre est **déjà là, avec une distance**, dès l'ouverture | il faut attendre que ça « démarre » |
| aucun bandeau « Démarrage… » | |

---

# Test B 🔴 — Le blocage, proprement *(10 minutes)*

**Le test le plus important de la série**, et celui qui a été bâclé hier : il
avait duré 22 secondes.

## ⚠️ D'abord, pourquoi ça prend du temps

Le blocage doit couper **les deux sens**, et les deux ne vont pas à la même
vitesse :

| | Chez qui | Par quel chemin | Délai attendu |
|---|---|---|---|
| **Le sens facile** | mimi (celle qui bloque) | son propre téléphone | immédiat |
| **Le sens difficile** | Charles (le bloqué) | le **serveur** doit cesser de le lui montrer | jusqu'à **une minute** |

Vingt secondes ne prouvent donc rien : **ni que ça marche, ni que ça ne marche
pas.** C'est le seul but des deux minutes d'attente.

## B1 — Redevenir inconnus *(2 min)*

1. Sur le téléphone de **Charles** : profil de mimi → **retirer l'ami**.
2. Attendez de vous voir apparaître dans **« Autour de toi »** (10 à 20 s).

| ✅ | ❌ |
|---|---|
| chacun voit l'autre dans « Autour de toi », avec une distance | personne n'apparaît |

🔴 **Si personne n'apparaît, arrête-toi ici et dis-le-moi** : les tests suivants
n'auraient aucun sens.

## B2 — Ouvrir un fil de discussion AVANT de bloquer *(1 min)*

**C'est l'étape neuve, et c'est elle qui teste le correctif du jour.**

3. Sur le téléphone de **Charles** : sur la tuile de mimi, appuie sur
   **« Écrire »**. Envoie **un** message.
4. **Reste dans ce fil de discussion**, ne quitte pas l'écran.

## B3 — mimi bloque, et on ATTEND *(3 min)*

5. Sur le téléphone de **mimi** : profil de Charles → **Bloquer**.
6. 🔴 **Attendez DEUX MINUTES**, côte à côte, sans toucher aux écrans.

| ✅ | ❌ |
|---|---|
| Charles a disparu de l'écran de mimi | |
| 🔴 **mimi a disparu AUSSI de l'écran de Charles** | mimi reste visible chez Charles |
| le compteur « N personnes ont le ping actif » est à **0** des deux côtés | il reste à 1 |

7. **Sur le téléphone de Charles, toujours dans le fil** : essaie d'envoyer un
   second message.

| ✅ | ❌ |
|---|---|
| l'envoi **échoue**, ou le champ devient inerte | le message part comme si de rien n'était |

> **Pourquoi cette étape existe.** Jusqu'à ce matin, le blocage supprimait
> l'amitié et les demandes en attente, mais laissait en place le **ticket**
> *« ces deux-là étaient côte à côte »* — celui qui autorise le bouton
> « Écrire ». Une personne qu'on venait de bloquer gardait donc **trois
> minutes** de fil ouvert, et **dix minutes** pour envoyer une demande d'ami.
> Le ticket est maintenant déchiré en même temps que le reste.

## B4 — Débloquer *(2 min)*

8. mimi débloque Charles.
9. Attendez **une minute**, côte à côte.

| ✅ | ❌ |
|---|---|
| vous vous revoyez dans « Autour de toi » | il faut redémarrer l'app |

⚠️ **Il est normal d'attendre 10 à 20 secondes de plus** avant que « Écrire »
redevienne possible : le ticket a été déchiré, il faut vous revoir pour en
refabriquer un. Ce n'est pas un défaut, c'est le correctif.

---

# Test C — Redevenir amis, et le compteur *(3 minutes)*

1. Côte à côte : demandez-vous en ami, et acceptez.
2. Regarde ton **compteur d'amis** sur ton profil.

| ✅ | ❌ |
|---|---|
| l'autre apparaît **avec une distance en moins d'une minute** | il faut redémarrer l'app |
| le compteur monte **tout de suite**, des deux côtés | il faut redémarrer l'app |
| l'autre **quitte** « Autour de toi », **sans doublon** | il reste dans les deux listes |

---

# Test D — La nuit *(à lancer en dernier, avant de dormir)*

1. Vous êtes **amis**, les deux interrupteurs allumés des deux côtés.
2. Les deux téléphones **côte à côte**, **apps fermées avec le bouton
   accueil** — 🔴 **PAS balayées de la liste des récentes**.
3. **Toute la nuit.**
4. Au réveil, **avant de rouvrir l'app** : la notification NeoVibe est-elle
   toujours dans la barre ?
5. Rouvre l'app, et envoie-moi le diagnostic des deux appareils.

## ⚠️ Ce qu'il ne faut surtout pas faire

> **N'utilise pas « Forcer l'arrêt » dans les réglages Android.**

Quand Android range l'app **de lui-même**, il la relance ensuite — c'est
exactement ce qu'on teste. Quand **toi** tu forces l'arrêt, Android ne la relance
**jamais** : tu conclurais à un échec alors que le test n'aurait pas eu lieu.

## 🆕 Ce que la nuit teste EN PLUS, cette fois

Le correctif du cri public. Au réveil, dans le diagnostic, deux nouvelles
lignes :

| Ligne | Ce qu'elle doit dire |
|---|---|
| `publicMuted` | **`true`** si l'app est restée rangée plus de 5 minutes — le téléphone a cessé tout seul de crier son identifiant public |
| `publicHeartbeatAgeMillis` | depuis combien de temps l'app n'a plus donné signe de vie |

⚠️ **`publicMuted: true` au réveil est le résultat ATTENDU, pas une panne.** Ça
prouve que le téléphone a arrêté de crier un identifiant que plus personne ne
pouvait traduire. Le croisement d'**amis**, lui, doit avoir continué — c'est ce
que le reste de la nuit vérifie.

---

# Reporté : le test d'éloignement

Il demande de **sortir de portée d'une trentaine de mètres** — une autre pièce ne
suffit pas — et d'attendre **deux minutes** sans toucher l'écran, pour voir le
fil de proximité se fermer tout seul. À faire quand tu pourras sortir.

---

# Ce qu'il me faut à la fin

1. **le diagnostic des DEUX appareils** ;
2. **à quel test ça a cassé**, si ça casse, et **ce que tu as vu à l'écran** ;
3. **l'heure de début et de fin.**

# Trois lignes à regarder toi-même dans le diagnostic

| Ligne | Ce qu'elle doit dire |
|---|---|
| `incidents consignés` | **0 ou 1**. À 300, le journal se sature et chasse tout le reste. |
| `carreau` | doit finir par **`· best`**, précision sous 60 m. |
| `publicMuted` | **`true` au réveil** après une nuit rangée — c'est le nouveau correctif qui travaille. |

---

# Connu et non corrigé — ne le prends pas pour un bug

| | |
|---|---|
| après un déblocage, il faut se revoir 10-20 s avant que « Écrire » revienne | c'est le correctif, pas un défaut |
| retirer un ami efface le croisement et les constats de la paire | voulu depuis le 2026-08-28 |
