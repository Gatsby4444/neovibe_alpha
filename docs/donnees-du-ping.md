# Toutes les données qui font fonctionner le ping

*Demandé par Jay le 2026-08-28.* Complément de
[`etats-et-echanges-du-ping.md`](etats-et-echanges-du-ping.md) : celui-là dit
**ce qui circule et quand**, celui-ci dit **de quoi c'est fait**.

⚠️ Relevé à la source (code Dart, code Kotlin, base) sur la **v0.9.144**.
Ce fichier a une date de péremption comme tous les autres.

🔴 **Corrigé le soir même de son écriture** : la **liste d'écoute**
(`ping_shortlist`) a été supprimée le 2026-08-28, quelques heures après la
première version de ce document. Elle ne protégeait aucune limite BLE — le
filtre de scan accepte tout, et il n'y a plus une seule connexion GATT dans le
ping. Ce qu'elle tenait réellement était la **barrière du blocage**, et elle la
tenait **depuis le client**, donc pas du tout.

---

## A. Les secrets — ils ne sortent JAMAIS de l'appareil

| # | Donnée | Taille | Où elle vit | Durée de vie |
|---|---|---|---|---|
| 1 | **Graine privée X25519** (`nv_x25519_seed`) | 32 o | **coffre-fort** Android (Keystore) | **jamais renouvelée** — c'est l'identité de l'appareil |
| 2 | **Secret de paire** — un par ami | 32 o | **mémoire vive seulement** | recalculé à la demande, jamais écrit |
| 3 | **Graine de l'identifiant public** (`_pingSeed`) | 32 o aléatoires | **mémoire vive seulement** | **neuve à chaque activation du ping** |

🔑 **Le secret de paire ne se transmet pas, il se calcule.** Chacun le dérive de
sa propre clé privée et de la clé publique de l'autre (Diffie-Hellman, puis
HKDF). Un observateur qui a vu passer les **deux** clés publiques ne peut pas le
retrouver. C'est ce qui rend une réinstallation indolore : la nouvelle clé
publique arrive, le secret suit tout seul, il n'y a rien à invalider.

⚠️ **La n° 3 est celle qu'on oublie toujours.** Elle n'est **pas** sauvegardée :
elle disparaît à chaque fermeture de l'app, et est refaite à neuf à chaque
activation du ping. **C'est délibéré** — c'est elle qui empêche de relier deux
séances de découverte à la même personne. Conséquence à connaître : ton
identifiant public d'inconnu change à chaque redémarrage.

---

## B. Les identités publiques — visibles du serveur

| # | Donnée | Où |
|---|---|---|
| 4 | **Clé publique X25519** | `device_keys.x25519_pub` |
| 5 | **Identifiant de compte** (UUID) | partout |

⚠️ La n° 4 est **publique au sens strict** : la republier ne coûte rien et
n'ouvre rien. Elle ne vaut que combinée à une clé privée qu'on n'a pas.

---

## C. Les jetons criés — 16 octets, neufs toutes les 15 minutes

| # | Jeton | Formule | Pour qui |
|---|---|---|---|
| 6 | **Identifiant public de ping** | `HMAC(graine ping, "nv-ping-{créneau}")` | les inconnus — **reconnu par personne**, c'est son rôle |
| 7 | **Jeton d'ami** — **un par ami** | `HMAC(secret de paire, "nv-pair-{créneau}\|{émetteur}")` | cet ami-là, et lui seul |

⚠️ **`nv-ping-` et `nv-pair-` ne sont pas décoratifs** : deux usages d'une même
fonction doivent partir de textes différents, sinon rien n'interdit qu'un jeton
d'un contexte soit accepté dans l'autre.

🔴 **Le jeton d'ami est DIRECTIONNEL, et ça a coûté une panne.** Jusqu'au
2026-08-26 il valait `HMAC(secret, créneau)` — donc **la même valeur des deux
côtés**. Le filtre qui écarte ses propres annonces jetait alors **toutes** celles
de l'ami : une annonce sur deux, mesurée. Le croisement d'amis était
structurellement impossible, sans qu'aucune erreur ne soit levée. Le nom de
l'émetteur dans la formule rend les deux sens distincts.

---

## D. Ce qui part réellement sur les ondes — 20 octets, et rien d'autre

