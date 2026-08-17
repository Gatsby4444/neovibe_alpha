# Diagnostic — demandes d'amis et synchronisation des connexions

*2026-08-17, après le test de Jay sur la v0.9.112.*

**Méthode** : rien ici n'est déduit d'une lecture seule. Chaque défaut est
appuyé sur l'état réel de la base, sur le journal des appareils, ou sur un test
qui échoue. Les points que je n'ai **pas** pu prouver sont marqués comme tels.

---

## 0. Ce que Jay a constaté

1. Un bouton « demander à se connecter » vers **mimi, alors qu'ils sont déjà
   amis**.
2. Clic → « Demande envoyée à mimi ». Plusieurs clics, même message.
3. Côté mimi, **rien** dans « Demandes & rencontres ».
4. Côté mimi (tablette), **le bouton n'apparaît pas** — asymétrie.
5. Après extinction/rallumage du ping : un encadré « charles veut se connecter
   avec toi » sur l'accueil ping, **avec un seul bouton, « Refuser »**.
6. Après ce redémarrage, le bouton a **disparu** côté Charles.
7. « Le presque » a fonctionné des deux côtés.
8. L'échange de messages BLE fonctionne — le correctif du matin tient.

---

## 1. L'état réel, relevé en base

| Fait | Valeur |
|---|---|
| `connections` Charles ↔ mimi | `status: full`, `confirmed_low: true`, `confirmed_high: true`, depuis le **2026-08-16 12:21** |
| `connection_requests` | **0 ligne**, table entièrement vide |
| `device_keys` | Charles et mimi ont tous les deux `ed_pub` **et** `broadcast_key` |
| RLS `device_keys_friends` | lecture restreinte aux `connections` en `status = 'full'` |
| `submit_ble_connection` | idempotente (`on conflict do update`) |

**Le serveur est juste.** Ils sont amis, sans ambiguïté. Tout ce qui suit est
côté client.

---

## 2. Les défauts prouvés

### A1 — `isFriend` est vérifié, puis jeté

**C'est exactement le diagnostic de Jay** : *« il manque une connexion entre la
vérification et l'affichage »*.

`ping_screen.dart:535` décide d'afficher le bouton sur `!peer.isFriend`, c'est-à-
dire sur le champ de l'entrée de **présence**.

Or `isFriend` n'est écrit qu'à **un seul endroit** : `observe()`
(`presence_tracker.dart:211` et `:251`), quand un pair est reconnu à son **ID
rotatif**. `markIdentified()` — le chemin de la **poignée de main** — ne le
touche pas :

```dart
void markIdentified(String address, PingPeerSnapshot snapshot) {
  _peers[address] = peer.copyWith(
    stage: PresenceStage.identified,
    snapshot: snapshot,          // ← isFriend n'est pas dans la liste
    lastSeen: _now(),
  );
}
```

Et pourtant l'information **existe au même instant** : `PeerNetwork._onProfile`
calcule `isFriend` et l'émet dans `PeerIdentified(isFriend: …)`. Personne ne la
range.

**Donc : tout ami identifié par poignée de main s'affiche comme un inconnu.**

### A2 — Trois carnets d'amis, trois caches, un seul disque

`FriendKeyBook` garde un cache mémoire par instance :

```dart
Future<Map<String, FriendKeys>> all() async {
  if (_cache != null) return _cache!;    // ← jamais relu ensuite
```

Et il en existe **trois instances indépendantes** :

| Instance | Rôle |
|---|---|
| `ProximityController._keyBook` | passée à `PeerNetwork` → décide `isFriend` |
| `ProximitySync._keyBook` | **écrit** les clés téléchargées du serveur |
| défaut de `PeerNetwork` | si aucune n'est fournie |

La synchro écrit sur le disque **avec sa propre instance**. Le contrôleur et le
réseau ont déjà chargé leur cache et **ne relisent jamais le fichier**.

⚠️ **Conséquence : les clés d'amis téléchargées sont invisibles au réseau qui
tourne, pour toute la durée de vie du processus.**

### A3 — L'index rotatif est construit AVANT que les clés n'arrivent

Dans `_ensureNetwork` :

```dart
await network.start();                              // → refreshFriends() ICI
unawaited(ref.read(proximitySyncProvider).run());   // → les clés arrivent APRÈS
```

