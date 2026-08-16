# Architecture de la proximité — reconstruction (chantier du 2026-08-16)

Carte blanche donnée par Jay le 2026-08-16, périmètre **ping et réseau P2P
uniquement**. Objectif fixé par lui :

> Le système de localisation et de détection de proximité est fiable, sécurisé et
> fluide. L'app détecte précisément la proximité entre plusieurs utilisateurs, le
> chat BLE P2P fonctionne. Le système résiste aux aléas (fermer/rouvrir l'app,
> quitter la page, couper puis remettre le Bluetooth ou le Wi-Fi). Il s'adapte à
> tous les appareils Android. Le code est cohérent, robuste, scalable, et
> respecte la séparation des fonctions et des technologies.

**Pas de release tant que ce chantier n'est pas terminé** (consigne de Jay).

---

## Ce qu'on garde, et pourquoi

Tout n'est pas à jeter. **La couche cryptographique est saine** et reste :

- `ProximityIdentity` — Ed25519 dans le Keystore Android, clé de diffusion 32 o,
  ID rotatif = `HMAC-SHA256(broadcastKey, créneau de 15 min)` tronqué à 16 o.
- `FriendKeyBook` — carnet local, index rotatif sur `[slot-1, slot, slot+1]`
  (tolérance d'horloge entre appareils : détail juste, et facile à oublier).

Ces deux-là sont déjà des couches propres : une responsabilité, aucune
dépendance vers le haut. Elles servent de modèle au reste.

## Ce qui est refait, et pourquoi

`proximity_service.dart` fait **1040 lignes** et porte à lui seul : cycle de vie
radio, permissions, scan, rotation d'identité, poignée de main, chiffrement,
découpage de trames, chat, certificats de croisement, demandes d'amis, waves et
synchronisation serveur.

C'est exactement ce que la règle impérative de `CLAUDE.md` interdit — *« on ne
mélange pas tout, on sépare clairement et distinctement tout ce que l'on peut »*
— et c'est la cause commune des 13 défauts du diagnostic
(`docs/diagnostic-proximite-2026-08-16.md`) : quand une seule classe sait tout,
un défaut de radio se manifeste comme un défaut d'interface, et personne ne peut
le situer.

---

## Les deux décisions de Jay (2026-08-16)

### ① Le ping vit en **natif Kotlin**, dans un service dédié

Le BLE appartient au service de premier plan, en Kotlin. Le Dart n'est plus qu'un
**client** : il affiche, il décide au niveau produit, il ne touche pas la radio.

**Ce que ça règle** : la détection survit à la destruction de l'activité — c'est
la seule façon d'être réellement résistant sur Android. Aujourd'hui, le service
de premier plan ne fait que maintenir le processus en vie pendant que tout le
travail reste dans l'isolate de l'interface.

⚠️ **Ce que ça engage** : c'est le même arbitrage que pour le lecteur vidéo
(2026-08-12) — la robustesse d'abord, au prix d'un portage à écrire par OS. **Le
portage iOS devra concevoir un mode dégradé** : CoreBluetooth en arrière-plan est
bridé par le système (pas d'advertising avec données de fabricant en arrière-plan
notamment). À inscrire au catalogue natif dès la fin de ce chantier.

### ② Le certificat entre amis : **échange court réservé aux amis**

Deux amis partagent déjà leurs clés (`FriendKeyBook`). Le certificat de
croisement se fait donc en **deux trames signées**, sans poignée de main X25519
complète — celle-ci reste réservée à la révélation d'un inconnu.

**Ce que ça règle** : le certificat existe enfin pour le cas qu'il doit servir
(défaut B1), sans payer une session complète sur le geste le plus fréquent du
produit. Le serveur continue de vérifier **les deux signatures** : la garantie
« croisement réellement constaté à deux » est conservée.

---

## Les couches

Chacune ignore totalement celles du dessus. Chacune est testable seule.

### 0 — Radio (`NativeBle.kt` + `BleRadio`)

**Possède le matériel.** Advertising, scan, serveur et client GATT.

**Le changement de contrat, qui est le cœur du chantier** : elle publie un
**état vrai**, jamais un succès nu.

```
RadioState =
  | unsupported                  // pas de BLE sur l'appareil
  | permissionsMissing(Set)      // lesquelles, précisément
  | adapterOff                   // Bluetooth éteint
  | starting
  | running(advertising, scanning)
  | failed(code, message)
```

Le natif écoute `BluetoothAdapter.ACTION_STATE_CHANGED` et pousse la transition.
**Aucun `?: return` silencieux ne subsiste** : l'absence d'advertiser est un
état, pas un non-événement. *(Corrige A1 et A2.)*

Ignore tout de NeoVibe : ni identité, ni crypto, ni profil.

### 1 — Transport (`PeerLink`)

Découpage MTU, préfixe de longueur, réassemblage, **file d'écriture par lien**.

⚠️ Défaut supplémentaire trouvé en concevant cette couche : aujourd'hui `send()`
écrit ses morceaux en `await` successifs **sans file**. Deux trames envoyées en
même temps sur le même lien entrelacent leurs morceaux et **corrompent les
deux** — silencieusement, puisque le réassembleur ne voit qu'un flux d'octets.
Ce n'était pas dans le diagnostic ; il n'apparaît qu'en cas d'envoi concurrent.

Ignore le sens des octets.

### 2 — Identité (`ProximityIdentity`, `FriendKeyBook`) — *conservée*

### 3 — Canal sécurisé (`SecureChannel`)

Poignée de main X25519 → AES-GCM, avec **anti-rejeu** (compteur de trames) et une
machine à états explicite : `opening` → `established` → `closed`.

Ignore le sens des messages qu'elle chiffre.

### 4 — Présence (`PresenceTracker`)

**La source de vérité unique de « qui est autour »**, avec un état explicite par
pair :

```
detected      // vu par la radio, identité inconnue
identifying   // poignée de main en cours
identified    // profil connu (ami reconnu, ou inconnu révélé)
lost
```

*(Corrige B5 : l'interface peut enfin distinguer « personne » de « quelqu'un, en
cours ». Aujourd'hui les deux affichent « Personne à proximité ».)*

Porte aussi le lissage du RSSI et l'**hystérésis** : un pair ne doit pas
clignoter dans la liste au gré d'une mesure de puissance qui varie de 10 dB d'une
seconde à l'autre.

### 5 — Protocole (`ProximityProtocol`)

Trames **typées et versionnées**, un seul endroit qui connaît le format du fil,
avec tests d'aller-retour. *(Le format change : aucune contrainte de
compatibilité, il n'y a que deux appareils en développement et aucune
production.)*

### 6 — Fonctions

Chacune indépendante, avec son propre magasin, abonnée à la présence et au
protocole — **aucune ne parle à la radio** :

- `EncounterService` — certificats de croisement co-signés ;
- `PingChatService` — chat local, TTL 12 h ;
- `FriendRequestService` — demandes d'amis, **persistantes et multiples** ;
- `WaveService` — « le presque », avec un cooldown **persisté**.

### 7 — Synchronisation (`ProximityOutbox`, `ProximitySync`)

File durable avec **politique de reprise par élément** : distinguer « pas de
réseau » (retenter) de « le serveur refuse » (abandonner et signaler). Profils
récupérés **en lot** et non un par un.

---

## La pièce transverse : l'INTENTION n'est pas l'ÉTAT

C'est la clé de la résistance aux aléas, et ça n'existe pas aujourd'hui.

| | Aujourd'hui | Après |
|---|---|---|
| L'utilisateur veut être visible | `state.visible`, en mémoire | **`ProximityIntent`, persisté** |
| Le matériel tourne vraiment | *confondu avec ci-dessus* | `RadioState`, publié par la radio |

Un **superviseur** réconcilie les deux en permanence : tant que l'intention est
« visible », il rétablit la radio dès qu'elle redevient possible.

Ce que ça règle, directement et sans cas particulier :

- **app fermée puis rouverte** → l'intention est relue, la radio repart ;
- **Bluetooth coupé puis remis** → l'état passe par `adapterOff`, le superviseur
  redémarre tout seul (aujourd'hui il faut couper/remettre l'interrupteur de
  l'app, ce que personne ne devine) ;
- **permission refusée puis accordée** → même chemin ;
- **l'écran Ping quitté** → sans effet : l'intention ne dépend pas d'un widget.

*« Visible » cesse d'être un booléen d'interface pour devenir un contrat entre
l'utilisateur et le système.*

---

## Avancement — CHANTIER TERMINÉ le 2026-08-16

| Couche | État | Tests |
|---|---|---|
| 0 — Radio (natif + `BleRadio`) | ✅ | *(natif : à éprouver sur appareil)* |
| Intention / superviseur | ✅ | |
| 1 — Transport (`PeerLink`) | ✅ | **6** |
| 2 — Identité | ✅ conservée | |
| 3 — Canal sécurisé (`SecureChannel`) | ✅ | **9** |
| 4 — Présence (`PresenceTracker`) | ✅ | **10** |
| 5 — Protocole (`ProximityProtocol`) | ✅ | *(couvert par les 9)* |
| 6 — Réseau (`PeerNetwork`) + fonctions | ✅ | **6** (deux appareils complets) |
| 7 — Synchronisation (`ProximitySync`) | ✅ | |
| Journal durable | ✅ | **8** |
| Interface (`ping_screen.dart`) | ✅ | |

**L'ancien `proximity_service.dart` (1040 lignes) est supprimé**, avec ses deux
orphelins relevés dans le sens sortant : `ble_link.dart` et `NativeBle.kt`.

⚠️ **Ce qui n'a jamais tourné sur un appareil.** Tout compile, 102 tests
passent, et deux piles complètes dialoguent en test — mais **aucun octet n'est
encore passé par une vraie radio**. Les trois choses à vérifier en priorité :

1. le service survit-il à la fermeture de l'app (la notification reste, la
   détection continue) ;
2. couper puis remettre le Bluetooth relance-t-il tout seul ;
3. deux appareils réels se découvrent-ils, et en combien de temps.

## Ordre de construction

Chaque étape est testable seule et laisse l'app compilable.

1. **Radio honnête** (couche 0) + intention/superviseur — c'est ce qui rend tous
   les tests suivants interprétables.
2. **Transport** (couche 1), file d'écriture comprise.
3. **Canal sécurisé** (3) et **protocole** (5).
4. **Présence** (4) et l'interface qui en découle.
5. **Fonctions** (6), une par une.
6. **Synchronisation** (7).
