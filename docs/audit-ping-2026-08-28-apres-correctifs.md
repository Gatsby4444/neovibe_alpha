# Audit du ping — second passage, après correctifs (2026-08-28)

**Même méthode que le premier** : lecture textuelle intégrale, chaînes de
fonctions suivies jusqu'au bout, **sans tenir compte des commentaires, des
rapports ni de la mémoire des sessions précédentes**. Chaque symbole suspecté
mort vérifié par recherche d'appelants dans `lib/`, `test/` et `android/`.

**Périmètre** : les 22 fichiers Dart de `lib/features/proximity/**` et les
6 fichiers Kotlin de `android/.../ble/**`.

---

# 1. Les 14 défauts du premier audit — état vérifié

| # | Défaut | Vérifié comment | État |
|---|---|---|---|
| A1 | le plan natif ignorait le carnet d'amis | le superviseur s'abonne à `friendBookProvider.changes` **et** à `currentUserIdProvider` ; 4 tests comptent les dépôts | ✅ |
| A2 | récursion `refreshPlan` ↔ `_engage` | `_engage` scindé en `_demarreRadio` + dépôt ; la reprise est **linéaire** ; le test boucle sans le correctif | ✅ |
| A3 | `parallelRefused` définitif | devient `parallelRefusedUntil` (10 min), remis à zéro par `start()` | ✅ |
| A4 | scans rejoués sans date | `atMillis` traverse le pont ; **deux** consommateurs filtrent, chacun avec son seuil | ✅ |
| A5 | `copyWith` effaçait `blocker` / `lastError` | sentinelle `_nonFourni` ; 3 tests | ✅ |
| A6 | renoncement calibré à 60 s | devient une **durée nommée** de 3 min, et il se **réarme** quand le jeton n'est plus entendu | ✅ |
| A7 | `isFriendProvider` écrivait après fermeture | le drapeau est testé **après** l'`await` | ✅ |
| A8 | « Croisés récemment » sans borne de temps | `DerivedList` + `kFenetreRencontre` (10 min) ; 2 tests | ✅ |
| B1 | `ProximityLevel` invisible mais dans l'égalité | supprimé de bout en bout ; ses 2 tests repointés sur `ProximityBand` | ✅ |
| B2 | deux `protocolVersion` (3 / 5) | la constante Dart est supprimée ; seule celle du fil reste | ✅ |
| B3 | deux branches inatteignables | supprimées, **et leur cause avec** : `refreshFriends` retire l'identité des sessions que le carnet ne connaît plus | ✅ |
| B4 | deux sessions par appareil | ⚠️ **non corrigé — et ce n'est pas un défaut** (voir §3) | 🟡 |
| B5 | `BleRadio` construit 4 fois | `bleRadioProvider` ; superviseur, contrôleur et écran de diagnostic le lisent | ✅ (1 reste, §3) |
| B6 | provider lu depuis `onDispose` | la référence est prise pendant `build` | ✅ |

## Ce que le correctif A1 a coûté en plus

⚠️ **Le premier correctif de A2 était faux, et c'est un test qui l'a montré.**
J'avais posé une borne (`_retablissement`) que le rejeu de la demande en attente
(`_planADemander`) contournait : `refreshPlan` se rappelait après le `finally`,
`_retablissement` était déjà retombé à faux, et la boucle repartait. Le test
« un plan refusé ne boucle pas » ne s'est jamais terminé.

La correction n'est pas une seconde borne : **la cause est supprimée**. `_engage`
faisait deux choses — démarrer la radio *et* déposer le plan —, donc la reprise
ne pouvait pas faire l'une sans l'autre. Séparées, la reprise devient linéaire :
relancer, retenter **une fois**, puis publier `RadioFailed`. Il n'y a plus de
cycle à interrompre.

---

# 2. 🔴 Défauts trouvés par CE passage

Deux, et de la même famille que B1 : un champ que personne n'affiche mais qui
décide de quelque chose.

## N1. `PingBeaconState.cell` — invisible, et pourtant dans l'égalité ✅ corrigé

Écrit à chaque tour (`cell: fix.toString()`), porté dans `==` et `hashCode`… et
**lu par personne** : ni l'écran de diagnostic, ni le rapport — qui recalcule le
carreau depuis la position, à sa source.

⚠️ **Il n'était pas gratuit** : l'écran Ping observe `pingBeaconProvider` en
entier, donc **changer de quartier reconstruisait l'écran** pour une valeur que
rien n'affiche. Retiré.

## N2. `PeerSession.advertAddress` — un second nom pour `address` ✅ corrigé

Deux accesseurs publics rendant le même champ, dont un sans aucun lecteur. Retiré.

---

# 3. Ce qui reste, assumé et documenté

## 3a. Un appareil produit deux sessions de présence — **ce n'est pas un défaut**

Un appareil en mode parallèle émet un jeton public **et** un jeton d'ami. Ils
sont, par conception, **cryptographiquement impossibles à relier** par qui n'est
pas l'émetteur — c'est toute la propriété anti-traçage. Les regrouper exigerait
de casser cette propriété.

Conséquence, bornée et sans effet visible : `presence.length` compte deux
sessions pour un appareil. Les listes affichées n'en montrent qu'une
(`presenceKeysProvider` ne garde que les identifiés) et les constats de
croisement écartent les sessions sans identité.

