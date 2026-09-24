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

Nous en mettons **deux** :

```
 octet  0                                          24        27        30
        ┌──────────────────────────────────────────┬─────────┬─────────┐
        │            DONNÉES FABRICANT             │PUISSANCE│  libre  │
        │                  24 o                    │  3 o    │  4 o    │
        └──────────────────────────────────────────┴─────────┴─────────┘
         2 o d'étiquette + 2 o fabricant + 20 o à nous  Android
```

**27 octets occupés sur 31. Il en reste 4** (depuis le 2026-09-24,
v0.9.252 ; avant, une troisième boîte « drapeaux » de 3 octets, ajoutée par
Android parce que l'annonce était connectable, en occupait 30).

*(Le schéma du 2026-09-23 plaçait la puissance avant les données fabricant ;
le tableau ci-dessous, vérifié dans le code d'Android, dit l'inverse — c'est
le tableau qui avait raison.)*

---

## 2. Le détail

| Octet | Valeur | Ce que c'est | Qui l'écrit |
|---|---|---|---|
| **0** | `0x17` | longueur de la boîte « données fabricant » : 23 octets suivent | Android |
| **1** | `0xFF` | type : données fabricant | Android |
| **2–3** | `0xFF 0xFF` | identifiant fabricant `0xFFFF` = « aucun fabricant enregistré » (écrit poids faible d'abord) | nous (`MANUFACTURER_ID`) |
| **4–5** | `0x4E 0x56` | `N` `V` : la signature NeoVibe | nous (`MAGIC`) |
| **6** | `0x05` | **version du protocole** | nous (`PROTOCOL_VERSION`) |
| **7** | `0x01` / `0x02` | **type de jeton** : `0x01` public (pour les inconnus) · `0x02` ami | nous (`TYPE_PUBLIC` / `TYPE_FRIEND`) |
| **8–23** | 16 octets | **le jeton** — voir §3 | nous |
| **24** | `0x02` | longueur de la boîte « puissance d'émission » | Android |
| **25** | `0x0A` | type : puissance d'émission | Android |
| **26** | ex. `0xF9` | la puissance réelle, en dBm (un nombre négatif) | **Android la remplit** au moment d'émettre |
| **27–30** | — | **libres** | — |

Nos **20 octets** sont les octets **4 à 23** : `ADVERT_PAYLOAD_SIZE = 20`.

⚠️ **Rien ne lit une position fixe.** Le récepteur demande à Android « la
boîte fabricant `0xFFFF` » (`getManufacturerSpecificData`), où qu'elle soit :
retirer les drapeaux décale les numéros de ce tableau, pas ce que lit le
récepteur. C'est pourquoi le changement ne change pas la version du
protocole (toujours **5**) — un téléphone en v0.9.251 et un en v0.9.252 se
voient encore.

### Comment ça a été vérifié (2026-09-23)

| Affirmation | Source |
|---|---|
| nos 20 octets, leur ordre, les constantes | `BleEngine.advertDataFor` et `RadioStatus.kt` (objet `BleConstants`) |
| l'ordre des boîtes : fabricant **puis** puissance | code source d'Android 13, `AdvertiseHelper.advertiseDataToBytes` |
| les drapeaux ajoutés **en tête**, **seulement si l'annonce est connectable** — donc absents chez nous | code source d'Android 13, `btm_ble_multi_adv.cc` (lignes 739–749) |
| notre annonce n'est **plus** connectable (2026-09-24) | `BleEngine.kt` : `neoAdvertParams()` (mode parallèle et sonde de capacité) et `.setConnectable(false)` dans `startAdvertising` (mode cycle) |

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

| Type (octet 7) | Formule | Qui le reconnaît |
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
puissance reçue (RSSI) — qui, comparée à l'octet 26, donne une estimation
de distance.

---

## 5. Ce qui reste ouvert

- ✅ **Les 3 octets de drapeaux sont retirés (2026-09-24, v0.9.252).** Ils
  n'existaient que parce que l'annonce était « connectable », réglage du canal
  de connexion directe (GATT) supprimé le 2026-08-27. Vérifié avant de couper :
  aucun code ne se connecte ni ne sert de serveur (`connectGatt`,
  `openGattServer`, `BluetoothGatt` : zéro), la permission `BLUETOOTH_CONNECT`
  est déjà retirée, aucune réponse de scan n'est fournie, le récepteur ne lit
  ni les drapeaux ni le type d'annonce. ⚠️ Change ce qui part sur les ondes :
  **à confirmer au test à deux téléphones du week-end** (`neoScans` doit rester
  comparable ; nRF Connect doit montrer une annonce « non connectable » sans
  boîte de drapeaux).
- 🔴 **L'octet 26 est peut-être émis pour rien — PROBABLE, NON MESURÉ.** Le
  récepteur lit la puissance par `ScanResult.txPower` (`onScanResult`). D'après
  la documentation d'Android, ce champ vient de **l'en-tête des annonces
  étendues**, pas de notre boîte « puissance » : pour une annonce classique
  comme la nôtre, il vaudrait toujours 127 (« absent »). Notre boîte se lit
  par `scanRecord.txPowerLevel`, que rien n'appelle. Si c'est confirmé,
  l'estimation de distance tourne **toujours** sur la valeur supposée
  (`distance_estimate.dart`, `txPower != 127`), et les 3 octets de la boîte
  ne servent à rien. À mesurer avant de corriger (règle 7).
  ✅ **Instrument posé en v0.9.251** : `txAnnonces`, `txEnTetePresent`,
  `txBoitePresent` (+ dernières valeurs) au diagnostic, avec une ligne
  « LECTURE : … PUISSANCE » qui conclut d'elle-même. Il faut **deux
  téléphones** : il ne compte que les annonces NeoVibe d'un autre appareil.
- **Protocole v6** (RAPPELS #159) : une annonce filtrable par la puce
  (identifiant de service 16 bits). Toute place gagnée ici compte pour lui.
- **Version** : un seul octet, et deux versions différentes ne se voient
  pas. Les deux téléphones de test se mettent à jour **ensemble**.