| Position | Contenu |
|---|---|
| — | identifiant fabricant `0xFFFF` |
| 0–1 | `"NV"` (`0x4E 0x56`) |
| 2 | **version du protocole** = **5** |
| 3 | **type** : `0x01` public · `0x02` ami |
| 4–19 | **le jeton** (16 o) |

⚠️ **La version est un octet aujourd'hui et une migration entière si on
l'oublie.** Deux appareils de versions différentes **ne se voient tout
simplement pas** — sans erreur. Le compteur `otherVersionScans` du diagnostic
existe pour que ça ne passe pas pour « personne autour ».

⚠️ **Il n'y a ni nom, ni identifiant, ni pseudo sur les ondes.** Un jeton est
opaque : seul le serveur (pour le public) ou le carnet local (pour un ami) sait
le nommer.

---

## E. Ce que la radio MESURE — jamais transmis tel quel

| # | Donnée | Remarque |
|---|---|---|
| 8 | **adresse BLE** de l'émetteur | **aléatoire, et Android la fait tourner tout seul** |
| 9 | **RSSI** (puissance reçue) | la seule mesure de distance qu'on ait |
| 10 | **txPower** annoncé par l'émetteur | ⚠️ **sans lui la distance est fausse d'un facteur 2 à 4** |
| 11 | **instant de l'annonce** | ⚠️ pas l'instant du traitement — la différence compte au rejeu |

Ce qu'on en **dérive**, et qui ne quitte jamais l'appareil sous cette forme :
distance estimée en mètres · **bande** (`contact`, `close`, `room`, `far`) ·
**tendance** (`approaching`, `stable`, `leaving`).

🔴 **La n° 8 est le piège classique.** Une session de présence était rangée
**par adresse BLE** : chaque rotation d'adresse créait une nouvelle « personne
détectée ». C'est ce qui affichait plusieurs détections pour un seul téléphone.

📤 **Seule la bande part au serveur.** Jamais une distance en mètres — une
distance au mètre près ferait de l'app un outil de traque, et elle serait de
toute façon fausse.

---

## F. Le temps — c'est une donnée, pas une commodité

| # | Donnée | Valeur |
|---|---|---|
| 12 | **le créneau** (`slot`) | `millisecondes epoch ÷ 900 000` → change toutes les 15 min |
| 13 | **la tolérance** | **±1 créneau** — deux téléphones n'ont jamais la même heure |

⚠️ **Le créneau est ce qui synchronise deux appareils qui ne se parlent pas.**
C'est la seule granularité sur laquelle ils peuvent se rejoindre sans échanger
un mot — et la seule qu'on ait envie de confier au serveur.

---

## G. La position

| # | Donnée | Qui la produit |
|---|---|---|
| 14 | **latitude / longitude exactes** | l'appareil |
| 15 | **incertitude annoncée** (`acc`, en mètres) | l'appareil — ⚠️ **il peut se tromper**, c'est la panne du 2026-08-28 |
| 16 | **quel palier a répondu** (`best` / `network` / `lastKnown`) | l'appareil *(nouveau)* |
| 17 | **le carreau** (`cell_lat`, `cell_lon`) | 🔑 **le SERVEUR**, jamais le client |

⚠️ **Le carreau est calculé côté serveur exprès** : non pour empêcher un client
de mentir sur sa position (il le peut de toute façon), mais pour qu'il n'existe
**qu'une seule définition** de la taille de la grille — 0,01°, soit ~1,1 km en
latitude et ~0,79 km en longitude.

---

## H. Ce qui est écrit sur le disque de l'appareil

| # | Fichier | Ce qu'il contient |
|---|---|---|
| 18 | `ping/friend_keys.json` | **le carnet d'amis** : par ami — identifiant, pseudo, tag, avatar, **clé publique X25519** |
| 19 | `ping/outbox.json` | **la file d'envoi** : ce qui doit remonter au retour d'internet |
| 20 | `proximity_plan.bin` (natif) | **le plan d'émission** et **la table de reconnaissance** |
| 21 | l'intention **« croiser mes amis »** | vrai / faux (`proximity_friends`) |
| 22 | l'intention **« visible des inconnus »** | vrai / faux (`proximity_visible`) |

