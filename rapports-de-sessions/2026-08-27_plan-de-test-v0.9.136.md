# Plan de test — v0.9.136

*Ce qui se prouve, et par quoi.*

Cette version change **beaucoup** : le transport BLE a été retiré, la présence
se constate en local, le canal de proximité se ferme, le blocage coupe, et la
clé de signature de l'appareil a disparu. Chaque test ci-dessous vise **un
risque précis**, dans l'ordre où il bloque les suivants.

---

## ⚠️ Avant de commencer

| | |
|---|---|
| **Installer v0.9.136 sur LES DEUX appareils** | une colonne serveur a été supprimée ; un appareil resté en v0.9.135 casserait sa synchro de clés |
| **Ouvrir l'app sur les deux** | c'est au démarrage que la clé publique se republie et que le carnet d'amis local se synchronise |
| **Activer « Visible à proximité » sur les deux** | rien ne tourne sans ça |

### L'état de départ, relevé en base le 2026-08-27

| | |
|---|---|
| Charles et mimi | **pas amis** |
| Demandes en cours | 0 |
| Blocages | 0 |
| Croisements, constats | 0 |
| Canaux de proximité | 0 |

👉 **C'est exactement le point de départ du protocole « deux inconnus »** — le
seul chemin jamais exercé de bout en bout. Le test se referme sur lui-même :
ils finissent amis.

---

## 🔴 Test 1 — La radio vit encore

**C'est le test bloquant.** `BLUETOOTH_CONNECT` a été retirée du manifeste, et
si c'était une erreur, **rien ne lèvera d'erreur** : la radio se taira.

**À faire** — ping actif sur les deux, à côté l'un de l'autre. Attendre ~1 min.
Puis : *Réglages → Développeur → Diagnostic* et m'envoyer le rapport.

**Ce qui prouve** :

