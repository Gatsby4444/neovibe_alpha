# Le recensement du ping : ce qui circule, ce qui a un état, ce qui a un rythme

*Demandé par Jay le 2026-08-28, comme base de reconstruction.*

> « On a essayé de tout généraliser mais en fait il faut séparer les choses
> suivantes : les données, l'état de l'utilisateur par rapport à un autre, l'état
> du ping, les actions de l'utilisateur, et l'intervalle d'envoi des données au
> serveur. »

**Périmètre** : la proximité et le graphe d'amis. Pas la caméra, pas les Vibes,
pas les stories.

📎 **Le catalogue des données elles-mêmes** — clés, jetons, mesures radio,
fichiers sur le disque, colonnes en base — est dans
[`donnees-du-ping.md`](donnees-du-ping.md). Celui-ci dit **ce qui circule et
quand** ; celui-là dit **de quoi c'est fait**.

⚠️ **Tout ce qui suit est relevé à la source** — le code et la base — le
2026-08-28, sur la **v0.9.144**. Aucune ligne ne vient d'un document antérieur.
Ce fichier a donc, lui aussi, une date de péremption : il dit ce qui était vrai
ce jour-là.

🔴 **Et il l'a prouvé le jour même.** Écrit le matin sur la v0.9.143, il
décrivait `ping_shortlist` — une fonction **supprimée le soir**, quelques heures
plus tard, précisément parce que ce recensement a permis de voir qu'elle ne
servait plus à ce qu'on croyait. Trois lignes de ce fichier étaient déjà fausses
avant la fin de la journée. **C'est la démonstration de la règle, pas une
excuse** : on relit toujours le code, jamais le document.

---

## Jay a-t-il raison de dire qu'on ne l'a jamais fait correctement ?

**Oui, avec une nuance.** Les *règles* de séparation existent depuis le
2026-08-20 dans `CLAUDE.md`, et deux modules les appliquent bien
(`presence_feed.dart`, `ping_nearby_feed.dart`). Ce qui n'a **jamais** été fait,
c'est le **recensement** : la liste close de ce qui traverse le fil dans chaque
sens, de ce qui possède un état, et de ce qui possède un rythme.

Et c'est vérifiable, pas une figure de style : **les quatre défauts corrigés
aujourd'hui sont tous assis sur une couture entre deux de ces cinq catégories.**

| Défaut | La couture |
|---|---|
| **D1** le carnet d'amis restait vide chez celui qui n'écrivait pas | le carnet est un **état (③)** que seule une **action (④)** mettait à jour — il n'avait ni propriétaire, ni rythme |
| **D2** le compteur d'amis figé après un retrait | même couture : un cache rafraîchi par l'action, pas par le changement d'état |
| **D3** 4 appels serveur toutes les 2 s | un **intervalle (⑤)** que personne n'avait déclaré — il émergeait d'une boucle de balayage |
| **D4** deux appareils côte à côte invisibles | une **donnée (①)**, l'incertitude GPS, promue au rang de **règle** |

Aucun des quatre n'aurait survécu à ce tableau écrit à l'avance.

---

# ① Ce que l'APPAREIL envoie au serveur

## Par appel de fonction

| Appel | Ce qui part exactement | Déclenché par |
|---|---|---|
| `publish_ping_beacon(lat, lon, token, slot, acc)` | **ma position exacte**, mon jeton public du créneau, le créneau, l'incertitude annoncée | rythme (60 s) |
| `retire_ping_beacon()` | rien | action : couper le ping |
| `ping_neighbour_count()` | rien — c'est une demande | rythme (60 s) |
| `confirm_ping(tokens[], slot)` | **TOUS les jetons publics entendus par la radio** + le créneau | 1ʳᵉ écoute d'un jeton, puis rythme (60 s) |
| `report_sightings(items[])` | par ami vu : son identifiant, le créneau, la **bande** | 1× par (ami, créneau) |
| `request_connection_from_proximity(peer)` | l'identifiant du pair | action |
| `accept_connection_request(req_id)` | l'identifiant de la demande | action |
| `decline_connection_request(req_id)` | idem | action |
| `get_or_create_proximity_conversation(peer)` | l'identifiant du pair | action : « Écrire » |
| `block_user` / `unblock_user(p_user_id)` | l'identifiant | action |
| `ping_nearby()` | rien — c'est une demande | rythme conditionnel (voir ⑤) |
| `profile_stats(target)` | l'identifiant | affichage d'un profil |

