# L'annonce BLE du ping — octet par octet

> Écrit le **2026-09-23** à la demande de Jay. Remplace la section D de
> `donnees-du-ping.md` (qui ne décrivait que nos 20 octets) et le chiffre
> périmé « on en occupe 28 » de `moteur-spatial-et-transports.md`.
>
> **Protocole v5.** Si l'un des chiffres ci-dessous change dans le code, ce
> document est faux : le mettre à jour dans le même commit.

---

## 1. L'image

Une annonce BLE est une **enveloppe de 31 cases** (31 octets), qu'un téléphone
crie en boucle — chez nous toutes les **250 ms** (`ADVERT_INTERVAL`). Tous les
téléphones autour l'entendent, NeoVibe ou pas.

Dans l'enveloppe, on range des **petites boîtes**. Chaque boîte commence par
deux cases d'étiquette : **sa longueur**, puis **son type**. C'est tout ce
qu'un récepteur a besoin de savoir pour les séparer.

Nous en mettons **trois** :

```
 octet  0         3         6                                          30
        ┌─────────┬─────────┬───────────────────────────────────────────┬──┐
        │ DRAPEAUX│PUISSANCE│          DONNÉES FABRICANT                │  │
        │  3 o    │  3 o    │               24 o                        │1 │
        └─────────┴─────────┴───────────────────────────────────────────┴──┘
          Android   Android    2 o d'étiquette + 2 o fabricant + 20 o à nous  libre
```

**30 octets occupés sur 31. Il en reste 1.**

---

## 2. Le détail

