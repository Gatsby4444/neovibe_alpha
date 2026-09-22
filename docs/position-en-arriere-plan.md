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

## 2 bis. ✅ CONSTRUIT le 2026-09-22 (v0.9.244) — décision de Jay

Jay : *« Oui c'est toujours ce que j'ai voulu […] au niveau de
l'architecture on vise le plus large possible. En fait il faudrait rajouter
un interrupteur supplémentaire. »* Ses trois scénarios, et ce que le code en
fait :

| Scénario | Ce qui se passe maintenant |
|---|---|
| **1.** Alice inconnue, ping + nouvel interrupteur, app fermée ; Bob à portée | Alice crie toujours son identifiant public, et **le natif republie sa balise toutes les minutes** — le serveur sait la traduire, Bob la voit et peut lui écrire |
| **2.** Idem, interrupteur **éteint** | `publicAutorise()` retombe sur l'homme mort : plus d'identifiant public 5 min après la fermeture. Bob ne voit rien |
| **3.** Alice et Bob **amis**, ping allumé | inchangé, et ça marchait déjà : BLE pur, plan de 12 h, aucun serveur — ils se voient app fermée |

Construit : `LocationBeat.kt`, `AdvertSchedule.publicTokenAt`, le drapeau
`publicEnArrierePlan` porté par le plan, `revoirLeBattement()` (la règle de
passage de main), 5 instruments dans `stats()`, le troisième interrupteur
dans l'écran Ping et 3 tests Dart.

⚠️ **Ce qui n'est PAS fait, et qu'il faut savoir** : le plan persisté sur le
disque reste `friendsOnly`. Si Android tue le **processus** et relance le
service, il n'a aucun jeton public à crier jusqu'à la réouverture de l'app —
le croisement d'amis, lui, reprend seul. C'est un cas de second ordre (la
v0.9.241 vise justement à empêcher cette mort), pas un oubli.

## 3. La conception — **construite le 2026-09-22, voir §2 bis**

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

### 3.3 🔴 Le point d'architecture : **un seul écrivain À LA FOIS**

Règle 4 de `CLAUDE.md` (« un chemin, une donnée ») : si le Dart **et** le
natif publient la balise en même temps, il y a deux chemins vers la même
ligne, deux cadences, et un désaccord que rien ne signalera.

⚠️ **La première rédaction de ce paragraphe disait « le natif devient le seul
écrivain » et le Dart perdait sa publication.** Ce n'est PAS ce qui a été
construit, et le changement est délibéré : retirer la publication du Dart
touche aussi ce qui alimente l'écran (`blocker`, `precision`, « suis-je
encore annoncé ? »), c'est-à-dire le chemin app ouverte qui fonctionne —
la veille d'un week-end de mesure.

➡️ **Ce qui est construit : un relais explicite.** Le Dart publie tant qu'il
vit ; le natif prend la main après `relaisApres` = **90 s** de silence (deux
battements manqués de 60 s), et la rend dès que le Dart redépose un plan
(`setAdvertSchedule` repose `dernierBattement`). Il y a donc **un seul
écrivain à chaque instant**, et la règle de passage de main est écrite dans
`ProximityService.revoirLeBattement`, à un seul endroit.

⚠️ **Et l'homme mort change de sens** (règle 6 : rejouer les décisions dont la
prémisse bouge). `graceBattement` protégeait d'un jeton intraduisible. Quand
le natif republie la balise, le jeton reste traduisible : `publicAutorise()`
rend donc vrai sans condition de temps dès que `publicEnArrierePlan` est
posé — et retombe sur les 5 minutes sinon.

### 3.4 Ce que ça change POUR L'UTILISATEUR — **tranché par Jay le 2026-09-22**

> Avant : « Visible à proximité » allumé + app fermée ⇒ invisible aux
> inconnus au bout de 5 min, en silence.
> Après : **un interrupteur de plus**, « Visible même quand l'app est
> fermée », éteint par défaut. Allumé, la visibilité tient app fermée.

Jay : *« on vise le plus large possible […] il faudrait rajouter un
interrupteur supplémentaire »*. Le troisième interrupteur n'apparaît que
sous celui dont il dépend, et il ne descend au natif que si les deux sont
allumés.

### 3.5 Ce qui a été construit, et ce qui ne l'a pas été

| | État |
|---|---|
| `LocationBeat.kt` : mesure + dépôt, cadence donnée de l'extérieur | ✅ |
| `ProximityService` : branchement, cadence selon `ScreenState`, relais | ✅ |
| Instruments dans `stats()` (`beaconPublications`, `beaconEchecs`, `beaconDernierEchec`, `beaconAgeMillis`, `publicEnArrierePlan`) | ✅ — sans eux, « ça tourne la nuit » est invérifiable (#130) |
| Le troisième interrupteur, persisté, porté par le plan | ✅ + 3 tests Dart |
| `PingBeaconService` (Dart) : retirer la publication | ❌ **volontairement** — voir §3.3 ; le relais rend la chose inutile pour l'instant |
| Un test JVM sur `revoirLeBattement` | ❌ — la décision lit `schedule`, `engine` et l'horloge ; l'extraire en fonction pure est le prochain geste |
| Mesure : une nuit, une publication par minute au carnet | ❌ — **c'est la vérification qui compte**, elle attend un test réel |

## 4. Ce qui reste à mesurer avant d'y toucher

| Question | Comment |
|---|---|
| combien coûte une position par minute, la nuit | deux nuits, ping seul vs ping + position, `batt=` du carnet |
| le GPS se réveille-t-il en Doze quand le service vit | carnet : âge de la dernière position à chaque alarme |
| MIUI laisse-t-il le service vivre une fois exempté | v0.9.241, journée sur batterie |