`refreshFriends()` n'est **jamais rappelé** au terme de la synchro. Il ne l'est
qu'au changement de créneau — toutes les **15 minutes** — et il relit alors le
**cache périmé** de A2, donc rien ne change jamais.

**A2 + A3 expliquent 1, 4 et 6 ensemble** : au premier lancement (ou après un
effacement du local), le carnet est vide au moment où l'index se construit ;
mimi n'est donc pas reconnue à son ID rotatif ; Charles ouvre un lien, l'identifie
par poignée de main, et A1 laisse `isFriend = false` → **bouton affiché**. Sur la
tablette, dont le carnet était déjà chargé au démarrage, mimi reconnaît Charles à
son ID rotatif → **pas de bouton**. C'est l'asymétrie du point 4.

### A4 — Le bouton « Accepter » sort de l'écran, et c'est global

`theme.dart:492` :

```dart
minimumSize: const Size.fromHeight(52),
```

⚠️ **`Size.fromHeight(52)` vaut `Size(double.infinity, 52)`** — une largeur
minimale **infinie**, pas « seulement une hauteur ». Le nom du constructeur
suggère le contraire ; c'est ce qui a permis au défaut de vivre.

Posé dans une `Row` à côté d'un autre bouton — le cas de la carte de demande —
il impose à son parent :

```
BoxConstraints(w=Infinity, 52.0<=h<=568.0)
```

En test, Flutter lève. **En release, `debugAssertIsValid` est compilée hors du
binaire** : la mise en page se poursuit avec une largeur infinie et le bouton
part à droite de l'écran, **sans un mot**.

`_CarteDemande` rend bien **les deux** boutons. « Accepter » est simplement
peint hors du cadre. C'est le point 5 de Jay — et la demande était donc
**impossible à accepter**.

**Reproduit** : `test/filled_button_row_test.dart`, rouge aujourd'hui.

### A4 bis — L'ampleur réelle : UN seul endroit, mais un piège permanent

⚠️ **Correction d'une affirmation trop large faite en première lecture.** J'avais
écrit que *tout* `FilledButton` dans une `Row` était cassé. **Inventaire fait :
c'est faux.**

La largeur infinie n'est un problème que si le parent laisse la largeur
**non bornée**. Un `Expanded`, un `Flexible` ou un `SizedBox` la borne, et le
bouton se comporte normalement. Une `Row` ne la borne **pas** pour un enfant
non-flexible : c'est le seul cas qui casse.

Sur les **49** `FilledButton` de l'app, 8 sont dans une `Row` :

| Endroit | État |
|---|---|
| `user_library_screen.dart:63` | ✅ `Expanded` |
| `gl_preview_test_screen.dart` ×3 | ✅ `Expanded` |
| `day_cycle_preview_screen.dart` ×2 | ✅ `SizedBox(width: infinity)` |
| `ping_screen.dart:332` | ✅ `Align` (largeur bornée) |
| **`ping_screen.dart:400` — « Accepter »** | 🔴 **nu dans la `Row`** |

**Un seul site cassé dans toute l'app**, et c'est celui que Jay a trouvé. Les
autres tiennent parce que leurs auteurs ont mis un `Expanded` — **par habitude,
pas parce qu'une règle l'imposait.**

C'est ça, le vrai défaut : la règle n'est écrite nulle part, et sa violation ne
se voit pas en release.

### A5 — Deux magasins pour un même concept, et deux écrans qui n'en lisent qu'un

« Demandes & rencontres » (`heart_screen.dart`) lit :

- `incomingRequestsProvider` → table **`connection_requests`** (serveur)
- `requestHistoryProvider` → table **`connection_requests`** (serveur)
- `wavesProvider` → table `waves` (serveur)

Une demande de **proximité** ne passe jamais par cette table : elle vit dans
`ProximityJournal` (`pending_requests.json`, fichier local) et s'affiche sur
l'écran **ping**.

**Preuve** : `connection_requests` est vide, alors que la demande existait bel et
bien — Jay l'a vue apparaître sur l'accueil ping.

Idem pour les rencontres : les croisements sont rangés en local
(`LocalEncounter`) et cet écran ne les lit pas.

**Le point 3 n'est donc pas une perte de données. C'est le mauvais écran** — et
l'utilisateur n'avait aucun moyen de le savoir.

### A6 — Aucun garde-fou « déjà amis »

Ni `requestFriendship` (envoi) ni `_onFriendRequest` (réception) ne consultent
l'état d'amitié. Une demande entre amis établis est donc émise, transmise,
vérifiée, persistée et acceptable.

