# Audit du ping — 2026-08-28

**Méthode, à la demande de Jay** : lecture textuelle intégrale, chaîne de fonctions
suivie jusqu'au bout, **sans tenir compte des commentaires, des rapports ni de la
mémoire des sessions précédentes**. Chaque symbole suspecté mort a été vérifié par
recherche d'appelants dans `lib/`, `test/` et `android/`.

**Périmètre** : 23 fichiers Dart (`lib/features/proximity/**`, ~7 000 lignes) et
6 fichiers Kotlin (`android/.../ble/**`, ~2 400 lignes).

---

# 🔴 A. Défauts fonctionnels

## A1. Le plan d'émission natif n'est JAMAIS rafraîchi quand le carnet d'amis change

**C'est le défaut le plus grave de l'audit, et il explique un symptôme déjà
constaté.**

Chaîne relevée :

| Fait | Où |
|---|---|
| Tous les jetons émis viennent du plan natif | `ProximityService.emitNext` → `AdvertSchedule.tokensAt` |
| Le plan est déposé par `refreshPlan()` | `proximity_supervisor.dart:284` |
| `refreshPlan()` n'a que **deux** appelants | `_engage()` (l.214) et un `Timer.periodic(1 h)` (l.225) |
| Rien n'écoute `_keyBook.changes` côté superviseur | vérifié : les seuls `changes.addListener` sont `peer_network.dart:138` et `ping_store.dart:190` |

**Conséquence, dans les deux sens :**

- **Ami accepté** → son jeton de paire n'est **pas émis** avant ≤ 1 h. Les deux
  appareils sont dans le même cas, donc **aucune reconnaissance BLE, aucune
  distance, aucun constat de croisement** pendant ce temps. La table de
  reconnaissance native n'est pas déposée non plus : le croisement app fermée est
  impossible lui aussi.
- **Ami retiré / bloqué** → on continue d'émettre son jeton et de le reconnaître
  pendant ≤ 1 h.

⚠️ `ProximityRepository.accept()` appelle bien `proximitySync.run()`, qui met à
jour le **carnet** et donc la reconnaissance **Dart**. Mais la reconnaissance Dart
n'a rien à reconnaître si personne n'émet. **Le correctif posé le 2026-08-27 ne
couvre que la moitié de la chaîne.**

🔎 Cela correspond exactement au contournement observé : *« j'ai désactivé et
réactivé le ping sur chaque appareil et là ça remarche »* — `setVisible(true)`
appelle `_engage()`, donc `refreshPlan()`.

**Correctif** : le superviseur doit s'abonner à `_keyBook.changes` et appeler
`refreshPlan()`, exactement comme `PeerNetwork` le fait pour sa table.

## A2. Récursion mutuelle sans borne entre `refreshPlan()` et `_engage()`

`proximity_supervisor.dart:322-330` :

```dart
} catch (_) {
  if (state.wantsVisible) await _engage();   // _engage() → refreshPlan()
}
```

`_engage()` (l.214) appelle `refreshPlan()`. Si le dépôt du plan échoue de façon
**reproductible** (service tué et non relancé, argument refusé), la boucle
`refreshPlan → catch → _engage → refreshPlan` tourne **sans borne ni délai**, et
chaque tour recalcule 48 créneaux × N amis de HMAC. Il n'y a ni compteur, ni
temporisation, ni condition d'arrêt.

## A3. `parallelRefused` n'est jamais remis à faux

`BleEngine.kt:130, 322, 437-438`. Un seul refus — y compris transitoire (pile
occupée, `onAdvertisingSetStarted` en échec) — pose `parallelRefused = true`
**définitivement** : ni `start()`, ni `stop()`, ni `applyAdverts` ne le
réinitialisent.

L'appareil bascule alors en mode **cycle** pour toute la vie du service : à N
jetons, celui d'un ami donné n'est en l'air que **1/N du temps** — précisément le
défaut d'échelle que le mode parallèle a été écrit pour supprimer. Observable
seulement par `stats().advertMode`, et rien ne rétablit le mode parallèle.

## A4. Les scans mis en tampon sont rejoués **sans horodatage**

`ProximityService.kt:116-125` — `BufferedScan` ne porte **aucune date**.
`replayTo` (l.513) les repasse tels quels au Dart, où `PeerRegistry.observe`
appelle `_now()` : une annonce captée il y a des heures devient une observation
**« maintenant »**.

Conséquences en chaîne :

1. `PeerNetwork._onScan` → `presence.identify` → `PeerIdentified` ;
2. `ProximityController._onPeerEvent` → `_maybeWave` → **notification « Le
   presque… » pour quelqu'un qui n'est plus là** ;
3. le pair apparaît ~5 s dans « Autour de toi » avant d'être élagué.