| Octet | Valeur | Ce que c'est | Qui l'écrit |
|---|---|---|---|
| **0** | `0x02` | longueur de la boîte « drapeaux » (2 octets suivent) | Android |
| **1** | `0x01` | type : drapeaux | Android |
| **2** | `0x02` | « appareil visible par tous » (*general discoverable*) | Android |
| **3** | `0x17` | longueur de la boîte « données fabricant » : 23 octets suivent | Android |
| **4** | `0xFF` | type : données fabricant | Android |
| **5–6** | `0xFF 0xFF` | identifiant fabricant `0xFFFF` = « aucun fabricant enregistré » (écrit poids faible d'abord) | nous (`MANUFACTURER_ID`) |
| **7–8** | `0x4E 0x56` | `N` `V` : la signature NeoVibe | nous (`MAGIC`) |
| **9** | `0x05` | **version du protocole** | nous (`PROTOCOL_VERSION`) |
| **10** | `0x01` / `0x02` | **type de jeton** : `0x01` public (pour les inconnus) · `0x02` ami | nous (`TYPE_PUBLIC` / `TYPE_FRIEND`) |
| **11–26** | 16 octets | **le jeton** — voir §3 | nous |
| **27** | `0x02` | longueur de la boîte « puissance d'émission » | Android |
| **28** | `0x0A` | type : puissance d'émission | Android |
| **29** | ex. `0xF9` | la puissance réelle, en dBm (un nombre négatif) | **Android la remplit** au moment d'émettre |
| **30** | — | **libre** | — |

Nos **20 octets** sont les octets **7 à 26** : `ADVERT_PAYLOAD_SIZE = 20`.

### Comment ça a été vérifié (2026-09-23)

| Affirmation | Source |
|---|---|
| nos 20 octets, leur ordre, les constantes | `BleEngine.advertDataFor` et `RadioStatus.kt` (objet `BleConstants`) |
| l'ordre des boîtes : fabricant **puis** puissance | code source d'Android 13, `AdvertiseHelper.advertiseDataToBytes` |
| les drapeaux ajoutés **en tête**, **seulement si l'annonce est connectable**, valeur *general discoverable* | code source d'Android 13, `btm_ble_multi_adv.cc` (lignes 739–749) |
| notre annonce est connectable | `BleEngine.kt` : `.setConnectable(true)` dans les deux modes (parallèle et cycle) |

⚠️ **Pas encore mesuré sur les ondes.** Le code source dit ce qu'Android
*devrait* émettre ; Xiaomi peut modifier sa pile Bluetooth. La seule preuve
définitive : lire le paquet brut avec l'app gratuite **nRF Connect** sur un
second téléphone. À faire au test du week-end.

---

## 3. Le jeton — les 16 octets qui comptent

Un jeton est **opaque** : ni nom, ni pseudo, ni identifiant de compte. Il
change **toutes les 15 minutes** (`slotDuration`, créneau calculé en UTC),
pour qu'un observateur ne puisse pas suivre quelqu'un d'un quart d'heure à
l'autre. C'est un HMAC-SHA256 **tronqué à 16 octets**
(`proximity_identity.dart`) :

| Type (octet 10) | Formule | Qui le reconnaît |
|---|---|---|
| `0x01` **public** | `HMAC(graine ping, "nv-ping-{créneau}")` | **personne sur place** — seul le serveur sait à qui il appartient |
| `0x02` **ami** | `HMAC(secret de la paire, "nv-pair-{créneau}\|{celui qui crie}")` | **cet ami-là, et lui seul** — un jeton différent par ami |

Le secret de paire vient d'un échange Diffie-Hellman (X25519) : les deux amis
le calculent chacun de leur côté, il ne voyage jamais.

⚠️ **« celui qui crie » dans la formule n'est pas décoratif.** Sans lui, les
deux amis criaient le même jeton, et chacun jetait celui de l'autre en le
prenant pour le sien (panne du 2026-08-26).

---

## 4. Ce que le récepteur fait de l'enveloppe (`BleEngine.onScanResult`)

1. il **compte** l'annonce, quelle qu'elle soit (`rawScans`) ;
2. il cherche la boîte fabricant `0xFFFF` ; pas de boîte → ignorée ;
3. il vérifie qu'elle fait **exactement 20 octets** et commence par `NV` →
   sinon ignorée ; si oui : `neoScans` ;
4. il lit la **version** : différente de la sienne → comptée à part
   (`otherVersionScans`), **jamais** prise pour « personne autour » ;
5. il écarte ses **propres** jetons (`selfScans`) ;
6. le jeton part au carnet (ami) ou au serveur (public).

Ce que la radio **mesure** sans que ce soit dans le paquet : l'adresse
Bluetooth de l'émetteur (aléatoire, Android la change tout seul), et la
puissance reçue (RSSI) — qui, comparée à l'octet 29, donne une estimation
de distance.

---

## 5. Ce qui reste ouvert

- **Les 3 octets de drapeaux sont un reste.** Ils n'existent que parce que
  l'annonce est « connectable » ; ce réglage servait au canal de connexion
  directe (GATT), **supprimé le 2026-08-27** — le commentaire du code dit
  encore « le chat passe par le GATT ». Passer en non-connectable libérerait
  3 octets (4 libres au total) et fermerait une porte devenue inutile.
  ⚠️ Change ce qui part sur les ondes : à éprouver sur les deux téléphones
  avant de le garder. Proposé à Jay le 2026-09-23, prévu pour le week-end.
- 🔴 **L'octet 29 est peut-être émis pour rien — PROBABLE, NON MESURÉ.** Le
  récepteur lit la puissance par `ScanResult.txPower` (`onScanResult`). D'après
  la documentation d'Android, ce champ vient de **l'en-tête des annonces
  étendues**, pas de notre boîte « puissance » : pour une annonce classique
  comme la nôtre, il vaudrait toujours 127 (« absent »). Notre boîte se lit
  par `scanRecord.txPowerLevel`, que rien n'appelle. Si c'est confirmé,
  l'estimation de distance tourne **toujours** sur la valeur supposée
  (`distance_estimate.dart`, `txPower != 127`), et les 3 octets de la boîte
  ne servent à rien. À mesurer avant de corriger (règle 7) : compter, par
  annonce NeoVibe reçue, les deux valeurs côte à côte.
- **Protocole v6** (RAPPELS #159) : une annonce filtrable par la puce
  (identifiant de service 16 bits). Toute place gagnée ici compte pour lui.
- **Version** : un seul octet, et deux versions différentes ne se voient
  pas. Les deux téléphones de test se mettent à jour **ensemble**.