Sans conséquence en base — `submit_ble_connection` est idempotente — mais c'est
la cause directe du point 2.

### A7 — Ce chemin n'écrit rien dans le journal

Les deux rapports de la v0.9.112 ne contiennent **aucune** ligne de demande,
d'acceptation, de refus ou de synchronisation. La séquence de Jay est
irreconstituable depuis les rapports.

C'est le même mal que le transport ce matin, au même endroit du raisonnement :
*un rapport ne peut pas dire ce que le code ne consigne pas.*

---

## 3. Ce que l'instrumentation du matin a prouvé

### B1 — Mon hypothèse des deux connexions GATT est FAUSSE

`bothPathsPeak: 0` sur les **deux** appareils. `clientPaths: 1 / serverPaths: 0`
côté Charles, l'inverse côté mimi : topologie propre, un seul chemin.

**Rien à changer au natif.** C'était l'engagement pris avec la mesure, il est
tenu — et c'est la mesure qui a évité une réécriture inutile.

### B2 — Wi-Fi Aware indisponible

`wifiDirect: true`, `wifiAware: false` sur les deux appareils. Le §9.4 de
`moteur-spatial-et-transports.md` est **tranché** : sur ce matériel, Wi-Fi Direct
est la seule option pour les médias.

### B3 — Une QUATRIÈME cause de message fantôme, visible dans le journal

Côté mimi :

```
15:57:01  session fermée par l'entretien  — fusion d'adresses
16:08:31  session fermée par l'entretien  — fusion d'adresses
```

Côté Charles, 2 minutes après la première :

```
15:59:00.954  second lien ignoré      — entrant, canal established
15:59:01.233  déchiffrement refusé    — compteur 0, canal established
15:59:01.334  déchiffrement refusé    — compteur 1, canal established
```

**Les compteurs 0 et 1 sont décisifs** : ce n'est pas un rejeu (qui porterait un
compteur ancien), c'est une **session neuve**. Le pair a reconstruit son canal ;
Charles a refusé le nouveau lien parce que son ancien canal était encore
« established » ; sa clé ne correspondait plus.

Deux enseignements :

1. **La fusion d'adresses ferme encore un canal ÉTABLI.** Ma trace ne se
   déclenche que si `stage == established` — elle s'est déclenchée deux fois.
   `hasLiveLink` ne protège la fusion que lorsqu'**une seule** des deux adresses
   est vivante ; quand les deux le sont, une session vivante est sacrifiée.
2. **La règle « un canal établi ne se remplace jamais », posée le 2026-08-16,
   est devenue la cause du défaut suivant.** Elle empêche d'adopter la session
   que le pair a, lui, déjà reconstruite. *Le correctif d'un symptôme est devenu
   la cause du suivant* — troisième fois sur ce chantier.

⚠️ **Ce n'est pas ce que Jay a signalé aujourd'hui** (les messages passent). Mais
c'est consigné, mesuré, et ça reste à traiter.

---

## 4. Le défaut d'architecture

Une fois les sept symptômes rangés, il n'en reste qu'un.

**L'amitié a cinq représentations, et aucune n'est désignée comme la source.**

| # | Où | Qui la lit | Durée de vie |
|---|---|---|---|
| 1 | `connections` (serveur) | `heart_screen`, `friends_list` | permanente — **la vérité** |
| 2 | `FriendKeyBook` (fichier, ×3 caches) | `PeerNetwork.isFriend`, chat | permanente, mais **jamais rafraîchie en mémoire** |
| 3 | `PresencePeer.isFriend` (mémoire) | **le bouton du ping** | le temps d'un croisement |
| 4 | `connection_requests` (serveur) | « Demandes & rencontres » | 90 s (heartbeat) |
| 5 | `ProximityJournal` (fichier) | l'accueil ping | 24 h |

Chaque écran lit celle qui lui tombe sous la main. Rien ne les réconcilie.

C'est la règle 2 de `CLAUDE.md` prise à l'envers — *deux objets qui n'obéissent
pas aux mêmes règles ne partagent ni le même stockage ni le même chemin d'accès*
— appliquée à un **seul** objet éclaté en cinq. Et c'est la règle 3 : personne
n'a compté les chemins qui mènent à la réponse « suis-je ami avec cette
personne ? ». Il y en a cinq, ils ne s'accordent pas, et **c'est la plus proche
qui gagne**.