## 3b. `DiagnosticBundle.proximity()` construit encore un `BleRadio`

C'est le seul point de construction restant hors du provider. La méthode est
**statique** et appelée depuis trois écrans sans `Ref` : la faire passer par le
provider demanderait de propager un `Ref` jusqu'à `app_updater` et `dev_report`.
`BleRadio` étant sans état, le coût réel est nul — mais **c'est une entorse, et
elle est écrite ici plutôt que tue**.

## 3c. Le plan d'émission ne survit pas à la mort du processus

`AdvertSchedule` vit en mémoire dans le service. Si Android tue le processus,
`onStartCommand` reçoit un intent sans identifiant, publie
`RadioFailed("restarted")` et **s'arrête** — c'est délibéré, l'identifiant dérive
d'une clé que seul le Dart sait lire.

⚠️ **Conséquence à connaître** : les « 12 heures d'indépendance » valent tant que
le **service** vit, pas tant que l'appareil est allumé. Le point H est corrigé
pour la mort de l'*activité*, pas pour celle du *processus*.

## 3d. Trois champs déclarés sans lecteur, et **laissés en place**

`PresencePeer.firstSeen`, `PresencePeer.lastSeen`, `PeerView.userId`.

**Le critère appliqué, énoncé pour qu'il soit contestable** : on retire ce qui
**coûte** (un champ dans une égalité, donc dans les redessins) ou ce qui
**duplique** (deux noms pour une valeur). Ces trois-là ne font ni l'un ni l'autre
— `PresencePeer` n'a pas d'égalité de valeur, et le getter ne fait que déréférencer.
Les retirer serait raboter la surface d'un modèle sans rien gagner de mesurable.

## 3e. Cinq symboles utilisés uniquement par les tests

`PeerSession.contactDuration`, `PeerRegistry.byAddress`, `.identifiedCount`,
`.isPresent` (et `byUser`, son seul appelant interne). Ce sont des **points
d'observation** : les couper demanderait de réécrire les tests qui s'y adossent,
donc de réduire la couverture pour gagner cinq lignes.

⚠️ **`PeerNetwork.foreignTokenScans` a quitté cette liste** : il est supprimé, et
son test assertion remplacée par la propriété observable (aucune session créée).

---

# 4. Code mort — inventaire après coup

**17 symboles retirés**, vérifiés absents de `lib/` et `android/app/src/main/` :

`TokenResolver` · `SightingLog.clear` · `ProximitySync.abandoned` · `kPingGrace`
· `canalProximiteOuvertProvider` · `AdvertPlan.covers` ·
`RecognitionTable.covers` · `RecognitionTable.length` · `AdvertToken.isPublic` ·
`NativeRecognitionTable.isEmpty` · `RadioScan.hasTxPower` ·
`BleRadio.advertCapabilities` (+ le cas du pont + la méthode du service) ·
`ProximityIdentity.protocolVersion` · `FriendKeyStore.put` / `.remove` ·
`RecognitionTable.validUntilMillis` (Kotlin) · `ProximityService.sightingCount`
· `PingBeaconState.cell` · `PeerSession.advertAddress`.

## 🔴 Un compteur natif qui publiait un zéro permanent

`BleEngine.foreignTokenScans` était **déclaré, publié dans `stats()`, et jamais
incrémenté**. Le rapport de diagnostic affichait donc `foreignTokenScans: 0`
présenté comme une mesure — le « seau vide » exact que ces compteurs existent
pour éviter.

⚠️ **Le moteur radio ne pouvait pas le compter** : il ne détient pas la table de
reconnaissance, donc il ne sait pas distinguer un jeton étranger d'un jeton
attendu. Celui qui le sait est `ProximityService`, qui interroge la table à
chaque scan privé. Le compteur y a déménagé, et il compte maintenant **aussi
quand l'interface est absente** — ce que la couche Dart n'a jamais pu faire.

**La règle qui en sort** : *un compteur se place là où vit l'information qu'il
mesure.* Consignée dans `docs/parties-natives-par-os.md` pour le portage iOS.

---

# 5. Ce que le passage a vérifié et trouvé correct

- **Le filtre anti-soi couvre les deux modes d'émission** : `applyAdverts`
  appelle `rememberOwnToken` **avant** le test de faisabilité du parallèle, donc
  le repli en cycle est couvert.
- **Le sens des jetons reste cohérent** : `plan()` émet avec `emitter = moi`,
  `table()` et `nativeTable()` attendent avec `emitter = lui`.
- **`refreshFriends` ne modifie pas l'ensemble qu'il parcourt** : `deidentify`
  ne touche qu'au champ `snapshot`, jamais à `_sessions`.
- **`refreshPlan` ne peut plus lever** : `_deposeOuRetablit` rattrape ses deux
  tentatives, donc le `unawaited` de `_replanifier` n'avale rien.
- **Les délais restent séparés et nommés** : `freshFor` (5 s) pour la présence
  radio, `kPingLocalGrace` (10 s) pour le ping, `kPingGraceServeur` (2 min) pour
  le filet, `kFenetreRencontre` (10 min) pour l'action. Chacun a un lecteur et
  un seul.

---

# 6. État des vérifications

| | |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` | **205 tests au vert** (194 avant ce chantier, +11) |
| Kotlin | compile, tests unitaires au vert |
| Motif mort restant en production | **0**, vérifié par inventaire |