Le constat de croisement, lui, est protégé : `isStable` exige 10 s de contact
continu, que le rejeu ne peut pas produire. **La notification, non.**

## A5. `PingBeaconState.copyWith` efface `blocker` et `lastError`

`ping_beacon_service.dart:324-340` :

```dart
blocker: blocker,        // et non `blocker ?? this.blocker`
lastError: lastError,    // idem
```

Tout appel qui ne les passe pas les **remet à nul**. En particulier
`_flushHeard()` (l.252) fait `copyWith(confirmed: …)` toutes les 60 s : **il
efface le bandeau de permission de localisation** posé par `_tick`. L'écran cache
donc un blocage encore vrai, jusqu'au tour suivant.

## A6. Le renoncement de découverte est calibré trop court

`ping_nearby_feed.dart:161` — `_maxDemandes = 6`, à 10 s le tour, soit **60 s**.

Or le pire cas d'appariement est du même ordre : le jeton d'en face n'entre dans
ma liste d'écoute qu'après **sa** republication de balise
(`PingBeaconService.refreshEvery` = 60 s), plus l'aller-retour serveur. Le
renoncement peut donc tomber **au moment précis où le serveur devient capable de
nommer le jeton**.

Aggravant : `_sansReponse` n'est purgé qu'au **changement de créneau**
(`refresh()`, l.248). Un jeton abandonné à tort le reste donc jusqu'à **15
minutes**, même s'il est réentendu en permanence.

## A7. `isFriendProvider` peut écrire dans un contrôleur fermé

`ping_store.dart:185-188` :

```dart
if (controller.isClosed) return;
controller.add((await book.all()).containsKey(userId));  // ← le test date d'avant l'await
```

`emit` est enregistré comme écouteur (`addListener(emit)`) et son `Future` n'est
jamais attendu : si la disposition survient pendant l'`await`, `controller.add`
lève un `StateError` **asynchrone et non rattrapé**.

## A8. « Croisés récemment » n'a aucun filtre de temps

`croisesRecemmentProvider` (`ping_nearby_feed.dart:344`) = source − à portée.
Aucun `expiryClockProvider`, aucun seuil.

La source n'est remplacée qu'à un `refresh()`, qui peut n'arriver qu'au
changement de créneau (**15 min**), alors que le serveur refuse la demande d'ami
au-delà de **10 min** (`private.fenetre_rencontre()`). La section peut donc
afficher des gens dont le bouton **ne peut plus que dire non** — ce que sa propre
conception cherchait à éviter.

---

# 🟡 B. Incohérences d'architecture

## B1. `ProximityLevel` est calculé, transporté, comparé — et jamais affiché

`PeerSession.level` + `_levelFor` + hystérésis `enterVeryClose/-58`,
`leaveVeryClose/-66` → `PresencePeer.level` → `PeerView.level`, **inclus dans
`PeerView.==` et `hashCode`** (`presence_feed.dart:94, 106`).

**Aucun écran ne le lit.** Un basculement de niveau force donc la reconstruction
d'une tuile pour une valeur invisible — et c'est un **second modèle de distance**
à côté de `ProximityBand` (seuil −55, hystérésis 6 dB), avec des seuils
différents.

## B2. Deux constantes `protocolVersion`, deux valeurs

| | Valeur | Sur le fil ? | Lecteur |
|---|---|---|---|
| `BleConstants.PROTOCOL_VERSION` (Kotlin) | **5** | oui, `payload[2]` | `BleEngine:665`, `stats()` |
| `ProximityIdentity.protocolVersion` (Dart) | **3** | **non** | **aucun** |

Le diagnostic affiche la valeur **native**. La constante Dart n'a aucun lecteur et
contredit celle qui compte.

## B3. Deux branches inatteignables

- `proximity_supervisor.dart:260` — `if (plan.isEmpty) return;` : le superviseur
  passe **toujours** `pingSeed: _identity.pingSeed()`, qui n'est jamais nul, donc
  le plan contient toujours au moins un jeton public par créneau. Corollaire :
  **aucun appelant ne passe `pingSeed: null`**, donc la distinction « croiser ses
  amis » / « se rendre découvrable » n'existe pas dans le câblage — un seul
  interrupteur fait les deux.
- `ping_screen.dart:518` — `if (!estAmi) _BoutonDemande(...)` sur `_TuilePair`,
  alors que cette tuile ne liste que des pairs **identifiés**, et qu'une identité
  ne vient que du carnet d'amis. Branche atteignable seulement dans la fenêtre où
  un ami vient d'être retiré et sa session vit encore.

## B4. Un appareil produit deux sessions de présence