⚠️ **Un sixième chemin, invisible au code** : `isFriend` ne veut « ami » que
parce que la politique RLS `device_keys_friends` restreint `device_keys` aux
connexions `full`. Le code client, lui, écrit
`from('device_keys').select().neq('user_id', me)` — « prends tout ». La
définition d'« ami » côté client **vit donc dans une politique du serveur**, et
rien au point d'appel ne le dit. Ça marche aujourd'hui ; ça marche par accident.

---

## 5. Direction proposée — à arbitrer par Jay

Rien n'est implémenté. Trois décisions à prendre.

### ① Une seule source pour « qui sont mes amis »

Un `FriendBook` **unique** (un provider, pas trois `new`), alimenté par le
serveur, exposant un flux. `isFriend` se **dérive** de lui au moment du rendu.

**Et `PresencePeer.isFriend` disparaît.** La règle, énoncée positivement :

> **La présence dit OÙ et À QUELLE DISTANCE. Elle ne dit jamais QUI.**

C'est ce qui rend A1 impossible par construction, au lieu d'être rattrapé par
une ligne de plus dans `markIdentified` — un garde-fou qu'il faudrait ensuite
maintenir dans les trois chemins d'identification.

### ② Une seule boîte de réception, quel que soit le canal

Une demande est une demande, qu'elle arrive par BLE ou par le serveur.
« Demandes & rencontres » doit lire **les deux**, sinon l'écran qui porte le nom
de la fonction n'en montre qu'une moitié.

⚠️ Ça ne veut **pas** dire fusionner les stockages : une demande BLE n'a pas de
ligne serveur, et c'est voulu (la co-signature part d'appareil à appareil). Ça
veut dire **une seule vue au-dessus de deux magasins**, chacun gardant ses
règles.

### ③ Le thème — recommandation RÉVISÉE après inventaire

Ma première recommandation (changer le thème) reposait sur une ampleur que
l'inventaire a démentie (A4 bis). **Un seul site est cassé.**

Et la largeur infinie n'est **pas** un accident à supprimer : c'est ce qui rend
pleine largeur les ~40 gros boutons de l'app (connexion, envoi, réglages) sans
que personne n'ait à l'écrire. La retirer les rétracterait tous à la taille de
leur libellé, et il faudrait repasser sur chaque écran.

**Donc : garder le thème, corriger le site, et NOMMER la contrainte là où elle
naît.**

| | Action |
|---|---|
| 1 | `ping_screen.dart` — les deux boutons de la carte dans des `Expanded` (meilleur rendu au passage : deux boutons de largeur égale) |
| 2 | `theme.dart` — un commentaire au point de définition : *« `Size.fromHeight` pose une largeur minimale INFINIE. C'est voulu — c'est ce qui rend les gros boutons pleine largeur. Dans une `Row`, il FAUT un `Expanded`/`Flexible`/`SizedBox`, sinon le bouton est peint hors de l'écran, et en release rien ne le signale. »* |
| 3 | `test/filled_button_row_test.dart` — garde le contrat : le motif nu échoue, le motif `Expanded` passe |

C'est l'application de la règle du 2026-08-15 : *un commentaire qui énonce une
contrainte dit comment elle a été constatée.* Ici la contrainte est réelle, elle
n'était écrite nulle part, et son coût a été une demande d'ami impossible à
accepter.

### ④ Instrumenter ce chemin

Les mêmes compteurs que pour le transport, sur : demande émise / reçue /
signature refusée / acceptée / refusée / synchro réussie / synchro abandonnée.
Sans quoi le prochain test de Jay sera aussi aveugle que celui-ci.

---

## 6. Ce que je n'ai pas prouvé

1. **Pourquoi le bouton a disparu après le redémarrage du ping (point 6).**
   L'explication A2+A3 est cohérente et suffisante, mais je n'ai pas de trace
   qui la confirme sur l'appareil — le chemin n'est pas instrumenté (A7).
2. **Si la demande a été reçue au premier clic ou seulement plus tard.** Sans
   journal, impossible de le dire. `putRequest` ne garde qu'**une** demande par
   personne, ce qui est cohérent avec « plusieurs clics, un seul encadré ».
3. **La fréquence réelle de B3** — deux occurrences en une session, sur un
   dénominateur de 15 et 29 trames livrées. Trop peu pour conclure à un taux.
