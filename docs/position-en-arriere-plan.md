# La position en arrière-plan — état relevé et conception

> Écrit le **2026-09-22**, au titre de `RAPPELS.md` #158 ③ : *« détecter la
> position d'un utilisateur mise à jour de manière continue app ouverte et
> récurrente toutes les 1 min si possible app fermée, ou alors toutes les
> 10 min (Snap affiche de temps en temps une notification "mise à jour de la
> position", même app fermée) »*.
>
> ⚠️ Ce document décrit **ce qui existe, relevé dans le code ce jour-là**, puis
> une conception **non construite**. Ne rien en déduire sans revérifier à la
> source (règle de `CLAUDE.md`).

---

## 1. Ce qui existe aujourd'hui — trois chemins, et un trou

| Quand | Qui **mesure** | Qui **publie**, et où | Cadence |
|---|---|---|---|
| App ouverte, « Visible à proximité » allumé | Dart, `CoarseLocation` (geolocator) | Dart → `publish_ping_beacon` (`ping_beacons`) | **60 s** (`PingBeaconService.refreshEvery`) |
| Pendant un événement rejoint | **natif**, `EventPresenceService` (`LocationManager`, GPS + réseau) | natif → `report_event_position` | **60 s** (`EVERY_MS`) |
| App fermée, hors événement | **personne** | **personne** | — |

**Le trou est la troisième ligne, et il a une conséquence jamais écrite
noir sur blanc** : le natif n'a le droit de crier l'identifiant **public**
que cinq minutes après le dernier signe de vie du Dart
(`ProximityService.graceBattement`, posé par `battementPublic()` à chaque
republication de balise réussie). Donc :

> **Aujourd'hui, fermer l'app rend invisible aux inconnus au bout de
> 5 minutes** — silencieusement. Le croisement d'**amis**, lui, continue :
> il est en BLE pur, le plan porte 12 h de jetons, aucun serveur n'est
> nécessaire pour reconnaître un ami.

⚠️ Ce n'était **pas** une décision de confidentialité, c'est une conséquence
technique, et le commentaire du code le dit lui-même : *« passé ce délai, plus
personne au monde ne peut relier ce jeton à un compte : le crier encore ne
rend service à personne »*. Un jeton public que le serveur ne sait plus
traduire ne sert à rien — **sauf si quelqu'un republie la balise**.

## 2. Ce qu'Android autorise, et ce qu'il refuse

| Besoin | Possible ? | Le moyen, et sa limite |
|---|---|---|
| position **continue** app ouverte | oui | `LocationManager.requestLocationUpdates` ; c'est déjà fait pendant un événement |
| position **toutes les 1 min** app fermée | **oui, à une condition** : qu'un service de premier plan de type `location` vive. `ProximityService` en est déjà un | un service de premier plan n'est pas soumis à Doze. Si le service meurt (MIUI — après-midi du 2026-09-21), tout s'arrête |
| position toutes les 1 min **sans** service de premier plan | **non** | Doze impose ~9 min entre deux réveils d'alarme par app, et `WorkManager` ne descend pas sous 15 min. C'est un plancher système, pas un réglage |
| position toutes les **10 min** sans service | oui (alarme inexacte) | une sonnerie peut être avalée — déjà vu (#133) ; `SlotAlarm.veille()` est la parade |
| ce que fait **Snap** | la notification « mise à jour de la position » **est** ce service de premier plan | c'est le prix à payer : une notification permanente ou périodique. Nous en avons déjà une |

➡️ **Conclusion : on a déjà tout le matériel.** `ProximityService` est un
service de premier plan de type `location` avec sa notification, qui tourne
dès que le ping est allumé. Il ne manque que le battement de position lui-même.

## 3. La conception proposée — **non construite**

### 3.1 Un fichier, une responsabilité

`android/.../ble/LocationBeat.kt`, à côté de `SlotAlarm`, `EnergyWatcher` et
`ScreenState` : il **mesure** une position et la **dépose**, à la cadence
qu'on lui donne. Il ne décide ni du droit d'être visible, ni de la cadence :
`ProximityService` la lui donne, en lisant `ScreenState`.

| État | Cadence proposée |
|---|---|
| écran allumé | mises à jour continues (`minTime` 30 s, `minDistance` 0) |
| écran éteint | **1 min**, et le service vit ⇒ tenable |
| service mort | rien — c'est le sujet de la v0.9.241, pas celui-ci |

### 3.2 Il publie **lui-même**, comme le fait déjà l'événement

`SessionStore` + `SupabaseHttp` existent (`publish/`) et sont éprouvés par
`EventPresenceService`. Le natif a déjà tout ce qu'il faut pour appeler
`publish_ping_beacon(p_lat, p_lon, p_acc, p_token, p_slot)` : **le plan
d'émission contient les jetons publics des 12 prochaines heures** avec leur
créneau (`AdvertSchedule`, type `1`).

### 3.3 🔴 Le point d'architecture : **un seul écrivain**

Règle 4 de `CLAUDE.md` (« un chemin, une donnée ») : si le Dart **et** le
natif publient la balise, il y a deux chemins vers la même ligne, deux
cadences, et un désaccord que rien ne signalera.

➡️ **Le natif devient le seul écrivain de `ping_beacons`.** Ce que le Dart
perd et ce qu'il garde :

| `PingBeaconService` (Dart) | Devient |
|---|---|
| lire une position | **supprimé** (le natif mesure) |
| `publishBeacon` toutes les 60 s | **supprimé** |
| `battementPublic()` au succès | **supprimé** — le natif sait qu'il a publié, il n'a personne à croire |
| rafraîchir la liste des voisins, grouper les jetons entendus | **gardé**, c'est de l'usage |
| dire « suis-je encore annoncé ? » (`_publishedAt`) | **gardé**, mais l'information vient du natif par `stats()` |

⚠️ **Et l'homme mort change de sens** (règle 6 : rejouer les décisions dont la
prémisse bouge). `graceBattement` protégeait d'un jeton intraduisible. Quand
c'est le natif qui publie, le jeton reste traduisible : la garde devient
« tant que l'intention enregistrée dit que l'utilisateur veut être visible »,
et cette intention est déjà persistée (le plan sur le disque, `friendsOnly`).

### 3.4 🔴 Ce que ça change POUR L'UTILISATEUR — décision de Jay

> Aujourd'hui : « Visible à proximité » allumé + app fermée ⇒ **invisible aux
> inconnus au bout de 5 min**.
> Après : **visible tant que l'interrupteur est allumé**, app fermée comprise.

C'est ce que demande #158 (« position mise à jour app fermée »), et c'est
cohérent avec l'interrupteur — mais c'est un changement de posture qui doit
être **voulu**, pas hérité d'un correctif technique. À trancher par Jay avant
de construire.

Si la réponse est « oui mais visible seulement pour mes amis app fermée »,
alors la balise publique reste au Dart et le natif ne publie que la position
des amis — deux objets, deux règles, deux chemins (règle 2), donc **deux
tables** : à concevoir avant d'écrire.

### 3.5 Ordre de construction, si Jay valide

1. `LocationBeat.kt` : mesure + dépôt, cadence donnée de l'extérieur, un test
   JVM sur le choix de cadence (pur, comme `Energie.ligne`).
2. `ProximityService` : le branche, lui donne la cadence selon `ScreenState`,
   publie `positionBeatAgeMillis` et `positionBeatEchecs` dans `stats()` —
   **sans instrument, « ça tourne la nuit » est invérifiable** (#130).
3. `PingBeaconService` (Dart) : retirer la publication, lire l'état du natif.
4. Mesure : une nuit, et le carnet doit montrer une publication par minute.

## 4. Ce qui reste à mesurer avant d'y toucher

| Question | Comment |
|---|---|
| combien coûte une position par minute, la nuit | deux nuits, ping seul vs ping + position, `batt=` du carnet |
| le GPS se réveille-t-il en Doze quand le service vit | carnet : âge de la dernière position à chaque alarme |
| MIUI laisse-t-il le service vivre une fois exempté | v0.9.241, journée sur batterie |
