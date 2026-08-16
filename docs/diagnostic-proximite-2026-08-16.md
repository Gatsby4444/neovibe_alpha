# Diagnostic — proximité, Ping et connexions (2026-08-16)

Demandé par Jay après ses tests à deux appareils : *« dans mes tests j'ai
remarqué que tout n'était pas fonctionnel comme il faut à ce niveau. »*

**Périmètre réellement audité** : `proximity_service.dart` (1040 l.),
`proximity_repository.dart`, `ble_link.dart`, `ping_screen.dart`,
`connections_repository.dart`, `friends_list_screen.dart`, `NativeBle.kt`, plus
les politiques RLS de `device_keys`, `waves` et `connection_requests` relevées en
base.

**Non audité, à faire dans un second temps** : le chat ping et son TTL 12 h
(`ping_chat_screen.dart`, `ping_store.dart`), le parcours de recommandation
A→B→C et son plafond de 10/mois, les politiques temps réel de `connections`.

⚠️ **Tout ce qui suit est relevé dans le code ou en base.** Aucun de ces points
n'a été reproduit sur appareil — c'est la limite de ce rapport, et elle est
importante : la règle du projet est de reproduire avant de corriger. Les points
A1 et A2 sont toutefois lisibles directement dans le natif, sans ambiguïté.

---

## A. Les pannes silencieuses — l'app affirme que ça marche

Ces trois défauts partagent une signature : **l'interface annonce un succès, et
rien ne se passe.** C'est la pire catégorie, parce qu'aucun message d'erreur ne
mettra jamais sur la piste.

### A1. 🔴 Bluetooth éteint = panne totale et muette

`NativeBle.kt` :

| Ligne | Code | Si le Bluetooth est éteint |
|---|---|---|
| 134 | `val advertiser = adapter?.bluetoothLeAdvertiser ?: return` | **retour silencieux** |
| 174 | `val scanner = adapter?.bluetoothLeScanner ?: return` | **retour silencieux** |
| 265 | `manager.openGattServer(...) ?: return` | **retour silencieux** |

Et `onMethodCall` (l. 85-91) enchaîne les trois puis renvoie
`result.success(null)` **sans condition**.

Côté Dart, `enable()` considère donc l'opération réussie : `visible = true`,
l'écran affiche *« Les autres membres NeoVibe proches peuvent te voir »* et
*« Personne à proximité pour l'instant »*. **Aucune radio ne tourne.**

Aggravant : **rien n'écoute l'état de l'adaptateur**. Rallumer le Bluetooth ne
relance rien — `start()` a déjà « réussi ». Il faut couper puis rallumer
l'interrupteur de visibilité, ce que personne ne devinera.

### A2. 🔴 La permission de localisation est demandée, jamais vérifiée

`proximity_service.dart:209` demande cinq permissions et n'en vérifie que
**trois** :

```dart
return statuses[Permission.bluetoothScan]!.isGranted &&
    statuses[Permission.bluetoothAdvertise]!.isGranted &&
    statuses[Permission.bluetoothConnect]!.isGranted;
```

`locationWhenInUse` et `notification` sont demandées et le résultat est jeté. Or
le manifeste déclare `ACCESS_FINE_LOCATION` avec `maxSdkVersion="30"` : **sur
Android ≤ 11, un scan BLE sans permission de localisation ne renvoie aucun
résultat — et ne lève aucune erreur.** Même signature que A1 : interface verte,
radio morte.

`notification` non plus n'est pas vérifiée, alors que le service de premier plan
en dépend pour rester visible.

### A3. 🔴 Accepter une demande d'ami peut ne rien faire — et la demande est perdue

`respondToFriendRequest` (l. 807) :

```dart
state = state.copyWith(clearRequest: true);   // l.811 — la carte disparaît
if (!accept) return;
final linkId = _sessionByUser[pending.fromUserId];
final session = linkId != null ? _sessions[linkId] : null;
if (session == null) return;                  // l.815 — abandon SILENCIEUX
```

La bannière est retirée **avant** de vérifier que le lien BLE existe encore. Si
la personne s'est éloignée de quelques mètres entre l'affichage et le clic, le
tap sur « Accepter » **efface la demande et ne fait rien**.

⚠️ **Et c'est irrécupérable** : une demande d'ami BLE n'existe **que** en mémoire
(`state.incomingFriendRequest`). Il n'y a **aucune copie serveur** — le canal
`connection_requests` ne sert plus qu'aux recommandations (commentaire d'en-tête
de `proximity_repository.dart`). L'émetteur, lui, ne reçoit rien et ne saura
jamais que sa demande a été vue.

---

## B. Incohérences de conception

### B1. 🟠 Croiser un ami ne produit AUCUN certificat de croisement

C'est le point le plus structurant du rapport.

- `_onScan` (l. 274-291) : un ami reconnu par son ID rotatif est ajouté à
  `nearby`, déclenche éventuellement un wave, **puis `return`**. Aucune session
  n'est ouverte.
- Les certificats ne naissent que dans `_maybeStartCertificates` (l. 659), qui
  parcourt `_sessions`.
- Or une session n'est créée que par `_ensureSession`, appelée depuis
  **exactement deux endroits** : `sendMessage` (l. 579) et `sendFriendRequest`
  (l. 765) — vérifié par inventaire.

**Conclusion : deux amis peuvent passer une soirée côte à côte sans qu'aucun
croisement ne soit enregistré.** Le certificat co-signé n'est produit que pour
des **inconnus**, ou entre amis qui s'écrivent en ping.