`PeerRegistry.observe` regroupe par **jeton**. Un appareil en mode parallèle émet
un jeton public **et** un jeton d'ami : deux jetons inconnus l'un de l'autre, donc
**deux sessions**, dont une seule sera identifiée (`identify` ne fusionne que sur
`userId`). Sans effet sur les listes affichées (`presenceKeysProvider` ne garde
que les identifiés) ni sur les constats (`userId == null` est écarté), mais
`presence.length` et le compte de sessions valent **le double**.

## B5. `BleRadio` est construit à quatre endroits

`proximity_supervisor.dart:75`, `proximity_controller.dart:218`,
`proximity_diagnostic_screen.dart:58` et `core/diagnostics/diagnostic_bundle.dart:136`.
La classe est sans état, donc sans conséquence fonctionnelle — mais deux de ces
points sont un **écran** et un **collecteur de rapport** qui parlent directement
au canal natif.

## B6. `_teardown` lit un autre provider depuis `onDispose`

`proximity_controller.dart:117` — `ref.read(presenceProvider.notifier).clear()`
dans un `onDispose`. Correct lors d'une reconstruction ; risqué lors d'une
disposition de conteneur.

---

# ⚫ C. Code mort — vérifié par recherche d'appelants

## C1. Aucun appelant nulle part

| Symbole | Fichier |
|---|---|
| `TokenResolver` (typedef) | `net/sighting_log.dart:138` |
| `SightingLog.clear()` | `net/sighting_log.dart:130` |
| `ProximitySync.abandoned` | `net/proximity_sync.dart:51` — incrémenté 2 fois, **jamais lu** |
| `kPingGrace` | `net/ping_nearby_feed.dart:35` — cité seulement par des commentaires |
| `canalProximiteOuvertProvider` | `net/ping_nearby_feed.dart:392` |
| `AdvertPlan.covers` | `net/advert_plan.dart:90` |
| `RecognitionTable.covers` / `.length` | `net/advert_plan.dart:107, 109` |
| `AdvertToken.isPublic` | `net/advert_plan.dart:57` |
| `NativeRecognitionTable.isEmpty` | `net/advert_plan.dart:297` |
| `RadioScan.hasTxPower` | `net/radio_status.dart:217` |
| `BleRadio.advertCapabilities()` | `net/ble_radio.dart:159` — **avec** le cas `"advertCapabilities"` du pont (`ProximityBridge.kt:212`) et `ProximityService.advertCapabilities()` (l.360) |
| `ProximityIdentity.protocolVersion` | `proximity_identity.dart:113` |
| `FriendKeyStore.put` / `.remove` | `proximity_identity.dart:376, 377` + leur implémentation |
| `RecognitionTable.validUntilMillis` | `ble/SightingBook.kt:83` |
| `ProximityService.sightingCount()` | `ble/ProximityService.kt:284` |

## C2. Aucun appelant de production — utilisés seulement par les tests

Ceux-là **soutiennent des tests réels** ; les retirer demande de réécrire le test
correspondant, pas seulement de couper la ligne.

| Symbole | Test qui s'en sert |
|---|---|
| `PeerSession.contactDuration` | `peer_session_test.dart:239, 313` |
| `PeerRegistry.byAddress` | `peer_network_test.dart:324`, `peer_session_test.dart:300` |
| `PeerRegistry.identifiedCount` | `peer_network_test.dart:222, 372` |
| `PeerRegistry.isPresent` (et `byUser`, son seul appelant) | `peer_session_test.dart:148, 158, 341` |
| `PeerNetwork.foreignTokenScans` | `peer_network_test.dart:182, 194` |

⚠️ `foreignTokenScans` existe **aussi** côté natif (`BleEngine.kt:166`), et c'est
**celui-là** que le diagnostic publie. Le compteur Dart est un doublon sans
lecteur.

---

# Ce qui a été vérifié et tenu

Pour être juste, ces chaînes ont été suivies jusqu'au bout et sont correctes :

- **Le filtre anti-soi couvre les deux modes d'émission** : `applyAdverts` appelle
  `rememberOwnToken` (l.352) **avant** le test de faisabilité du parallèle, donc
  le repli en cycle est couvert lui aussi.
- **Le sens des jetons est cohérent** : `plan()` émet avec `emitter = moi`,
  `table()` et `nativeTable()` attendent avec `emitter = lui`.
- **Le carnet est en cache mémoire** (`FriendKeyBook._cache`) : les appels à
  `_isFriend` dans le balayage de 2 s ne touchent pas le disque après le premier
  chargement.
- **La version de protocole est bien sur le fil** (`payload[2]`) et un écart se
  **compte** (`otherVersionScans`) au lieu de disparaître.
- **La reconnaissance native ne traite que les jetons privés**
  (`ProximityService.kt:472`), et la table ne contient aucune identité.