## Par écriture directe en table

| Table | Ce qui part | Déclenché par |
|---|---|---|
| `device_keys` (upsert) | **ma clé publique X25519** | 1× par session |
| `waves` (insert) | identifiant du pair + heure de notification | un ami passe tout près (cooldown 2 h) |
| `messages` (insert) | le message | action |
| `connections` (delete) | — | action : retirer un ami |
| `dev_reports` (insert) | le rapport de diagnostic | action |

## ⚠️ Ce qui ne part JAMAIS, et c'est une décision, pas un oubli

- **aucune distance en mètres** — seulement une **bande** (`contact`, `close`,
  `room`, `far`). Une distance au mètre ferait de l'app un outil de traque ;
- **aucun nom, aucun identifiant dans les jetons** — le jeton public est opaque,
  le jeton d'ami est un HMAC que seule la paire sait lire ;
- **aucun BSSID Wi-Fi** (piste évaluée et écartée le 2026-08-26, `RAPPELS.md` #36) ;
- **aucune position quand l'app est fermée** — c'est ce qui permet de n'exiger
  que « pendant l'utilisation ».

🟡 **La position exacte, elle, part et est conservée** (décision de Jay,
2026-08-26). C'est la donnée la plus sensible de cette liste.

---

# ② Ce que le SERVEUR envoie à l'appareil

## Sur demande (l'appareil tire)

| Appel | Ce qui revient |
|---|---|
| `ping_neighbour_count` | **un entier**, et rien d'autre : combien de balises fraîches dans le voisinage |
| `confirm_ping` | **un nombre**, rien d'autre : combien de constats ont été retenus |
| `ping_nearby` | pour chaque paire **mutuelle** de moins de 10 min : identifiant, pseudo, tag, avatar, dernière vue, jeton |
| `device_keys` (select) | **la liste d'amis elle-même** — identifiant + clé publique |
| `profiles` (select) | pseudo, tag, avatar de ces amis |
| `profile_stats` | nombre d'amis, de posts, de cards sur 7 jours |

⚠️ **`device_keys` EST la liste d'amis, et rien au point d'appel ne le dit.** Le
client écrit « prends tout sauf moi » ; c'est la politique RLS
`device_keys_friends` qui restreint aux amis et écarte ceux qui m'ont bloqué. La
définition d'« ami » côté application vit donc **dans une règle du serveur**.

⚠️ **Un profil n'est révélé que si les DEUX se sont entendus.** C'est structurel,
pas déclaratif : `ping_nearby` lit `ping_pairs`, et une paire ne naît que d'une
confirmation croisée.

## Sans demande (le serveur pousse, en temps réel)

| Table | Ce qui arrive |
|---|---|
| `connections` | le graphe d'amis |
| `connection_requests` | les demandes reçues et envoyées |
| `messages` | les messages |
| `card_deliveries` | les livraisons de Vibes |

🔴 **Le piège à connaître** : une **suppression** de ligne n'est pas toujours
diffusée par le temps réel Postgres — la sécurité n'a pas de quoi s'évaluer sur
un enregistrement effacé. Or `block_user` **supprime** la connexion. C'est
pourquoi il existe un filet périodique (⑤).

---

# ③ Les états de l'APPAREIL

Six machines d'état vivent en parallèle. **Elles ne changent pas au même rythme
et ne se déduisent pas les unes des autres** — c'est le point.

### a. Les intentions de l'utilisateur — **il y en a DEUX**
`wantsFriends` (**croiser mes amis**, Réglages → Sécurité et confidentialité) ·
`wantsDiscovery` (**visible des inconnus**, écran Ping) · `intentLoaded` : lues
du disque ou pas encore.

🔴 **Il n'y en avait qu'une jusqu'au 2026-08-28**, et elle commandait les deux :
couper « Visible à proximité » coupait aussi le croisement des amis — donc les
streaks et le « presque ». Trois commentaires du code affirmaient le contraire.
La séparation avait été **conçue** (`AdvertPlanner.plan` accepte une graine
publique nulle depuis le 2026-08-20), jamais **branchée**.

| | croiser mes amis | visible des inconnus |
|---|---|---|
| permission de position | **aucune** (Android 12+) | oui |
| balise au serveur | **non** | oui |
| app fermée | **oui** | non |
| dans le plan d'émission | jeton d'ami, **12 h** | identifiant public, **75 min** |

### b. La radio *(`RadioStatus`, publié par le service natif)*
`unsupported` · `permissionsMissing(liste)` · `adapterOff` · `locationOff` ·
`idle` · `starting` · `running(advertising, scanning)` · `failed(code, message)` ·
`unknown`.

⚠️ **`advertising` et `scanning` sont deux choses.** Détecter sans être annoncé
donne un appareil qui voit tout le monde sans que personne ne le voie.

### c. La position
- **blocage** : aucun · `serviceOff` · `denied` · `deniedForever` · **`noFix`** *(nouveau le 2026-08-28)*
- **finesse accordée** : `precise` · `approximate`
- **palier qui a répondu** : `best` · `network` · `lastKnown` *(nouveau)*

### d. La balise
publiée (avec sa date) ou non · nombre de jetons écoutés · ce nombre est-il un
plancher · constats retenus · dernière panne réseau.

### e. Le mode d'émission *(natif)*
`parallele` (plusieurs jetons à la fois) · `cycle` (un seul, en alternance).
Plus `advertTokensPerSlot`, `protocolVersion`, et le fait que le plan ait été
**relu du disque** après un redémarrage du service.

### f. 🔴 Le carnet d'amis
**rempli / vide — et il n'a AUCUN état déclaré nulle part.**

C'est exactement le défaut D1 : un état invisible, sans propriétaire, dont
dépendait toute la reconnaissance Bluetooth. Depuis aujourd'hui il a une règle
(`friend_book_watcher.dart`) — **il n'a toujours pas d'état lisible.**
⚠️ **C'est le premier chantier à ouvrir si on reconstruit.**

---

# ④ L'état de l'utilisateur PAR RAPPORT À UN AUTRE

## Le lien social *(ce que la base sait)*

| État | Où il vit |
|---|---|
| **inconnu** | aucune ligne nulle part |
| **croisé** | `ping_pairs`, paire mutuelle de moins de 10 min |
| **demande envoyée** | `connection_requests` = `pending` |
| **demande refusée** | `= declined` — on peut redemander |
| **demande expirée** | `= expired` (7 jours) |
| **ami** | `connections.status = 'full'` |
| **bloqué par moi / par lui** | `blocks` |

🟡 **Il n'existe qu'UN seul statut d'ami** (`full`). Les paliers de relation
posés par Jay le 2026-08-28 viendront comme des **valeurs supplémentaires de ce
champ**, sur un chemin d'entrée unique (`RAPPELS.md` #86).

## La présence physique *(ce que la radio sait, ici et maintenant)*

| Dimension | Valeurs |
|---|---|
| étape | `detected` (entendu) · `identified` (reconnu comme ami) |
| bande | `contact` · `close` · `room` · `far` |
| tendance | `approaching` · `stable` · `leaving` |

⚠️ **Ces deux tableaux sont indépendants.** Un ami peut être hors de portée ; un
inconnu peut être en `contact`. Les confondre est ce qui a produit le bandeau
menteur du chat de proximité le 2026-08-27.

---

# ⑤ Les actions de l'UTILISATEUR

| Action | Ce qu'elle déclenche |
|---|---|
| basculer **« Visible à proximité »** | démarre/arrête la radio, publie ou retire la balise |
| **autoriser la position** / ouvrir les réglages / **réessayer** | relance une lecture |
| **« Écrire »** à un inconnu à portée | ouvre le canal de proximité |
| **« Demander en ami »** | crée la demande (le serveur exige une paire mutuelle de moins de 10 min) |
| **accepter** / **refuser** une demande | crée ou ferme le lien |
| **retirer un ami** | supprime la connexion |
| **bloquer** / **débloquer** | supprime aussi la connexion et les demandes en cours |
| **signaler** un contenu ou un profil | — |
| **envoyer un diagnostic** | écrit dans `dev_reports` |

⚠️ **Une action ne doit dire qu'une chose : « la vérité a changé, relis-la. »**
Depuis le 2026-08-28, c'est ce qu'elles font — elles invalident la source, et la
règle qui écoute le graphe s'occupe du reste. Auparavant chacune entretenait
**sa propre liste** de ce qu'il fallait rafraîchir, et les listes divergeaient.

---

# ⑥ Les rythmes

## Ce qui parle au serveur

| Quoi | Cadence | Coût par tour |
|---|---|---|
| balise + compteur du quartier | **60 s** | 2 appels |
| dépôt des jetons entendus | **60 s** + immédiat au 1ᵉʳ jeton neuf | 1 appel |
| `ping_nearby` | **conditionnel** : seulement si un jeton entendu n'a pas de nom, ou au changement de créneau. Renoncement après 3 min | 1 appel |
| constats de croisement | **1 par (ami, créneau)** — donc 1 par quart d'heure | 1 appel |
| filet du carnet d'amis | **15 min** | 2 appels |
| carnet d'amis (événement) | **quand l'ensemble des amis change** | 2 appels |
| ma clé publique | **1× par session** | 1 appel |

**Total au repos, un ami à côté : environ 5 appels par minute, et ~600 octets.**

| | appels/min | octets/min |
|---|---|---|
| avant le 2026-08-28 | ~120 | ~30 000 |
| après (carnet + constats corrigés) | ~5 | ~9 000 |
| après (liste d'écoute supprimée) | ~5 | **~600** |

## Ce qui ne parle à personne (local)

| Quoi | Cadence | Rôle |
|---|---|---|
| balayage des constats | 2 s | regarder qui est là ; n'envoie que s'il y a du neuf |
| entretien des sessions BLE | 2 s | ouvrir/fermer les présences |
| horloge de péremption | 5 s | fermer les fenêtres de temps à l'écran |
| rotation du plan d'émission | 1 h | recalculer les jetons à venir |

## Les durées qui décident

| Durée | Valeur | Ce qu'elle décide |
|---|---|---|
| créneau | **15 min** | tous les jetons changent |
| horizon du plan — **amis** | **12 h** | combien de temps l'appareil reste reconnaissable **sans aucun code Dart vivant** |
| horizon du plan — **public** | **75 min** | au-delà, plus personne ne peut nommer ce qu'on crie : la balise serveur est morte depuis longtemps |
| silence radio | **10 s** | « il est parti » (décidé en local, sans réseau) |
| filet serveur | **2 min** | « il est parti », quand on ne connaît pas encore son jeton |
| durée de vie d'une balise | **5 min** | au-delà, le serveur nous a oubliés |
| fenêtre de rencontre | **10 min** | au-delà, la demande d'ami est refusée |
| fraîcheur d'un point GPS | **5 min** | au-delà, on ne le publie pas |
| session BLE oubliée | **30 s** | sans annonce ni trafic |
| cooldown d'un « presque » | **2 h** | par ami |
| demande d'ami | **7 jours** | expiration |

🔴 **Trois de ces valeurs doivent rester égales à leur jumelle côté serveur** —
et rien ne le signalerait si elles divergeaient : la taille du carreau
(`kCellSizeDegrees` / `private.ping_cell_size`), la durée de vie de la balise
(`kPingBeaconTtl` / `private.ping_beacon_ttl`), la fenêtre de rencontre
(`kFenetreRencontre` / `private.fenetre_rencontre`).

---

# Ce que ce recensement montre, et par quoi reprendre

1. 🔴 **Le carnet d'amis n'a pas d'état lisible** (③f). C'est la donnée dont
   dépend toute la reconnaissance Bluetooth, et rien à l'écran ni au diagnostic
   ne dit s'il est rempli. **À faire en premier.**
2. 🟡 **Trois valeurs sont dupliquées entre l'app et le serveur** (⑥) sans
   qu'aucun test ne les compare.
3. 🟡 **`ping_nearby` est la seule cadence « conditionnelle »** de tout le
   système — donc la seule dont on ne peut pas dire le coût sans simuler. C'est
   déjà elle qui avait produit les 122 appels en 7 minutes du 2026-08-27.
4. 🟢 **Le lien social n'a qu'un seul palier.** Les cercles à venir s'installent
   dans ④, sans toucher au reste — c'est la bonne nouvelle de ce recensement.