⚠️ **Conséquence pour les streaks** (`RAPPELS.md` chantier #1) : les streaks de
proximité sont **par définition** entre amis, et ils doivent se calculer sur
`report_encounter`. La fondation annoncée comme « posée » **ne se remplit pas
pour le cas qu'elle est censée servir**. À ressortir impérativement à
l'ouverture de ce chantier.

*Contexte relevé en base, à interpréter avec prudence* : `encounters` = **1**
ligne, `waves` = **0**, `device_keys` = **2**. Ces chiffres sont compatibles avec
le défaut ci-dessus, mais ils ne le prouvent pas — Jay n'a testé à deux appareils
que depuis aujourd'hui, et la table `encounters` est purgée à 24 h.

### B2. 🟠 Une seule demande d'ami à la fois, les autres sont écrasées

`state.incomingFriendRequest` est un emplacement **unique**. Si deux personnes
demandent en même temps — exactement ce qui arrive dans un groupe, le cas d'usage
du produit — la seconde écrase la première **sans trace**.

### B3. 🟠 `copyWith` efface le message d'erreur à chaque appel

`ProximityState.copyWith` (l. 108) : `error: error`, là où tous les autres champs
font `x ?? this.x`. **Toute** mise à jour d'état sans erreur explicite remet
`error` à `null` — l'arrivée d'un pair, un `_pruneStale`, un `_upsertNearby`.

Un message comme « Permissions Bluetooth refusées » peut donc disparaître avant
d'avoir été lu. Si c'est volontaire (erreurs transitoires), rien ne le dit ; en
l'état c'est indiscernable d'un oubli.

### B4. 🟠 Un seul côté initie, et il n'y a aucun repli

`_onScan` l. 305 : `if (myHex.compareTo(hex) >= 0) return; // l'autre initiera`.

L'asymétrie est correcte — exactement un des deux initie. Mais **le côté passif
n'a aucun mécanisme de reprise** : si l'initiateur n'y arrive pas (écran éteint,
scan bridé par Android, pile GATT occupée, refus de connexion), la paire ne se
rencontre jamais, indéfiniment.

### B5. 🟡 Rien ne s'affiche pendant la poignée de main

Un inconnu détecté n'entre dans `nearby` qu'**après** l'échange chiffré. Entre la
détection et la fin de la poignée de main, l'écran affiche *« Personne à
proximité »* alors que deux téléphones sont en train de se parler. Aucun état
intermédiaire (« appareil détecté, vérification en cours »).

C'est cohérent avec la règle « le profil ne circule qu'après chiffrement », mais
du point de vue de l'utilisateur c'est indiscernable d'une panne — et ça se
confond exactement avec A1 et A2.

---

## C. Coûts et dettes

### C1. 🟠 N+1 dans `syncWithServer` — une requête profil PAR ami

`syncWithServer` (l. 949-973) récupère les `device_keys` en un appel, puis fait
**une requête `profiles` par ligne**, séquentiellement, dans une boucle `await`.

À 200 amis : **200 allers-retours réseau**, à chaque `enable()`, à chaque wave et
à chaque croisement certifié. Invisible aujourd'hui (2 lignes en base), coûteux
dès les premiers vrais utilisateurs. Un `in_` sur la liste d'ids le ramènerait à
**deux** requêtes.

*(À rapprocher de `RAPPELS.md` #12 : ces appels comptent dans les 129.)*

### C2. 🟡 Un heartbeat toutes les 30 s pour toute la vie de l'app

`proximity_repository.dart:53` : `Timer.periodic(30 s)` créé à l'instanciation du
provider et jamais suspendu, **qu'il y ait ou non des demandes sortantes**. Il
lit deux providers et, le cas échéant, écrit `expires_at` **depuis le client** —
un client modifié peut donc prolonger une demande indéfiniment.

### C3. 🟡 L'outbox retente une erreur permanente à l'infini

`syncWithServer` l. 999 : `catch (_) { remaining.add(item); }` ne distingue pas
« pas de réseau » (à retenter) de « le serveur refuse » (à abandonner ou à
signaler). Un enregistrement rejeté — signature invalide, RLS — **reste dans
l'outbox pour toujours** et repart à chaque synchronisation.

### C4. 🟡 Le cooldown des waves ne survit pas au redémarrage

`_lastWaveAt` est une `Map` en mémoire. Redémarrer l'app remet à zéro la fenêtre
de 2 h : la notification « le presque » peut repartir à chaque relance, pour la
même personne.

### C5. 🟡 Une connexion partielle expirée reste affichée

`partialConnectionsProvider` filtre sur `partialExpiresAt.isAfter(DateTime.now())`
mais c'est un `Provider` : il ne recalcule que lorsque le flux émet. Une
connexion partielle qui expire pendant que l'écran est ouvert **y reste jusqu'au
prochain événement serveur**.

---

## Ordre de traitement proposé

1. **A1 et A2 ensemble** — ce sont les deux seules causes capables d'expliquer
   « rien ne marche, sans message ». Elles se corrigent en même temps : faire
   remonter un état réel depuis le natif (`adapter == null`, `adapter.isEnabled`,
   permissions manquantes) au lieu d'un `success` inconditionnel, écouter
   `ACTION_STATE_CHANGED`, et vérifier **toutes** les permissions demandées.
   **Tant que ces deux-là ne sont pas faits, aucun autre test de proximité n'est
   interprétable** — on ne saura jamais si un échec vient du reste du code ou
   d'une radio éteinte.
2. **A3** — quelques lignes : vérifier la session **avant** d'effacer la
   bannière, et dire pourquoi si ça échoue.
3. **B1** — décision de conception à prendre avec Jay : faut-il ouvrir une
   session avec un ami croisé (coût : une poignée de main par croisement) ou
   produire le certificat autrement ? **À trancher avant le chantier streaks**,
   pas pendant.
4. **B3, B2, C1** — corrections courtes et sans risque.
5. Le reste selon l'usage.
