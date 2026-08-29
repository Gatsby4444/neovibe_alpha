# Protocole de test — v0.9.147, ce qui reste

⚠️ **Pas de nouvelle installation.** On teste la **v0.9.147 déjà installée**.
Rien à télécharger.

## Ce qui est déjà validé, et qu'on ne refait pas

Prouvé aux tests précédents, ou confirmé par toi :

- ✅ le **doublon** de mimi a disparu *(toi, hier soir)* ;
- ✅ le journal ne se sature plus : `incidents consignés` = **0** et **1**, contre
  318 et 485 avant ;
- ✅ la localisation : **même carreau**, ± 33 m et ± 36 m, en `best` ;
- ✅ le croisement d'amis aboutit, un ami accepté est reconnu en 2 secondes ;
- ✅ les deux interrupteurs sont bien séparés.

## L'état de départ, relevé en base ce matin

| | |
|---|---|
| Charles et mimi | **amis** (depuis hier 17:34) |
| Blocages | aucun |
| Demandes en attente | aucune |
| Croisements enregistrés | 0 — *effacés par le retrait d'ami d'hier, c'est normal* |

⚠️ **Fais les tests DANS L'ORDRE.** Chacun laisse l'état dont le suivant a
besoin : amis → inconnus → amis.

---

# Étape 0 — Préparer *(1 minute)*

Sur **les deux** appareils :

1. Réglages → Sécurité et confidentialité → **« Croiser mes amis » ALLUMÉ**.
2. Écran Ping → **« Visible à proximité » ALLUMÉ**.
3. Réglages → Développeur → **effacer le journal** (« nouveau test »).

---

# Test A — Le ping marche sans ouvrir l'onglet Ping *(4 minutes)*

**Ce qu'on vérifie :** avant la v0.9.146, rien ne démarrait tant que tu n'avais
pas ouvert l'onglet Ping **une fois**. Comme tu l'ouvrais toujours, le trou ne
pouvait pas se voir.

1. Sur les deux : **balaie l'app** de la liste des applis récentes (fermeture
   complète).
2. Rouvre-la. 🔴 **NE VA PAS sur l'onglet Ping.** Reste sur l'accueil.
3. Posez les deux téléphones côte à côte, **deux minutes**, sans y toucher.
4. **Ensuite seulement**, ouvre l'onglet Ping.

| ✅ Ce qui doit être vrai | ❌ Ce qui serait un échec |
|---|---|
| l'autre est **déjà là, avec une distance**, dès l'ouverture | il faut attendre que ça « démarre » |
| aucun bandeau « Démarrage… » | |

---

# Test B 🔴 — Le blocage, proprement *(8 minutes)*

**Le test le plus important.** La dernière fois il a duré 22 secondes ; il en
faut plus, et pour une raison précise, expliquée en bas.

**Il faut être INCONNUS pour ce test.**

## B1 — Redevenir inconnus

1. Sur le téléphone de **Charles** : profil de mimi → **retirer l'ami**.
2. Attendez de vous voir apparaître dans **« Autour de toi »** (10 à 20 s).

| ✅ | ❌ |
|---|---|
| chacun voit l'autre dans « Autour de toi » | personne n'apparaît |

## B2 — Bloquer, et ATTENDRE

3. Sur le téléphone de **mimi** : profil de Charles → **Bloquer**.
4. 🔴 **Attendez DEUX MINUTES**, côte à côte, sans toucher aux écrans.

> **Pourquoi deux minutes et pas vingt secondes.** Le blocage doit couper **les
> deux sens**. Chez mimi, c'est immédiat : elle n'affiche plus Charles. Chez
> **Charles**, la disparition de mimi passe par le serveur, à son propre rythme.
> Vingt secondes ne prouvent rien : ni que ça marche, ni que ça ne marche pas.

| ✅ | ❌ |
|---|---|
| Charles a disparu de l'écran de mimi | |
| 🔴 **mimi a disparu AUSSI de l'écran de Charles** | mimi reste visible chez Charles |
| le compteur « N personnes ont le ping actif » est à **0** des deux côtés | il reste à 1 |

## B3 — Le bouton « Écrire » *(le point neuf)*

5. **Sans débloquer**, sur le téléphone de **Charles** : essaie d'ouvrir une
   discussion avec mimi si le bouton est encore quelque part à l'écran.

| ✅ | ❌ |
|---|---|
| aucun moyen d'écrire à mimi | une discussion s'ouvre quand même |

*(Si mimi a déjà disparu de partout chez Charles, il n'y a rien à faire : note-le
simplement.)*

## B4 — Débloquer

6. mimi débloque Charles.
7. Attendez **une minute**.

| ✅ | ❌ |
|---|---|
| vous vous revoyez dans « Autour de toi » | il faut redémarrer l'app |

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

---

# Reporté : le test d'éloignement

Il demande de **sortir de portée d'une trentaine de mètres** — une autre pièce ne
suffit pas — et d'attendre **deux minutes** sans toucher l'écran. Impossible ce
soir. Détail du protocole quand tu pourras le faire.

---

# Ce qu'il me faut à la fin

1. **le diagnostic des DEUX appareils** ;
2. **à quel test ça a cassé**, si ça casse, et **ce que tu as vu à l'écran** ;
3. **l'heure de début et de fin.**

# Deux lignes à regarder toi-même dans le diagnostic

| Ligne | Ce qu'elle doit dire |
|---|---|
| `incidents consignés` | **0 ou 1**. À 300, le journal se sature et chasse tout le reste. |
| `carreau` | doit finir par **`· best`** avec une précision sous 60 m. |

---

# Connu et non corrigé — ne le prends pas pour un bug

| | |
|---|---|
| un appel natif toutes les 2 s même ping coupé | coût seulement |
| le cri public peut durer **75 min** après qu'Android range l'app | |
| une paire née **juste avant** un blocage reste exploitable 10 min | c'est ce que teste B3 |