🔴 **Le n° 18 est le trou du recensement** : c'est de lui que dépend toute la
reconnaissance Bluetooth, et **rien à l'écran ni au diagnostic ne dit s'il est
rempli**. C'est le défaut D1 du 2026-08-28.

🔑 **Le n° 20 est ce qui fait fonctionner le croisement la nuit.** Le Dart meurt
avec l'interface ; le service natif survit. S'il ne trouvait pas le plan sur le
disque après avoir été relancé par Android, l'appareil se tairait.

Ce que le plan contient exactement : `"NVPLAN2"` · créneau de départ · durée d'un
créneau · nombre de créneaux · jetons par créneau · longueur d'un jeton · **les
jetons eux-mêmes** — puis la même chose pour la table de reconnaissance, plus son
`tableId`.

---

## I. Le lien rang ↔ personne — la donnée la plus facile à oublier

| # | Donnée | Où |
|---|---|---|
| 23 | **le rang** (index) dans la table de reconnaissance | le natif ne connaît **que ça** |
| 24 | **le `tableId`** | versionne le carnet |

⚠️ **Le natif n'apprend aucune identité, jamais.** Il répond « le rang 3 est
passé », et c'est le Dart qui sait qui c'est. Lui donner les identifiants des
amis mettrait la liste de tes proches hors du Dart, pour un gain nul.

⚠️ **L'ordre est la seule chose qui relie un rang à une personne.** D'où le
`tableId` : si le carnet change, la table change d'identifiant, et les constats
de l'ancienne sont **jetés** plutôt qu'attribués au hasard. Un croisement faux
vaut moins que pas de croisement.

---

## J. Ce que la base garde

| Table | Colonnes |
|---|---|
| `device_keys` | `user_id`, `x25519_pub`, `updated_at` |
| `ping_beacons` | `user_id`, `cell_lat`, `cell_lon`, `lat`, `lon`, `acc`, `token`, `slot`, `updated_at` |
| `ping_confirmations` | `observer_id`, `subject_id`, `slot`, `created_at` |
| `ping_pairs` | `user_low`, `user_high`, `first_seen_at`, `last_seen_at` |
| `sightings` | `observer_id`, `seen_id`, `slot`, `band`, `created_at` |
| `encounters` | `user_low`, `user_high`, `first_seen_at`, `last_seen_at`, `proof` |
| `connections` | `id`, `user_low`, `user_high`, `status`, `origin`, `created_at`, `established_at` |
| `connection_requests` | `id`, `sender_id`, `receiver_id`, `status`, `created_at`, `expires_at` |
| `blocks` | `blocker_id`, `blocked_id`, `created_at` |
| `waves` | `user_id`, `peer_id`, `notify_after`, `detected_at` |

⚠️ **Deux niveaux de preuve, à ne jamais fusionner** : `ping_confirmations` /
`ping_pairs` pour les **inconnus** (le serveur résout les jetons), et
`sightings` / `encounters` pour les **amis** (l'appareil sait déjà qui c'est).
Dans les deux cas, **rien ne naît d'un constat unilatéral** — c'est la propriété
anti-traque, et elle est tenue en base, pas dans le client.

---

# Les huit qu'on oublie toujours

Si tu ne dois retenir qu'une liste, c'est celle-ci — ce sont les données
invisibles, et **chacune a déjà causé une panne ou en causera une** :

| | Donnée | Pourquoi elle compte |
|---|---|---|
| 1 | **la graine du jeton public** (A-3) | en mémoire seulement → ton identité d'inconnu change à chaque redémarrage |
| 2 | **le sens du jeton d'ami** (C-7) | l'inverser rend les deux appareils sourds, sans erreur |
| 3 | **le numéro de version du protocole** (D) | un octet faux = deux plateformes mutuellement invisibles |
| 4 | **le `txPower`** (E-10) | sans lui, toutes les distances sont fausses |
| 5 | **l'adresse BLE** (E-8) | elle tourne toute seule et fabrique de fausses personnes |
| 6 | **l'instant de l'annonce** (E-11) | un scan rejoué n'est pas une observation |
| 7 | **le `tableId`** (I-24) | sans lui, un rang désigne peut-être quelqu'un d'autre |
| 8 | **l'état du carnet d'amis** (H-18) | **il n'existe pas encore** — c'est le prochain chantier |
