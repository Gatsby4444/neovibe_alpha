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

> ⚠️ **Deux corrections sur cette couche le 2026-08-18**, toutes deux invisibles
> à l'usage et toutes deux graves.
>
> **La clé de diffusion ne tournait jamais.** Écrite une fois à l'installation,
> plus jamais régénérée : un ex-ami qui l'avait téléchargée pouvait nous
> reconnaître **à vie**, hors ligne et en silence. La politique RLS l'empêche de
> la relire — elle ne reprend pas ce qu'il a déjà copié sur son appareil. Pour
> une app dont la thèse est le cercle restreint, retirer un ami ne retirait rien.
> Elle tourne désormais tous les **7 jours** (décision de Jay), la précédente
> reste publiée pour qu'une rotation n'aveugle personne, et le retrait d'un ami
> déclenche une **révocation** qui, elle, jette l'ancienne.
>
> **Cinq instances, et une course au premier lancement.** `ProximityIdentity` se
> construisait avec `new` à cinq endroits, sans verrou d'initialisation :
> au tout premier démarrage, superviseur et synchro généraient chacun leur clé et
> l'écrivaient. Mesuré : **quatre clés d'appareil créées au lieu d'une**. On
> pouvait diffuser un ID dérivé de la clé A pendant que le serveur recevait la
> clé B. C'est exactement le défaut corrigé pour le carnet d'amis la veille — le
> raisonnement n'avait jamais été appliqué à l'identité elle-même.

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

#### ⚠️ La session appartient au COUPLE DE CLÉS ÉPHÉMÈRES (2026-08-17)

Elle appartenait à un **rôle** — initiateur ou répondeur — déduit de qui avait
composé le numéro. C'est ce qui a produit la quatrième cause de message fantôme,
mesurée sur les deux appareils de Jay.

Le rôle est un fait de **transport**, et les deux côtés ne le lisent pas toujours
pareil : deux liens qui se croisent, ou une session reconstruite d'un seul côté,
et les deux peuvent se croire initiateurs. Mêmes clés, **préfixes de nonce
opposés**, et AES-GCM refuse tout — sans un mot.

Trois règles remplacent le rôle, et chacune est vérifiable des deux côtés sans se
concerter :

| Question | Ce qui y répond maintenant |
|---|---|
| Quelle est la session courante ? | le couple `(ma clé éphémère, la sienne)` |
| Dans quel sens va cette trame ? | l'**ordre** des deux clés éphémères |
| Qui parle en premier ? | **les deux** — plus personne n'attend |

Et une quatrième, qui est le correctif proprement dit :

> **Un `hello` reçu est une demande de session, et elle l'emporte toujours.**
> Un pair ne l'envoie que s'il n'a plus de session. Garder la nôtre ne peut alors
> produire que du silence.

Reconstruire, c'est **tout ou rien** : nouvelle clé éphémère, nouvelle clé de
session, **compteurs remis à zéro**. Le défaut relevé était exactement une
reconstruction à moitié — la clé suivait, pas les compteurs, et toutes les trames
du pair étaient refusées (`déchiffrement refusé, compteur 0 puis 1`).

⚠️ **Un `hello` répété ne reconstruit rien** (même clé éphémère) : sinon il
suffirait d'en rejouer un pour désarmer l'anti-rejeu.

⚠️ **Changement de protocole** : les deux appareils doivent être à la même
version. Un ancien et un nouveau ne se comprendront pas.

### 4 — Présence et sessions (`peer_session.dart`)

**Un objet par pair, et un seul** : `PeerSession`. Elle porte ses adresses BLE
(Android renouvelle sa MAC), ses observations, son lien, son canal, son identité
et ses marqueurs. `PeerRegistry` les tient, et la présence n'est qu'une
**projection en lecture seule** de ce registre.

> ⚠️ **Refonte du 2026-08-18.** Le réseau tenait **neuf collections indexées par
> adresse**, à nettoyer ensemble à la main à chaque sortie. Tous les défauts du
> chantier sont le même : *la collection X a été nettoyée, la Y non* — au point
> que la boucle de nettoyage des adresses fusionnées existait **en deux
> exemplaires dont les corps avaient divergé**. Fermer un pair est désormais
> **un geste** (`release()`), impossible à faire à moitié.

Le stade n'est plus un champ mais un **calcul** — il était écrit par trois
chemins, dont l'un l'oubliait toujours :

```
detected      // vu par la radio, identité inconnue
identifying   // un lien est ouvert ou en cours
identified    // profil connu (ami reconnu, ou inconnu révélé)
```

#### Les règles de présence, en secondes (`PresenceRules`)

Il n'y a **qu'une** définition de « il est là », et tout ce qui est visible ou
irréversible s'y adosse — affichage, envoi d'un message, certificat, barrière du
produit :

| Règle | Valeur | Ce qu'elle décide |
|---|---|---|
| `freshFor` | **5 s** | « il est là maintenant » (décision de Jay, 2026-08-18) |
| `stableAfter` | **10 s** + 5 annonces | avant d'ouvrir un lien vers un **inconnu**, et avant de certifier un croisement |
| `forgetAfter` | **30 s** | on oublie la session et on referme son transport |

⚠️ **`freshFor` et `forgetAfter` ne sont pas deux délais de grâce.** Cesser de
dire « il est là » et démonter une session chiffrée sont deux décisions
différentes : la première répond à l'utilisateur, la seconde détruit un état
partagé avec le pair. Les confondre reconstruit le défaut d'origine.

⚠️ **Une trame reçue vaut observation**, au même titre qu'une annonce. C'est ce
qui rend une fraîcheur de 5 s tenable sans réintroduire une seconde horloge —
et c'est le désaccord entre ces deux horloges qui avait produit les cinq causes
de « message fantôme ».

⚠️ **`stableAfter` est une durée, pas un compte d'annonces.** L'intention de Jay
(« 15 pings en 20 secondes ») est de ne pas payer une poignée de main pour un
passant ou une voiture qui s'arrête au feu. Mais l'advertising BLE tourne à
~100 ms : « 15 annonces » est atteint en moins de deux secondes et ne filtre
rien. Un **ami** reconnu à son ID rotatif n'est pas concerné — le reconnaître ne
coûte rien.

Cette couche porte aussi le lissage du RSSI et l'**hystérésis** : un pair ne doit
pas clignoter dans la liste au gré d'une mesure qui varie de 10 dB d'une seconde
à l'autre.

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
| 2 — Identité (`ProximityIdentity`) | ✅ *(rotation + verrou, 2026-08-18)* | **7** |
| 3 — Canal sécurisé (`SecureChannel`) | ✅ | **9** |
| 4 — Présence et sessions (`peer_session.dart`) | ✅ *(refondue le 2026-08-18)* | **18** |
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