| Compteur | Attendu | Ce que ça dit |
|---|---|---|
| `rawScans` | **> 0** | la radio livre quelque chose |
| `neoScans` | **> 0** | elle entend des annonces NeoVibe |
| `advertMode` | **`cycle`** tant que vous n'êtes pas amis | ⚠️ **corrigé le 2026-08-27** : le plan disait `parallele`, c'était faux. Avec **un seul jeton** à crier (l'identifiant public), le mode parallèle n'est même pas tenté — il exige 2 jetons ou plus. Lire `advertTokensPerSlot` : s'il vaut 1, `cycle` est la seule réponse possible, pas un repli. **C'est APRÈS être devenus amis (test 7) qu'il faut lire `parallele`.** |
| `otherVersionScans` | `0` | les deux appareils parlent le même protocole |
| `fgsLocationType` | `true` | le service porte le bon type |
| `synchros du carnet réussies` | **`0`** tant que vous n'êtes pas amis | normal : la synchro sort tôt quand le serveur ne renvoie aucune clé d'ami. Ça n'empêche pas la publication de la vôtre. |

🔴 **Si `rawScans` vaut 0 : arrête tout et dis-le-moi.** C'est
`BLUETOOTH_CONNECT` qu'il faut remettre — dans le manifeste **et** dans
`BlePermissions.required()`, les deux ensemble.

---

## Test 2 — Deux inconnus se découvrent

**Jamais exercé de bout en bout.** Jusqu'ici, seule la base prouvait que ce
chemin existe.

**À faire** — les deux téléphones côte à côte, ping actif. Regarder l'écran Ping.

**Ce qui prouve** :

- chacun voit l'autre dans **« Autour de toi »**, avec son **avatar** et son nom ;
- ça prend **10 à 20 secondes**, pas plus ;
- ⚠️ **une seule tuile par personne** — si tu en vois deux, le carnet d'amis
  local n'a pas été purgé : ferme et rouvre les deux apps.

**Ce que je vérifierai en base** : `ping_pairs` contient la paire, et
`ping_confirmations` en porte **deux** (une par sens) — c'est la propriété
anti-traque.

---

## Test 3 — Il disparaît en ~10 secondes, sans réseau

**C'est le changement le plus visible de cette version.** Avant, la disparition
prenait 30 à 45 s et coûtait un appel serveur toutes les dix secondes.

**À faire** — l'un s'éloigne d'une trentaine de mètres (ou coupe le Bluetooth).
L'autre regarde l'écran Ping, **sans y toucher**.

**Ce qui prouve** :

- la personne quitte « Autour de toi » en **~10 secondes** ;
- elle **réapparaît dans « Croisés récemment »**, avec « Croisé il y a un
  instant — plus à portée » ;
- sur cette tuile : **le bouton « écrire » a disparu**, seul « demander en ami »
  reste ;
- en revenant à portée, elle remonte dans « Autour de toi » en quelques secondes.

**Ce que je mesurerai** : les journaux du serveur, pour compter les appels par
minute. Attendu : **~2/min** au lieu de 8 à 14. C'est la seule preuve réelle de
l'économie — voir « ce que ce test ne prouve pas » plus bas.

---

## Test 4 — Le canal de proximité, et sa fermeture

**Il ne se fermait jamais avant cette version** : un canal ouvert une fois
servait pour toujours, à des kilomètres.

**À faire, dans cet ordre** :

1. côte à côte, appuyer sur **« Écrire »** sur la tuile de l'autre ;
2. échanger deux ou trois messages **dans les deux sens** ;
3. l'un s'éloigne d'une trentaine de mètres ;
4. essayer d'écrire.

**Ce qui prouve** :

- les messages passent **dans les deux sens** quand vous êtes ensemble ;
- en s'éloignant, un bandeau orange apparaît : **« Canal fermé — vous n'êtes
  plus à proximité. Tu peux relire, plus écrire. »** ;
- **le champ de saisie est inerte** et la flèche d'envoi a disparu ;
- **les messages restent lisibles** — fermer n'est pas effacer ;
- en revenant à portée, on peut réécrire.

---

## Test 5 — La demande d'ami, et son état

**C'est le défaut que tu avais signalé le 17 août** : tu cliquais plusieurs
fois sans savoir si ça avait marché.

**À faire** — côte à côte, appuyer sur **« Demander en ami »** depuis la tuile.

**Ce qui prouve** :

- un encadré confirme l'envoi ;
- **le bouton devient un sablier** — « Demande envoyée, en attente de sa
  réponse » ;
- appuyer dessus redit l'état au lieu de renvoyer une demande ;
- sur l'autre téléphone, la demande apparaît dans **« Demandes & rencontres »**.

⚠️ **Éloignez-vous puis répondez plus tard** : c'est nouveau. La demande vit
**7 jours**, et répondre ne demande plus d'être à portée.

---

## Test 6 — Accepter, et devenir amis

**À faire** — accepter la demande sur le second téléphone.

**Ce qui prouve** :

- l'encadré « Vous êtes connectés » ;
- **la personne quitte « Autour de toi »** (cette liste ne montre que des
  inconnus) et devient un ami ;
- une conversation directe est disponible.

---

## Test 7 — Le croisement d'amis, en Bluetooth pur

Ce chemin ne passe par **aucun serveur** : c'est la moitié du produit.

**À faire** — une fois amis, se remettre côte à côte, ping actif.

**Ce qui prouve** :

- la personne apparaît **instantanément** (moins d'une seconde, pas 15) ;
- avec une **distance** : « tout près », « il se rapproche » ;
- ⚠️ **Coupe le Wi-Fi et les données** sur les deux : la reconnaissance doit
  continuer. C'est ce que le serveur ne saura jamais faire.

**Ce que je vérifierai en base** : `sightings` se remplit, et `encounters`
apparaît quand les deux se sont vus.

---

## Test 8 — Bloquer coupe vraiment

**Avant cette version, bloquer quelqu'un ne l'empêchait que de te découvrir par
le ping.** Il voyait encore ton profil, tes stories, et pouvait t'écrire.

**À faire** — sur le téléphone A : ouvrir le profil de B (appuyer sur sa tuile)
→ menu **« … »** → **Bloquer**.

**Ce qui prouve** :

- B disparaît de la liste de A **et** A disparaît de celle de B ;
- B ne peut plus ouvrir le profil de A ;
- si A a des stories publiques, elles ne sont plus visibles par B.

**Puis débloquer** : *Réglages → comptes bloqués*. L'accès doit revenir.

---

## Test 9 — Retirer un ami

**À faire** — retirer l'amitié depuis le profil.

**Ce qui prouve** : les deux redeviennent des inconnus, et le ping les redécouvre
comme au Test 2.

**Ce que je vérifierai en base** : `encounters` et `sightings` de la paire ont
été **supprimés** par le déclencheur — c'est la fuite corrigée aujourd'hui.

🟡 **À savoir** : le profil restera visible entre eux **parce qu'ils partagent
une conversation**. C'est une branche différente de la règle, et une question
produit ouverte (`RAPPELS.md` #77).

---

## ⚠️ Ce que ce test NE PEUT PAS prouver

**L'économie d'appels n'est pas observable sur le téléphone.** Aucun compteur ne
la montre dans l'interface ni dans le rapport de diagnostic.

Je la mesurerai **dans les journaux du serveur** après coup — ça marche, je l'ai
vérifié. Mais si tu veux la voir **pendant** le test, je peux ajouter un
compteur d'appels au diagnostic : une dizaine de minutes, plus un build.

**Le ping app fermée** n'est pas testé ici — c'est un chantier non ouvert. Le
croisement d'amis, lui, fonctionne app fermée (tout est en Kotlin).

---

## Ce que j'attends de toi à la fin

1. **le rapport de diagnostic des deux appareils** (Réglages → Développeur) ;
2. **à quel test ça a cassé**, si ça a cassé, et ce que tu as vu à l'écran ;
3. l'heure approximative du début et de la fin, pour que je cadre la mesure des
   appels dans les journaux.

---

# 🔴 Correctif du 2026-08-27, 19 h 50 — l'APK ne s'installait pas

**Constaté par Jay sur la tablette** : « Application non installée », sans autre
explication, à chaque tentative.

## La cause, mesurée sur les artefacts publiés

| Release | Signataires | S'installe sur la tablette |
|---|---|---|
| v0.9.134 | **V3.0** `CN=Android Debug` (API 24-32) + **V3.1** `CN=NeoVibe` (API 33+) | ✅ |
| v0.9.135 | **v2** seul, `CN=NeoVibe` | ❌ |
| v0.9.136 (initiale) | **v2** seul, `CN=NeoVibe` | ❌ |

La tablette (Android 10) avait installé v0.9.134 sous l'identité **`Android
Debug`** — c'est le signataire que la rotation lui destine. Les deux APK publiés
ensuite se présentaient sous `NeoVibe`, **sans la preuve de rotation** : Android
voit un signataire étranger et refuse la mise à jour.

## C'était écrit, et je ne l'ai pas appliqué

`RAPPELS.md` #61, depuis le 2026-08-25 :

> Ne plus jamais publier un APK produit par `flutter build apk --release` seul :
> il est signé par la nouvelle clé **sans la preuve de rotation** et ne
> s'installera pas — **sans que rien ne le signale**.

`tool/build-release.sh` existait. Je ne m'en suis pas servi.

## ⚠️ Et ma vérification ne pouvait pas voir le défaut

J'avais bien contrôlé la signature — en comparant l'empreinte de la v0.9.136 à
celle de la **v0.9.135**. Deux APK cassés de la même façon. **Un instrument qui
compare le neuf au neuf ne peut pas contenir la preuve du contraire.** Il fallait
comparer à la dernière version qui **s'était installée**.

## Ce qui a été fait

1. **v0.9.136 reconstruite et re-signée** par `tool/build-release.sh`. L'artefact
   publié porte maintenant le certificat V3.0 `4df8a044…` — **exactement celui de
   la v0.9.134**, donc celui sous lequel la tablette a installé.
2. **v0.9.135 marquée inutilisable** dans ses notes de release.
3. **La cause est supprimée** : `tool/publish-release.sh` refuse de publier un
   APK qui ne porte pas les deux empreintes attendues, écrites **en dur** dans le
   script — donc indépendantes de la build précédente. Il vérifie aussi que le
   `versionCode` progresse, en lisant l'**artefact** de la release précédente.
   **Éprouvé dans les deux sens** : il refuse l'APK cassé de la v0.9.135, il
   accepte celui de la v0.9.136 re-signé.

👉 **Retélécharge la v0.9.136** — le fichier a été remplacé, le lien est le même.
