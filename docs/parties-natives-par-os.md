# Parties natives par OS — catalogue

> Recense **tout le code natif** de NeoVibe (ce qui n'est PAS du Dart partagé) et,
> pour chaque bloc, l'implémentation **Android** actuelle et l'**équivalent iOS**
> à écrire. But : savoir exactement ce qu'il restera à faire pour porter l'app
> sur iOS, et ne rien découvrir au dernier moment.
>
> Contexte et principes : voir [`strategie-multiplateforme.md`](strategie-multiplateforme.md).

---

## ⚠️ RÈGLE DE TENUE DE CE FICHIER (impérative)

- **À CHAQUE changement du code natif**, mettre ce fichier à jour :
  - ajout / suppression / renommage d'un fichier natif (`.kt`, plus tard `.swift`) ;
  - ajout / suppression / modification d'une **méthode de platform channel**
    (le « contrat » Dart↔natif) ;
  - nouvelle capacité matérielle utilisée (API caméra, BLE, Wi-Fi, capteur…).
- **En fin de chaque session**, VÉRIFIER que ce fichier reflète l'état réel du
  code natif (canaux, méthodes, fichiers). Le corriger sinon.
- Ce fichier est la **source de vérité** du périmètre natif : si le code et ce
  fichier divergent, c'est un bug de documentation à corriger.

---

## Vue d'ensemble

| Bloc natif | Canal | Android (fait) | iOS (à faire) |
|---|---|---|---|
| Caméra | `neovibe/camera` | CameraX + Camera2 + OpenGL ES | AVFoundation + Metal/CoreImage + AVAssetWriter |
| Anti-capture | (dans `neovibe/camera` : `setSecure`) | `WindowManager.FLAG_SECURE` | Pas d'équivalent strict → détection + occultation |
| Média (hors caméra) | `neovibe/media` | `MediaMetadataRetriever` (image de couverture d'une vidéo) | `AVAssetImageGenerator` |
| Proximité BLE | `neovibe/proximity` + `/events` | Service de premier plan qui POSSÈDE la radio (advertise + scan) | CoreBluetooth, **mode dégradé à concevoir** |
| ~~Transport GATT (liens, trames)~~ | — | **SUPPRIMÉ le 2026-08-27** — le BLE ne fait plus que prouver la proximité | *sans objet* |
| ~~Transfert média proximité~~ | — | **ABANDONNÉ le 2026-08-27** — tout le contenu passe par le serveur | *sans objet* |
| Hôte / cycle de vie | — | `MainActivity : FlutterFragmentActivity` | `AppDelegate` / `FlutterViewController` |
| Journal caméra (dev) | (dans `neovibe/camera`) | `CamLog` (fichier disque) | fichier disque (trivial) |
| Diagnostic appareil (dev) | `neovibe/diag` | `NativeDiagnostics` (`PackageManager` + `Build`) | `Bundle.main.infoDictionary` + `UIDevice` |
| **Installation d'APK (dev)** | `neovibe/install` | `NativeInstall` + `FileProvider` + `MediaStore` | *sans objet — iOS n'installe que par l'App Store ou TestFlight* |
| **Finesse de position accordée** | `neovibe/location` | `LocationGrant` (`checkSelfPermission` sur `ACCESS_FINE_LOCATION`) | `CLLocationManager.accuracyAuthorization` (`.fullAccuracy` / `.reducedAccuracy`) |

### Natif **fourni par un paquet**, donc rien à écrire — mais à connaître

Ces blocs ne sont pas de notre code. Ils figurent ici parce que la règle de ce
fichier est de **ne rien découvrir au dernier moment lors du portage iOS**, et
qu'un moteur natif tiers pèse sur le portage autant qu'un fichier `.kt` à nous.

| Bloc | Paquet | Android | iOS |
|---|---|---|---|
| **Moteur de rendu Rive** | `rive` 0.14.11 → `rive_native` 0.1.11 | `.so` par ABI (~7,3 Mo en arm64) | fourni par le paquet — **rien à écrire** |

Trois points à retenir pour le jour du portage :

1. **Initialisation obligatoire** : `await rive.RiveNative.init()` dans
   `main()`, avant tout `File.asset`. Enveloppé dans un `try` — un moteur
   indisponible ne doit pas empêcher l'app de démarrer, seulement faire retomber
   les boutons sur leur rendu Flutter.
2. **Coût réel : +7,3 Mo, pas +21,5.** Un appareil n'installe qu'une
   architecture. C'est ce qui a décidé du passage à `--split-per-abi`
   (2026-08-14) : **29,6 Mo en arm64 contre 83,1 Mo en APK gras**.
3. ⚠️ **Dette signalée par Flutter** : `rive_native` applique l'ancien plugin
   Kotlin (KGP). « Future versions of Flutter will fail to build if your app
   uses plugins that apply KGP. » À surveiller — même avertissement que
   `flutter_foreground_task`.

---

## 1. Caméra — le moteur

**Rôle** : aperçu, bascule, photo, vidéo, et le **double flux Oneshot** (deux
caméras en même temps).

**Canal** : `neovibe/camera`. Méthodes actuelles (contrat partagé) :
`open`, `close`, `switchLens`, `takePicture`, `startVideo`, `stopVideo`,
`normalize`, `capabilities`, `isCameraServiceAlive`, `setSecure`, `log`,
`readLog`, `clearLog`, `setFlash`, `hasFlash`, `setScreenFlash`,
`openGlPreview`, `closeGlPreview`, `openGlDual`, `closeGlDual`,
`captureGlDual`, `startGlDualVideo`, `stopGlDualVideo`.
Événements natif→Dart : `previewInfo`, `previewReady`.
*(Vérifié conforme au code le 2026-07-31.)*

> **`previewReady` — signal de PREMIÈRE IMAGE (ajouté le 2026-07-31)**.
> Émis une fois que la session caméra a réellement livré ses premières images
> après un bind (`open` ou `switchLens`). C'est ce qui corrige l'aperçu
> renversé pendant la bascule : CameraX annonce la nouvelle rotation
> d'affichage à la CONFIGURATION de session, donc avant les images — le Dart
> l'appliquait alors aux dernières images de la caméra précédente, encore dans
> la texture (180° d'écart entre l'arrière à 90° et l'avant à 270°).
> **Android** : `Camera2Interop.Extender(previewBuilder).setSessionCaptureCallback(…)`,
> puis comptage de 3 `onCaptureCompleted` avant d'émettre.
> **iOS** : l'équivalent est le premier `captureOutput(_:didOutput:from:)` de la
> nouvelle session — même contrat, même règle (n'annoncer l'aperçu vivant que
> sur une IMAGE, jamais sur une configuration).
> À noter : le moteur GPU (`Camera2Gl.kt`) n'a pas besoin de ce signal — il
> tourne l'image dans le shader et annonce `rotation = 0`. La sortie définitive
> du problème est donc le chantier de rendu GPU.

> **`setScreenFlash(on)` — assistance du FLASH FRONTAL (ajouté le 2026-07-31)**.
> La lueur d'écran elle-même est du **dessin Dart** (zéro natif, voir plus
> bas), mais deux choses n'existent qu'au niveau système :
> 1. **rétroéclairage à fond** — `window.attributes.screenBrightness = 1f`,
>    rendu au système (`BRIGHTNESS_OVERRIDE_NONE`) à l'extinction ET à la
>    fermeture de la caméra (sinon la batterie brûle dans le reste de l'app) ;
> 2. **correction d'exposition** — `CameraControl.setExposureCompensationIndex`
>    à la moitié du maximum annoncé par l'appareil, réappliquée à chaque bind.
> **iOS** : `UIScreen.main.brightness = 1.0` (restaurer la valeur d'origine) et
> `AVCaptureDevice.setExposureTargetBias(_:)`.

> **Flash (ajouté le 2026-07-26)** — `setFlash(mode)` avec
> `off` | `auto` | `on` | `torch`, et `hasFlash` pour savoir si la caméra
> active a une LED. Deux mécanismes distincts côté Android :
> `ImageCapture.flashMode` (déclenchement à la photo) et
> `CameraControl.enableTorch` (LED continue — le seul éclairage possible en
> vidéo). **Le mode est retenu côté natif et ré-appliqué à chaque bind** : une
> bascule de caméra crée une nouvelle instance et perdrait le réglage.
> iOS : `AVCaptureDevice.torchMode` / `flashMode`, même contrat, même piège
> (réappliquer après un changement d'entrée).
>
> **Flash FRONTAL : la LUEUR est en Dart, son ASSISTANCE est native.**
> Le dessin (pixels blancs à beige peints sur le contour de l'écran, faute de
> LED en façade) reste **entièrement en Dart** (`capture_tools.dart`) et ne
> coûte aucun portage. **Corrigé le 2026-07-31** : la mention « rien à écrire en
> natif » était fausse une fois le résultat comparé à Snapchat — le
> rétroéclairage et l'exposition du capteur ne sont accessibles que côté
> système. Voir `setScreenFlash` plus haut.

> **`normalize` prend un argument `hd` (2026-07-26)** — `true` : la face est
> mise au format **1440×2560** au lieu de 900×1600 (bouton HD de l'écran de
> capture). Aucun changement de configuration de la caméra : le cliché sortant
> d'`ImageCapture` est déjà en pleine résolution, c'est la normalisation qui
> décidait de la finesse conservée. Côté iOS, même signature attendue.

> **Retiré à l'étape 5d (2026-07-25)** : `openDual`, `takeDualPictures`,
> `startDualVideo`, `stopDualVideo` (ancien moteur double **logiciel**) et
> `probeDual` (sonde). Le double flux passe exclusivement par le moteur GPU.
> `switchLens` ne répond plus au retour du bind mais quand `CameraState` dit la
> caméra réellement ouverte — à reproduire sur iOS plutôt qu'un délai fixe.

**Android (fait)** :
- `NativeCamera.kt` — orchestration + **CameraX** pour tous les modes à une
  caméra (aperçu simple, Mono, recto/verso, vidéo simple, bascule pendant vidéo).
- `Camera2Gl.kt` — **double flux GPU** (chantier TERMINÉ, v0.9.23) : Camera2 brut +
  OpenGL ES (texture externe OES → shader → texture Flutter), photo par
  `glReadPixels`, **vidéo par `MediaCodec` H264 + `MediaMuxer`** (2e surface EGL
  sur l'input du codec — un `.mp4` par caméra). Deux instances = les deux caméras.
  Chaque instance est aussi un `DualAudioEncoder.AudioSink` (piste audio muxée).
- `DualAudioEncoder.kt` — **capture audio PARTAGÉE** (`AudioRecord` micro →
  encodeur AAC) pour la vidéo double : un seul flux audio muxé dans les DEUX
  vidéos (deux `AudioRecord` sur le même micro se battraient). Thread `nv-audio`.
- *(`Camera2Dual.kt` — ancien double flux logiciel — et `DualCameraProbe.kt` —
  sonde de capacité — ont été **SUPPRIMÉS** à l'étape 5d, le 2026-07-25. Rien à
  porter sur iOS : le double flux passe entièrement par le moteur GPU.)*
- `CamLog.kt` — journal (voir bloc 6).

**Audio (double vidéo)** : côté Android, `DualAudioEncoder` capture UNE fois
(`AudioRecord` + AAC) et muxe la même piste dans les deux `.mp4`. iOS : un seul
`AVCaptureAudioDataOutput` / entrée micro, écrit dans les deux `AVAssetWriter`.

> **Synchronisation A/V — piège à ne pas refaire sur iOS.** La capture audio
> démarre ~450 ms APRÈS les encodeurs vidéo. Normaliser chaque piste à zéro de
> son côté supprime ce décalage réel et met le son en AVANCE (bug v0.9.20,
> entendu par Jay). Les deux pistes doivent partager UNE origine : `Camera2Gl`
> note l'instant de sa 1re image encodée sur `System.nanoTime`
> (`videoFirstWallNs`) — la même horloge que l'audio — et `AudioSink
> .onAudioSample(buffer, info, sampleWallNs)` reçoit l'instant réel de chaque
> échantillon pour recaler son PTS. Ne PAS tenter de corréler l'horloge du
> capteur (elle est MONOTONIC ou BOOTTIME selon l'appareil). Sur iOS, même
> principe : `CMSampleBuffer` porte déjà un `presentationTimeStamp` sur une
> horloge commune — le conserver tel quel plutôt que de le remettre à zéro.

**iOS (à faire)** :
- **AVFoundation** : `AVCaptureSession` (une caméra) ; **`AVCaptureMultiCamSession`**
  pour le double flux (dispo iPhone XS+ ; `isMultiCamSupported` déclare la
  capacité — plus propre que sur Android où on force l'undeclared).
- **Rendu** : Metal (ou CoreImage) pour composer/afficher, via `FlutterTexture`.
- **Photo** : capture d'image depuis le flux (équivalent du `glReadPixels`), ou
  `AVCapturePhotoOutput`.
- **Vidéo** : `AVAssetWriter` (encodage H264/HEVC).
- **Points d'attention** : orientation (differs d'Android), miroir de la frontale,
  `isMultiCamSupported` = faux sur les vieux iPhone → repli séquentiel (comme le
  repli Android). Gestion thermique (le multicam chauffe).

---

## 2. Anti-capture (FLAG_SECURE)

**Rôle** : rendre les captures d'écran « coûteuses et visibles » (positionnement
assumé, pas d'impossibilité promise).

**Android (fait)** : `WindowManager.LayoutParams.FLAG_SECURE` posé/retiré via la
méthode `setSecure` du canal caméra (dans `NativeCamera.kt`). Bloque screenshots
et affiche un écran noir en capture/partage. **Désactivé par défaut en dev**
(voir `RAPPELS.md`), à réactiver avant la prod.

**iOS (à faire)** : **pas d'équivalent strict** — iOS n'autorise pas à bloquer
les captures d'écran comme FLAG_SECURE. Options :
- **détecter** les captures (`UIApplication.userDidTakeScreenshotNotification`)
  et l'enregistrement d'écran (`UIScreen.main.isCaptured`) → réagir (watermark,
  signalement) ;
- **occulter** le contenu quand l'app passe en arrière-plan.
→ Sur iOS, la couche **contractuelle/sociale + watermarking** (déjà prévue dans
l'architecture 4 couches) prend d'autant plus d'importance.

---

## 3. Proximité — BLE (détection + échange de contact + chat ping)

**Rôle** : détecter les pairs à proximité, échanger les mini-profils, et servir
de tuyau d'octets pour le **chat ping** (texte, petits paquets).

⚠️ **Entièrement reconstruit le 2026-08-16** (carte blanche de Jay). `NativeBle.kt`
et le canal `neovibe/ble` **n'existent plus**. Architecture complète :
`docs/architecture-proximite.md`.

**Deux canaux, et la séparation est volontaire** :

| Canal | Sens | Contenu |
|---|---|---|
| `neovibe/proximity` | Dart → natif | les **ordres** : `probe`, `start`, `stop`, `setAdvertPlan`, `setRecognitionTable`, `takeSightings`, `publicHeartbeat`, `stats`, `openLocationSettings`. ⚠️ **`updateAdvert` supprimé le 2026-08-25** (second chemin vers l'émission, incapable de porter le TYPE du jeton) ; ⚠️ **`connect`, `disconnect` et `send` supprimés le 2026-08-27**, avec tout le transport GATT ; ⚠️ **`advertCapabilities` supprimé le 2026-08-28** — aucun appelant Dart depuis que `stats()` fusionne la map entière des capacités (2026-08-26). |
| `neovibe/proximity/events` | natif → Dart | les **constats** : `status`, `scan`. ⚠️ **`link` et `frame` supprimés le 2026-08-27.** Le Dart ne sait plus les décoder : `RadioEvent.fromMap` les rendrait `null`. ⚠️ **`scan` porte `atMillis` depuis le 2026-08-28** — voir ci-dessous. |
| `setAdvertPlan` | Dart → natif | *(2026-08-20)* dépose des heures de jetons d'avance — correction du point H |
| `setRecognitionTable` | Dart → natif | *(2026-08-20)* jetons attendus → rangs, pour reconnaître sans le Dart |
| `takeSightings` | Dart → natif | *(2026-08-20)* récupère et vide ce que le service a constaté seul |
| `publicHeartbeat` | Dart → natif | *(2026-08-29)* **le battement de cœur de la découverte** — voir ci-dessous |

### 🔴 L'HOMME MORT de l'identifiant public (2026-08-29)

**Fichiers : `ProximityService.kt`, `AdvertSchedule.kt`, `ProximityBridge.kt`.**

Le défaut corrigé : le plan porte **75 minutes** de jetons d'avance, pour que le
service survive seul à la mort du Dart. C'est juste pour les jetons d'**ami** —
un ami reconnaît tout seul, sans réseau, app fermée. L'identifiant **public**,
lui, ne vaut rien sans la balise que le Dart republie au serveur toutes les
60 s et qui meurt 5 min après lui. L'appareil continuait donc de crier, **jusqu'à
70 minutes de plus**, un identifiant que plus personne ne pouvait traduire — mais
que n'importe quel scanner pouvait suivre.

| | |
|---|---|
| **Le battement** | `publicHeartbeat`, posé par le Dart à chaque republication **réussie** de sa balise serveur, et au dépôt d'un plan |
| **La grâce** | **5 minutes** — ce n'est pas un chiffre choisi, c'est `private.ping_beacon_ttl()` |
| **L'effet** | passé ce délai, `emitNext` filtre les jetons de type public ; **les jetons d'ami continuent** |
| **Le témoin** | `stats()` publie `publicMuted` et `publicHeartbeatAgeMillis` |

⚠️ **Le filtre est posé au seul endroit par lequel un jeton atteint la radio**
(`emitNext`), et le tri lui-même vit dans `AdvertSchedule.tokensAt(now,
avecPublic)`. Les modes parallèle et cycle partaient de deux calculs distincts :
une règle posée sur l'un ne s'appliquait pas à l'autre.

⚠️ **`AdvertSchedule.typeAt` a été supprimée** dans le même geste : sans
appelant en production, et surtout devenue **fausse** — elle indexait le curseur
sur le créneau complet alors que le mode cycle parcourt désormais la liste
filtrée.

⚠️ **À porter sur iOS** : le pendant iOS devra décider la même chose, et il n'a
pas de service de premier plan pour le faire — point à rouvrir au moment du
portage.

### ⚠️ Le plan d'émission est PERSISTÉ — et pas en entier (2026-08-28)

Fichier **`PlanStore.kt`** : le service écrit sur son disque de quoi reprendre
après la mort du **processus**. Avant, le plan vivait en mémoire seule : quand
Android récupérait l'app, le service redémarrait sans identifiant et s'arrêtait.
« Le croisement fonctionne app fermée » était donc vrai tant que le *processus*
vivait, pas tant que le téléphone était allumé.

**Décision de Jay, 2026-08-28 — à reconduire telle quelle sur iOS :**

| | Écrit sur le disque ? | Pourquoi |
|---|---|---|
| jetons de paire (amis) | **oui** | ce sont eux qui font le croisement app fermée |
| table de reconnaissance | **oui** | sans elle, l'appareil serait vu sans voir |
| identifiant **public** du ping | 🔴 **non** | il repart d'une graine neuve à chaque lancement — c'est ce qui empêche de relier deux sessions de découverte |

⚠️ **Conséquence assumée et VISIBLE** : après une reprise depuis le disque,
l'appareil croise ses amis mais **n'est pas découvrable par des inconnus** tant
que l'app n'a pas été rouverte. `stats()` publie **`resumedFromDisk`**, et le
rapport de diagnostic l'affiche — un prix qu'on ne voit pas est un prix qu'on
oublie d'avoir accepté.

⚠️ **Le fichier s'efface** à chaque démarrage demandé par le Dart (qui va en
déposer un neuf) **et** à chaque arrêt voulu. Sans ça, un compte laisserait
derrière lui des jetons que le suivant ferait crier — la fuite exacte que
l'effacement du carnet avait fermée côté Dart.

⚠️ **Aucun secret n'y est écrit** : ce sont des identifiants déjà calculés, ceux
que la radio crie en clair. Ce qu'ils donnent à qui lit le disque, c'est douze
heures de jetons d'avance — la même information qu'obtiendrait quelqu'un resté à
côté de l'appareil pendant douze heures.

⚠️ **`scan` porte la DATE de l'observation (`atMillis`), depuis le 2026-08-28 —
et c'est obligatoire côté iOS aussi.** Le service met de côté ce qu'il capte
quand l'interface est absente et le rejoue à son retour : sans cette date, le
Dart prend un souvenir vieux de plusieurs heures pour une présence, réaffiche le
pair « à portée » et envoie une notification « Le presque… » pour quelqu'un de
parti depuis longtemps. **Le natif publie quand il a entendu ; c'est le
consommateur Dart qui décide si c'est encore vrai** — et les deux consommateurs
n'ont pas le même seuil.

L'ancien code faisait remonter les événements par `invokeMethod` sur le canal de
commandes. Un flux qui remonte n'a pas les mêmes règles qu'un ordre qui descend —
il n'attend pas de réponse, il peut n'avoir aucun auditeur, et il doit survivre
au remplacement de l'interface.

**Android (fait, 2026-08-16 ; plan d'émission et reconnaissance ajoutés le 2026-08-20 ; persistance du plan le 2026-08-28)** — **sept** fichiers dans `ble/` :

- **`RadioStatus.kt`** — l'**état réel** de la radio, et le calcul des
  permissions réellement exigées selon la version d'Android. C'est le cœur du
  chantier : plus aucun échec silencieux.
- **`BleEngine.kt`** — advertising et scan. **Ne dépend d'aucune `Activity`.**
  Écoute `ACTION_STATE_CHANGED` : le Bluetooth rallumé relance tout seul.
  ⚠️ **Le serveur et le client GATT ont été SUPPRIMÉS le 2026-08-27** — environ
  300 lignes et la moitié des imports Bluetooth du fichier. Avec eux partent
  `connect` / `disconnect` / `send` / `mtuOf`, les files de notification, et les
  compteurs `pathStats` / `bothPathsPeak` qui mesuraient la dualité
  central/périphérique. **Conséquence pour iOS : `CBPeripheralManager` n'a plus
  à servir de serveur GATT, et `CBCentralManager` plus à se connecter** — la
  dualité disparaît, ce qui retire au portage sa difficulté la plus vicieuse.
  ⚠️ **`BleConstants.SERVICE_UUID` part aussi** : vérifié à l'inventaire, il
  n'apparaissait que dans le GATT — l'annonce ne porte que des
  `manufacturerData`. **Attention au portage iOS** : le scan en arrière-plan y
  exige justement un filtrage par UUID de service, donc il faudra peut-être en
  réintroduire un pour iOS, et l'annoncer côté Android.
- **`ProximityService.kt`** — service de premier plan qui **possède** le moteur
  et survit à la destruction de l'interface (décision de Jay). Sa notification
  dit l'état vrai.
- **`ProximityBridge.kt`** — le pont vers Dart. **Jetable** : il naît et meurt
  avec l'activité, le service reste.
- **`AdvertSchedule.kt`** — *(nouveau, 2026-08-20)* le **plan d'émission** :
  plusieurs heures de jetons calculés d'avance par le Dart, que le service
  déroule tout seul. C'est la correction du **point H** : le jeton dépend du
  créneau de 15 min, et tant que c'était un minuteur Dart qui poussait le
  suivant, l'identifiant se figeait dès qu'Android détruisait l'activité —
  l'appareil criait alors en permanence sans que personne ne le reconnaisse, et
  sans qu'aucune erreur ne soit levée.
  ⚠️ **Aucun secret ici, et aucune cryptographie.** Les jetons sont des
  identifiants déjà calculés : les dérober ne permet ni de suivre demain, ni
  d'en fabriquer d'autres. Toute la cryptographie reste en Dart.
  ⚠️ **Plan épuisé = silence**, jamais un jeton périmé rejoué : une annonce
  que plus personne n'attend est indiscernable d'une radio saine.
- **`SightingBook.kt`** — *(nouveau, 2026-08-20)* la **reconnaissance sans le
  Dart** : `RecognitionTable` (jeton attendu → rang) et `SightingBuffer` (les
  constats accumulés en attendant le retour du Dart). Sans lui, le service
  diffusait seul mais restait aveugle — l'appareil était **vu sans voir**, et le
  croisement, fait pour le téléphone dans la poche, ne se produisait jamais.
  ⚠️ **Le natif n'apprend AUCUNE identité** : la table associe un jeton à un
  **rang** (0, 1, 2…). Seul le Dart sait qui est le rang 3, et il le sait pour
  *cette* table — d'où le `tableId` renvoyé avec chaque constat, qui fait jeter
  les constats d'une table périmée au lieu de les attribuer au hasard.
  ⚠️ **Un jeton rejoué hors de son créneau est refusé** : sans cette fenêtre, il
  suffirait d'enregistrer une annonce le matin pour fabriquer un croisement le
  soir.
  ⚠️ **Logique volontairement PURE** (aucune dépendance Android) : c'est ce qui
  la rend vérifiable sur la JVM — 11 tests dans `SightingBookTest.kt`. Du code
  qui tourne quand l'interface est morte ne peut pas être validé « à l'usage ».
  ⚠️ **Les constats vivent en mémoire seulement.** Si Android tue le
  *processus* (et pas seulement l'interface), ils sont perdus — assumé : les
  écrire sur le disque depuis le natif poserait hors du Dart une trace de **qui
  a été croisé**, pour rattraper un cas rare.

  ⚠️ **À ne pas confondre avec `PlanStore`, qui LUI persiste** (2026-08-28) : un
  jeton d'émission est **opaque** — il ne nomme personne —, alors qu'un constat
  désigne quelqu'un. Deux objets, deux règles ; la différence est exactement
  celle qui décide de ce qui a le droit de toucher le disque.

- **`PlanStore.kt`** — *(nouveau, 2026-08-28)* le plan d'émission et la table
  **écrits sur le disque**, pour survivre à la mort du *processus*. Avant, le
  service relancé par Android n'avait plus rien à crier et s'arrêtait : « le
  croisement fonctionne app fermée » était vrai tant que le **processus**
  vivait, pas tant que le téléphone était allumé.
  ⚠️ **Les jetons d'AMIS seulement — décision de Jay, à reconduire sur iOS.**
  L'identifiant **public** du ping n'est jamais écrit : il repart d'une graine
  neuve à chaque lancement, et c'est ce qui empêche de relier deux sessions de
  découverte. Conséquence assumée : après une reprise, l'appareil croise ses
  amis mais **n'est pas découvrable par des inconnus** — publié dans `stats()`
  sous `resumedFromDisk`.
  ⚠️ **Le fichier s'efface** au démarrage demandé par le Dart et à l'arrêt
  voulu : sans ça, un compte laisserait derrière lui des jetons que le suivant
  ferait crier.
  ⚠️ **Séparé du `Context`** (il ne sert qu'à trouver le fichier) : c'est ce qui
  rend l'écriture et la relecture vérifiables sur la JVM — **9 tests dans
  `PlanStoreTest.kt`**. Ce code tourne **au seul moment où personne ne
  regarde** ; une panne y serait indiscernable de celle qu'il corrige.

- **`PresenceLog.kt`** — *(nouveau, 2026-08-30)* **combien de temps un ami a
  été là**, et non plus seulement « il était là ». Les règles de waves décidées
  par Jay le 2026-08-30 regardent la **durée** d'un contact ; `SightingBuffer`
  déduplique par `(ami, créneau)` et ne répond donc à aucune d'elles.
  ⚠️ **Le natif avait l'information et la jetait** : il voit chaque annonce,
  c'est la déduplication qui effaçait la durée. Ici, deux dates et un compteur
  par présence.
  ⚠️ **C'est la SEULE source des durées.** Le Dart sait aussi mesurer une
  présence (`PeerSession`), mais seulement tant que le pont est attaché — deux
  mesures d'un même fait, dont une avec des trous, c'est deux vérités à tenir
  d'accord, et rien ne les distingue une fois écrites.
  ⚠️ **Le seuil de coupure DESCEND du Dart** (`presenceGapMillis`, envoyé avec
  la table de reconnaissance) : c'est `PresenceRules.forgetAfter`, et il n'y a
  qu'une définition de « la présence est terminée ».
  ⚠️ **Plein, il jette le PLUS ANCIEN** — l'inverse de `SightingBuffer`, qui
  refuse les nouvelles entrées. La règle ne regarde que les trois dernières
  heures : perdre le récent serait perdre ce qu'il faut juger.
  Logique **PURE**, l'instant lui est passé — **9 tests dans
  `PresenceLogTest.kt`**, contre-test de la coupure compris.
  🍎 **iOS : à écrire, et c'est le même mur que `SightingBook`** — il suppose un
  processus qui survit à l'interface.

- **`SlotAlarm.kt`** — *(nouveau, 2026-08-30)* le **réveil qui sonne même quand
  l'appareil dort**. Le plan a rendu le natif indépendant du Dart pour savoir
  *quoi* crier ; la main qui **tourne la page** restait un
  `Handler.postDelayed`, et un `Handler` dort avec le processeur. En mode
  parallèle les jeux d'annonces sont déjà en l'air : la puce continue de
  rayonner seule, donc l'appareil endormi criait le jeton d'un créneau révolu
  **en continu, sans lever la moindre erreur**.
  ⚠️ **Mesuré au test de nuit du 2026-08-30** : la tablette a reçu 110 694
  jetons privés du téléphone et n'en a reconnu **aucun** ; les deux appareils ne
  se sont pas vus de 02:45 à 07:00.
  ⚠️ **`setAndAllowWhileIdle`, PAS `setExactAndAllowWhileIdle`** : la version
  exacte exige `SCHEDULE_EXACT_ALARM`, refusée par défaut sur Android 13 et
  réservée par Google Play aux réveils et aux agendas. L'exactitude n'est pas
  nécessaire — `RecognitionTable.match` tolère le créneau **à un près**.
  ⚠️ **Le quota Doze est d'un réveil par ~9 min** ; le créneau vaut 15 min. Un
  créneau raccourci sous 9 minutes rendrait ce réveil silencieusement
  insuffisant.
  ⚠️ **Récepteur enregistré à l'exécution**, jamais au manifeste : déclaré au
  manifeste, il relancerait le service après un arrêt voulu par l'utilisateur.
  Le calcul de la frontière est **pur** et éprouvé — 3 tests dans
  `SlotAlarmTest.kt`, dont le contre-test de la marge.
  🍎 **iOS : aucun équivalent, et c'est un mur connu.** Il n'y a pas d'API de
  réveil périodique en arrière-plan ; `CoreBluetooth` fait tourner l'advertising
  mais l'app ne choisit pas quand réécrire sa charge utile. À traiter avec
  `AdvertSchedule` et `SightingBook`, qui butent sur la même limite.

### 🔴 UN SEUL MODE EN L'AIR À LA SORTIE (2026-08-29)

**Fichier : `BleEngine.kt`.** Il y a **deux façons d'être en l'air** — les jeux
d'annonces **parallèles** (`AdvertisingSet`) et l'annonceur **legacy** du mode
cycle — et `ProximityService.emitNext()` est le seul à choisir entre les deux.

L'invariant, désormais imposé aux **trois** portes de sortie :

| Sortie | Ce qui doit être en l'air |
|---|---|
| `applyAdverts` réussit | N jeux parallèles, **aucune** annonce legacy |
| `updateAdvert` (cycle) | **une** annonce legacy, **zéro** jeu parallèle |
| `pauseAdvertising` (silence) | **rien du tout** |

⚠️ **Les deux dernières étaient fausses avant le 2026-08-29** : elles
n'arrêtaient que l'annonceur legacy. Conséquence relevée par Jay à deux
appareils : en passant de deux jetons à un (extinction de « Croiser mes
amis »), `applyAdverts` refusait le parallèle — il exige au moins deux jetons —
**sans raccrocher les jeux déjà en l'air**. L'appareil criait donc l'ancien plan
indéfiniment, jeton d'ami compris, pendant qu'il annonçait le nouveau en legacy.

⚠️ **Le même trou désarmait l'homme mort de l'identifiant public** : il
appelle `pauseAdvertising()` quand il ne reste rien à crier.

⚠️ **Rendu visible** : `stats()` publie `advertSetsOnAir`. En `cycle` il doit
valoir **0** ; « cycle » avec un nombre non nul est la signature exacte de ce
défaut. Un mode d'émission ne se constate pas par le drapeau qu'on a posé, mais
en comptant ce qui émet.

⚠️ **À porter sur iOS** : CoreBluetooth n'a qu'un seul annonceur, donc pas de
mode parallèle — mais la question « qu'est-ce qui reste en l'air après un
changement de plan ? » se reposera telle quelle.

### Le format d'annonce — protocole v5 (2026-08-26)

```
[0..1]  "NV"          magie
[2]     version = 5
[3]     TYPE          0x01 = identifiant PUBLIC · 0x02 = jeton d'AMI privé
[4..19] jeton         16 octets
```

20 octets de charge utile, **26 sur les 31** de la trame BLE avec la puissance
d'émission. Ne rien ajouter sans recompter.

⚠️ **Deux formats, deux chemins de traitement, et c'est une règle** (consigne de
Jay). Un jeton **public** est fait pour être capté sans être reconnu — c'est la
découverte d'inconnus, et lui seul ouvre un lien. Un jeton **privé** non reconnu
**se jette** : c'est le jeton d'une autre paire, pas un inconnu. Les confondre
faisait apparaître un ami à cinq amis comme **six appareils différents**.

⚠️ **Le natif ne DÉDUIT pas le type** : il le reçoit du Dart avec le plan
(`setAdvertPlan`, paramètre `types`). Savoir lequel est public est une règle
produit, elle vit d'un seul côté.

⚠️ **LE POINT DE CONTACT DART ↔ KOTLIN, ajouté le 2026-08-29.** Le plan
d'émission et la table de reconnaissance sont **écrits en Dart et lus en
Kotlin**. Chaque côté avait ses tests, **avec ses propres fixtures** : rien ne
vérifiait qu'ils rangent les octets de la même façon. Une transposition y serait
parfaitement silencieuse — tout compile, tous les tests restent verts, et le seul
symptôme est *« entendu dix fois par seconde, reconnu zéro fois »*.

Dispositif, calqué sur celui du format scellé : `test/recognition_vectors_test.dart`
produit et **revérifie à chaque exécution** le manifeste
`android/app/src/test/resources/recognition-vectors/manifest.json` ;
`RecognitionVectorsTest.kt` le relit et éprouve `RecognitionTable` **et**
`AdvertSchedule` dessus. ⚠️ **Ne jamais régénérer pour faire passer un test** :
les deux implémentations resteraient fausses ensemble, et plus rien ne les
départagerait. Régénération délibérée :
`NEOVIBE_REGEN=1 flutter test test/recognition_vectors_test.dart`.

⚠️ **À porter sur iOS**, et c'est là que ça paiera : une troisième
implémentation du même accord, sans point de contact, est une divergence promise.

- **`AdvertOnAir.kt`** — *(nouveau, 2026-08-29)* **ce que la pile a accepté de
  mettre en l'air**, par opposition à ce qu'on lui a demandé. Trois états par
  jeu d'annonce : *demandé*, *en vol*, *confirmé*.
  🔴 **Il existe parce que `AdvertisingSet.setAdvertisingData()` est
  asynchrone** : elle ne rend rien, ne lève rien, et rapporte son sort dans
  `onAdvertisingDataSet(set, status)` — un rappel qui **n'était pas écrit**. Un
  refus de la pile ne se voyait donc nulle part : le jeu continuait de rayonner
  le jeton d'un créneau révolu, et l'appareil était entendu dix fois par seconde
  et reconnu **zéro** fois, pendant que tous ses compteurs disaient que tout
  allait bien.
  ⚠️ **À écrire sur iOS aussi, et la question y est la même** :
  `CBPeripheralManager.startAdvertising` répond dans
  `peripheralManagerDidStartAdvertising(_:error:)`. Le piège n'est pas l'API,
  c'est de croire qu'une demande vaut une émission.
  ⚠️ **Il sert aussi à ne PAS réécrire pour rien** : `emitNext` repassait toutes
  les 30 s sur un contenu qui ne change que tous les quarts d'heure — ~2 900
  écrits inutiles par appareil et par nuit, chacun une occasion de refus.
  ⚠️ **Logique PURE**, comme `SightingBook` et `AdvertSchedule` : 11 tests dans
  `AdvertOnAirTest.kt`, dont deux nés d'un **contre-test** (défaut réintroduit,
  aucun test ne tombait).

⚠️ **Cinq compteurs de diagnostic remontent par `stats()`** et doivent rester
visibles même à zéro — le jour où ils montent, ils expliquent une détection
fantôme que rien d'autre n'expliquerait :

| Compteur | Où il est compté | Ce qu'il dit |
|---|---|---|
| `otherVersionScans` | `BleEngine` | des annonces d'une **autre version** du protocole : les appareils ne sont pas à jour ensemble |
| `selfScans` | `BleEngine` | on capte **sa propre** annonce — sans filtre, on se reconnaîtrait comme l'ami à qui on crie |
| `foreignTokenScans` | **`ProximityService`** | des jetons privés **destinés à quelqu'un d'autre**, écartés |
| `advertSlotDrift` | **`AdvertOnAir`** → `ProximityService` | **de quand date ce qui rayonne**. `0` = le jeton du créneau courant ; toute autre valeur = on crie le passé, donc on est entendu par tous et reconnu par personne. `-1` = aucun jeu confirmé |
| `advertDataRefus` | **`AdvertOnAir`** | la pile a **refusé** un contenu d'annonce — la seule trace qu'un refus ait existé |
| `advertSlotDriftMax` / `...MaxAgeMillis` | **`ProximityService`** | 🔴 **la PIRE dérive depuis le démarrage, et son âge.** `advertSlotDrift` ne dit que l'instant présent — or on ne lit un diagnostic qu'après avoir réveillé l'appareil, donc après l'avoir réparé. Le 2026-08-30 il affichait `0` au terme d'une nuit entière de dérive. Une trace haute survit au réveil, donc elle peut accuser |
| `slotAlarmReveils` / `slotAlarmRetardMaxMillis` | **`SlotAlarm`** | le réveil de veille a-t-il sonné, et avec quel retard. Sans eux, une dérive nulle ne distingue pas « c'est réparé » de « l'alarme n'a jamais été honorée » |

🔴 **`foreignTokenScans` a changé de maison le 2026-08-28, et c'est une leçon à
porter sur iOS.** Il était déclaré dans `BleEngine`, publié dans `stats()`… et
**jamais incrémenté** : le rapport de diagnostic affichait donc un zéro
permanent présenté comme une mesure — exactement le « seau vide » que ces trois
compteurs existent pour éviter. Le moteur radio **ne peut pas** le compter : il
ne détient pas la table de reconnaissance, donc il ne sait pas distinguer un
jeton étranger d'un jeton attendu. Celui qui le sait, c'est le service.
**Un compteur se place là où vit l'information qu'il mesure.**

⚠️ **Auto-filtre obligatoire** (`BleEngine.ownTokens`) : le jeton de paire est
**symétrique**, donc celui qu'on émet pour un ami est celui qu'on attend de lui.
Sans filtre, capter sa propre annonce revient à voir cet ami.

⚠️ Déclarer le service au manifeste avec
`android:foregroundServiceType="connectedDevice|location"`, et la permission
`FOREGROUND_SERVICE_LOCATION` **non bornée** : à partir d'Android 14, tout type
déclaré sur un `<service>` exige sa permission, utilisé ou non à l'exécution.

⚠️ **`BLUETOOTH_CONNECT` a été retirée le 2026-08-27**, avec le bloc GATT. Sur
Android 12+ elle ne sert qu'à ouvrir une connexion ou un serveur GATT ; annoncer
et scanner relèvent de `BLUETOOTH_ADVERTISE` et `BLUETOOTH_SCAN`. Il ne reste
donc que **deux** permissions Bluetooth à demander à l'exécution — une de moins à
justifier à la Play Console. ⚠️ **C'est le seul changement de ce chantier qui ne
peut se confirmer que sur l'appareil** : si la radio se tait au prochain test,
c'est la première ligne à remettre, et le diagnostic le dira (`rawScans`,
`advertMode`).

⚠️ **Le type `connectedDevice` du service reste déclaré**, alors qu'il n'y a plus
aucun appareil connecté. Il couvre l'usage BLE au sens large, mais c'est
désormais **plus large que la vérité** — à revoir avec le point de `RAPPELS.md`
#71 sur la justification par type à la Play Console.

⚠️ **`minSdk = 29` depuis le 2026-08-25 — le plancher a bougé deux fois.**

| Date | Plancher | Pourquoi |
|---|---|---|
| avant le 2026-08-20 | 26 | BLE stable + canaux de notification |
| 2026-08-20 | **31** | sous Android 12, le scan en arrière-plan semblait exiger « Autoriser la localisation tout le temps » |
| 2026-08-25 | **29** | cette exigence n'existe pas : un service de type `location` suffit |

**Le modèle de permission dépend donc de la version, et c'est le natif qui
tranche** (`BlePermissions.required()`), jamais le Dart :

- **API 31+** — `BLUETOOTH_SCAN` avec `neverForLocation` : **aucune** permission
  de localisation. Le `maxSdkVersion="30"` posé sur `ACCESS_FINE_LOCATION`,
  `BLUETOOTH` et `BLUETOOTH_ADMIN` garantit qu'elles **n'existent pas** sur ces
  appareils — vérifié sur le manifeste fusionné *release* le 2026-08-25.
- **API 29/30** — `ACCESS_FINE_LOCATION` en « pendant l'utilisation », **plus**
  le type `location` sur le service de premier plan. Sans ce type, interface
  fermée, `onScanResult` ne remonte rien, **sans erreur ni trace**.
  `ACCESS_BACKGROUND_LOCATION` n'est **pas** demandée : elle ne servirait qu'à
  démarrer un scan sans interface, ce que nous ne faisons jamais.

⚠️ **Le type `location` est déclaré sur TOUTES les versions depuis le
2026-08-27** — cette section disait le contraire, et c'était juste tant que le
service ne faisait que du BLE. **Le ping v2 a changé la prémisse** : le service
lit désormais une vraie position, et Android ne la rend fine en arrière-plan
qu'à une app portant ce type. Sans lui, l'incertitude annoncée passait de 129 m
à **449 m**, la balise cessait d'être republiée, et l'utilisateur disparaissait
de l'écran d'en face. Voir `RAPPELS.md` #71.

⚠️ **`ACCESS_BACKGROUND_LOCATION` reste inutile pour autant** : avec ce type,
« pendant l'utilisation » suffit — y compris pour lire une position. C'est ce
qui évite l'invite la plus dissuasive d'Android sur une app dont la thèse est la
confiance.

⚠️ **Sur API 29/30, l'interrupteur de localisation du SYSTÈME doit être allumé** —
la permission ne le remplace pas. Sinon `startScan` réussit et ne rend jamais
rien. C'est l'état `RadioStatus.LocationOff`, rendu inatteignable au-dessus de
l'API 30 par `evaluateRadio`, et le canal `openLocationSettings` qui va avec.

⚠️ **Ces trois prérequis sont exposés au diagnostic** (`stats()` :
`needsLocation`, `fgsLocationType`, `locationEnabled`) précisément parce
qu'aucun des trois ne lève d'erreur quand il manque. Voir `RAPPELS.md` #57.

**iOS (à faire)** — **CoreBluetooth**, et il faudra concevoir un **mode
dégradé** :

- `CBPeripheralManager` (advertising **seul**), `CBCentralManager` (scan
  **seul**) — ⚠️ **plus aucun GATT depuis le 2026-08-27**, ni serveur ni client ;
- ⚠️ **Le modèle Android ne se transpose pas.** iOS n'a pas d'équivalent du
  service de premier plan : le scan en arrière-plan est très restreint
  (filtrage obligatoire par UUID de service, pas de scan continu, réveils
  limités) et **l'advertising en arrière-plan ne transporte pas les données de
  fabricant** — or c'est là que voyage notre ID rotatif. La reconnaissance
  silencieuse des amis app fermée devra donc être repensée, pas seulement
  portée.
- ⚠️ **Ce qui se porte tel quel, en revanche** : tout ce qui est au-dessus de la
  radio est en Dart pur et sans dépendance Android — présence, registre de pairs,
  plan d'émission, table de reconnaissance. Seule la couche 0 est à réécrire.
  *(Le transport, le canal sécurisé et le protocole de fil figuraient ici jusqu'au
  2026-08-27 ; ils n'existent plus.)*
- ⚠️ **`SightingBook` non plus.** Reconnaître sans le Dart suppose un processus
  qui scanne en continu et garde un état — iOS ne le donne pas. Mais la logique
  est pure et sans dépendance Android : elle se transpose en Swift telle quelle,
  c'est **quand** elle tourne qui change.
- ⚠️ **Le mode d'émission PARALLÈLE ne se transpose pas non plus (2026-08-26).**
  Android sait émettre plusieurs annonces simultanées (`startAdvertisingSet`,
  API 26+), ce qui corrige un défaut d'échelle réel : en cycle, le jeton d'un ami
  n'est en l'air que 1/N du temps. **iOS n'offre rien d'équivalent** —
  `CBPeripheralManager.startAdvertising` ne gère **qu'une seule** annonce à la
  fois, et il n'y a pas d'API de jeux d'annonces. Le portage devra donc soit
  cycler (avec le défaut d'échelle assumé, et documenté à l'écran), soit repenser
  la reconnaissance d'amis autrement sur iOS. **À trancher au portage, pas
  avant.**
- ⚠️ **`AdvertSchedule` n'a PAS d'équivalent iOS évident.** Le plan suppose un
  processus qui survit à l'interface et qui peut changer son annonce tout seul —
  exactement ce qu'iOS ne donne pas. Le calcul du plan, lui, est en Dart pur
  (`advert_plan.dart`) et se porte sans rien changer : c'est **l'exécution** qui
  est à repenser, pas le contenu.
- ⚠️ **Depuis le 2026-08-20, l'appareil émet N jetons différents** (un par ami)
  au lieu d'un identifiant unique. Sur iOS, où l'advertising en arrière-plan ne
  transporte pas les données de fabricant, cette contrainte s'ajoute à celles
  déjà listées.

---

## 4. ~~Proximité — transfert média (Wi-Fi Direct)~~ — ABANDONNÉ

> 🔴 **Décision de Jay, 2026-08-27** : *« on annule le transfert de média via
> Wi-Fi Direct, on passera toute la messagerie par internet. Notre objectif n'est
> plus une app de messagerie pair-à-pair, mais une app sociale qui mise sur la
> proximité, et le BLE n'est maintenant qu'un outil pour PROUVER la proximité,
> non pour échanger. »*
>
> **Rien n'est perdu** : ce bloc n'avait jamais été écrit. Ce qui disparaît est
> une intention, pas du code.
>
> ✅ **Ce que ça allège pour iOS** : plus de `MultipeerConnectivity`, et surtout
> plus besoin de faire transiter un contenu hors du serveur — donc **un seul
> contexte de diffusion par média**, ce que la règle 5 de `CLAUDE.md` exige de
> toute façon.
>
> ⚠️ **Ce que ça coûte, et qui n'est pas technique** : toute la bande passante
> vidéo passe désormais par l'hébergement, sans exception. À relire avec le
> cadrage hébergement de `RAPPELS.md` avant la prod.

*Texte d'origine conservé ci-dessous pour mémoire.*


**Rôle** : envoyer des cards/médias dans les conversations éphémères (le chat
ping reste en BLE ; les médias passeront par un canal plus gros).

**Android (à venir)** : **Wi-Fi Direct** (API Wi-Fi P2P). **Pas encore
implémenté** (chantier promis, voir `RAPPELS.md`).

**iOS (à faire)** : **MultipeerConnectivity** (`MCSession`, `MCNearbyService
Advertiser/Browser`). Pas de Wi-Fi Direct sur iOS — modèle différent (peut
combiner Wi-Fi + Bluetooth automatiquement). Interface de pont à concevoir
**neutre** dès le départ pour couvrir les deux.

---

## 4 bis. Média hors caméra — image de couverture d'une vidéo

**Rôle** : produire une **image de couverture** (JPEG) à partir d'un fichier
vidéo **local**, pour les vignettes des grilles. Une vidéo ne se décode pas
comme une image côté Dart (« Invalid image data ») : seul le natif sait lire une
frame. Ajouté le 2026-07-25 (consigne Jay : plus d'icône grise à la place des
faces filmées).

**Canal** : `neovibe/media`. Méthode unique :
`videoThumbnail(source, dest, width) -> String (chemin écrit)`.
Erreurs : `BAD_ARGS`, `THUMB_FAILED` (l'appelant retombe sur le repli visuel,
jamais bloquant).

**Android (fait)** : `NativeMedia.kt` — `MediaMetadataRetriever.getFrameAtTime(
0, OPTION_CLOSEST_SYNC)` sur un exécuteur dédié (jamais le thread principal),
mise à l'échelle, JPEG qualité 85, écriture `.part` puis renommage.

**iOS (à faire)** : `AVAssetImageGenerator` sur un `AVURLAsset`
(`appliesPreferredTrackTransform = true` pour respecter la rotation, comme le
fait `MediaMetadataRetriever` sur Android), `copyCGImage(at: .zero)`, puis
`UIImage.jpegData(compressionQuality: 0.85)`. Même contrat de canal.

> **Point à vérifier au portage** : Android renvoie la frame **déjà orientée**
> selon la rotation déclarée dans le fichier. Sur iOS ce n'est vrai que si
> `appliesPreferredTrackTransform` est activé — sinon les vignettes des vidéos
> portrait sortiront couchées.

**Appel Dart** : `lib/features/cards/native_media.dart` ; le cache et la
politique (« extraire au premier affichage, garder à côté du fichier ») vivent
dans `CardMediaCache.videoThumb`.

---

## 5. Hôte / cycle de vie

**Android (fait)** : `MainActivity.kt` = **`FlutterFragmentActivity`** (et NON
`FlutterActivity`) — CameraX exige un `LifecycleOwner`, que seule la variante
Fragment fournit. Enregistre les canaux caméra + proximité + média + **lecteur vidéo**
(bloc 7), initialise `CamLog`, et **libère les lecteurs dans `onDestroy`** — un
ExoPlayer non libéré garde son décodeur matériel.

**iOS (à faire)** : `AppDelegate` + `FlutterViewController` ; enregistrement des
`FlutterMethodChannel` côté Swift ; gestion du cycle de vie (permissions caméra/
micro/Bluetooth via `Info.plist` : `NSCameraUsageDescription`,
`NSBluetoothAlwaysUsageDescription`, etc.).

---

## 6. Journal caméra persistant (outil dev)

**Android (fait)** : `CamLog.kt` — écrit un journal sur le disque privé de l'app
(survit aux crashes), lu via Réglages → Développeur. **À retirer avec la section
dev avant la prod** (voir `RAPPELS.md`).

**iOS (à faire, si conservé en dev)** : écriture fichier équivalente (trivial).
Outil de dev seulement — non prioritaire pour un portage.

---

## 6 ter. Finesse de position réellement accordée

**Canal** : `neovibe/location`. Méthode unique : `grant` → `{fine, coarse}`,
deux booléens.

**Android (fait, 2026-08-26)** : `LocationGrant.kt` —
`Context.checkSelfPermission(ACCESS_FINE_LOCATION)`. Aucune demande, aucun
réglage ouvert : ce pont **constate**, il ne décide de rien.

**Pourquoi c'est natif** : `geolocator` ne distingue pas
`ACCESS_FINE_LOCATION` de `ACCESS_COARSE_LOCATION` — il rend `whileInUse` dans
les deux cas. Or depuis Android 12 c'est exactement la question à poser.

**Ce que ça remplace, et ce que ça a coûté** : le Dart déduisait « position
approximative » de la précision de la **dernière position connue** (> 500 m).
C'est un raisonnement sur un cache, pas sur une permission — un point réseau
imprécis suffisait à déclarer la permission insuffisante alors qu'elle ne
l'était pas. L'app réclamait alors un réglage déjà fait, sans issue possible, et
la balise de ping ne partait jamais. Relevé sur l'appareil de Jay le
2026-08-26 : une seule ligne dans `ping_beacons` là où il en fallait deux.

**iOS (à faire)** : `CLLocationManager.accuracyAuthorization`, qui vaut
`.fullAccuracy` ou `.reducedAccuracy` — la correspondance est directe. À noter
pour le portage : iOS permet en plus de demander la précision complète
**temporairement**, pour un usage nommé
(`requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`), ce qu'Android ne
sait pas faire. Décision produit à prendre à ce moment-là, pas maintenant.

---

## 6 bis. Diagnostic appareil (outil dev)

**Canal** : `neovibe/diag`. Méthode unique : `deviceInfo` → `appVersion`,
`appBuild`, `model`, `android`.

**Android (fait, 2026-08-13)** : `NativeDiagnostics.kt` —
`PackageManager.getPackageInfo` pour la version installée, `android.os.Build`
pour le modèle et la version d'OS.

**Pourquoi c'est natif** : la version de l'app vit dans `pubspec.yaml` et
**Flutter ne l'expose pas au Dart**. La recopier dans une constante Dart
créerait une seconde source de vérité à tenir à la main — et un numéro de
version faux dans un rapport de diagnostic fait chercher le bug dans la
mauvaise version. Lue dans le paquet installé, elle ne peut pas dériver.

Alimente le bouton **« Tout copier pour diagnostic »**
(`lib/core/diagnostics/diagnostic_bundle.dart`), demandé par Jay le 2026-08-13.

**iOS (à faire, si conservé en dev)** : `Bundle.main.infoDictionary` pour
`CFBundleShortVersionString` / `CFBundleVersion`, `UIDevice.current` +
`utsname` pour le modèle. **À retirer avec la section dev avant la prod.**

---

## 7. Lecteur vidéo natif des médias scellés

**Décision de Jay, 2026-08-12** : la lecture native directe, choisie contre les
deux correctifs Dart possibles, en assumant d'écrire ce code **deux fois** —
« la priorité c'est la sécurité et le confort des utilisateurs ».

Ce que ce lecteur remplace : un serveur HTTP local sur `127.0.0.1` qui
déchiffrait en Dart, sur l'isolate qui dessine l'écran. Trois pièces ont disparu
avec lui — le socket, le jeton qui empêchait une autre application du téléphone
de deviner l'URL, et l'**exception réseau en clair** qu'il fallait déclarer par
OS (`network_security_config.xml` côté Android, `NSAllowsLocalNetworking` côté
iOS). Cette section décrivait cette exception jusqu'au 2026-08-12 ; elle n'a plus
d'objet, **et c'est le but** : la cause est supprimée, pas entourée.

### Android (fait, 2026-08-12)

| Fichier | Rôle |
|---|---|
| `SealedChunkReader.kt` | lit le format `NVC1` en accès aléatoire, AES-GCM par `javax.crypto` (instructions AES du processeur) |
| `SealedDataSource.kt` | l'expose à ExoPlayer comme une `androidx.media3.datasource.DataSource` |
| `SealedChunkStore.kt` | d'où viennent les octets scellés : fichier local, ou **intervalles HTTP + cache partiel** (`RemoteChunkStore`, `HttpRangeFetcher`) |
| `Mp4FastStart.kt` | déplace l'index MP4 (`moov`) en tête, pour décoder dès les premiers octets reçus |
| `NativePlayer.kt` | l'ExoPlayer lui-même, rendu dans un `TextureRegistry.SurfaceProducer` ; canal `neovibe/player` + `neovibe/player/events/<id>` |

Dépendances ajoutées : `androidx.media3:media3-exoplayer`, `-datasource`,
`-common`, en **1.9.2** — la version qu'apporte déjà `video_player_android`.
Deux versions de media3 dans un même APK ne se concilient pas, et la plus haute
gagnerait en silence.

#### Contrat du canal `neovibe/player`

`create` rend **un dictionnaire**, et non un identifiant seul :

| Clé | Type | Sens |
|---|---|---|
| `id` | entier | l'identifiant de texture, à donner au widget `Texture` |
| `availability` | texte | `complete`, `partial` ou `cold` — ce que l'appareil possédait **avant** cette ouverture |

⚠️ **`availability` doit venir du natif, et de lui seul** (depuis le
2026-08-13). Le Dart avait tenté de le déduire de l'existence du fichier de
cache : c'est faux par construction, `RemoteChunkStore` donnant au fichier sa
taille définitive dès le premier bloc et l'index étant posé à l'ouverture. Une
vidéo vue deux secondes passait pour « déjà sur l'appareil ». Seul le magasin
connaît la carte des blocs. **Tout portage doit rendre ces trois valeurs**,
sans quoi la mesure d'ouverture redevient illisible sur cette plateforme.

### iOS (à faire)

L'équivalent est **`AVAssetResourceLoaderDelegate`** : on crée un `AVURLAsset`
sur une URL à schéma bidon, et le système demande des **intervalles d'octets**
au délégué, qui les sert déchiffrés. Le principe est exactement celui de la
`DataSource` Android — c'est la même architecture, écrite deux fois.

- Le déchiffrement passe par **CryptoKit** (`AES.GCM.open`), accéléré
  matériellement comme `javax.crypto`.
- **Le streaming par intervalles est à porter avec** : `AVAssetResourceLoader`
  demande justement des intervalles d'octets, ce qui correspond exactement à
  `RemoteChunkStore`. Le cache partiel, lui, est de la logique de fichiers —
  transposable presque telle quelle.
- Le rendu passe par une texture Flutter (`FlutterTexture` +
  `CVPixelBuffer` via `AVPlayerItemVideoOutput`), ou par un `platform view`
  selon ce qui se révèle le plus simple à l'écriture.
- **Le portage devra rejouer les vecteurs de test croisés** (§ ci-dessous) :
  c'est la seule chose qui garantira que la troisième implémentation du format
  lit bien ce que le Dart a scellé.
- **`availability` est à porter aussi** (voir le contrat du canal ci-dessus) :
  l'équivalent iOS de `RemoteChunkStore` devra distinguer « jamais vu » de
  « vu mais incomplet », faute de quoi la mesure d'ouverture mélangera sur iOS
  les deux populations que ce champ sert à séparer.

### Le format, et ce qui empêche les implémentations de diverger

Le format `NVC1` est spécifié dans **`docs/format-media-scelle.md`**, et les
**vecteurs de test croisés** (`android/app/src/test/resources/seal-vectors/`)
sont rejoués par les deux côtés :

- Dart : `test/sealed_format_vectors_test.dart`
- Kotlin : `android/app/src/test/kotlin/…/SealedChunkReaderTest.kt`

Une divergence entre implémentations ne se voit **ni à la compilation, ni au
diff, ni à `flutter analyze`** — seulement à l'exécution, sur l'appareil. Ces
vecteurs sont le seul dispositif qui l'attrape. Ne jamais les régénérer pour
faire passer un test.

⚠️ **Le format hérité (bloc unique, antérieur au 2026-08-12) n'est PAS porté en
natif** — il garde son chemin Dart et s'éteindra de lui-même (voir `RAPPELS.md`,
décisions en attente #11).

---

## 7 bis. Gestes de bord — ce qu'iOS attend et que nous avons désactivé

**Relevé le 2026-08-16, sans rapport avec un chantier en cours : à traiter avant
le portage.**

`NeoTheme` impose `NeoPageTransitionsBuilder` **aussi sur iOS**
(`core/theme.dart`, `pageTransitionsTheme`). Or c'est le constructeur de
transition qui fournit le **glissement de retour interactif** depuis le bord
gauche — celui que tout utilisateur d'iPhone considère comme acquis, au point
de ne plus viser les boutons.

**En l'état, le portage iOS n'aurait pas ce geste.** Aucune erreur ne le
signalera : une transition personnalisée qui ne le fournit pas est parfaitement
valide, elle est juste étrangère à la plateforme.

Deux façons de le régler, à trancher au moment du portage :

1. rendre `NeoPageTransitionsBuilder` interactif sur iOS (il faut alors gérer
   soi-même le suivi du doigt et l'annulation) ;
2. n'appliquer notre transition qu'à Android et laisser
   `CupertinoPageTransitionsBuilder` sur iOS — au prix de deux grammaires de
   mouvement, ce que le système de mouvement cherche précisément à éviter.

### Le bord DROIT, lui, est libre sur iOS

Android réserve **les deux** bords pour son geste « retour » ; iOS ne réserve
que le **gauche**. Le glissement de sortie de l'écran de capture (bord droit,
depuis le 2026-08-16) n'a donc pas d'équivalent système à contourner sur iOS —
il n'y a rien à écrire côté natif pour lui.

⚠️ **Côté Android**, si l'on voulait un jour que ce geste passe AVANT celui du
système sur un appareil en navigation par gestes, il faudrait déclarer une zone
d'exclusion (`View.setSystemGestureExclusionRects`) — que Flutter n'expose pas,
donc un canal de plus.

🔴 **Corrigé le 2026-08-16 après test de Jay sur tablette.** Ce paragraphe se
terminait par : *« Non fait, et volontairement : le geste système fait déjà
exactement la même chose (revenir en arrière). »* **C'est faux, et ça fermait
l'app.** Les deux gestes décident au même instant — le relâchement — et quand
les deux sont délivrés, notre sortie ferme la caméra puis le retour système
dépile l'accueil devenu sommet.

**La zone d'exclusion reste écartée, mais pour un meilleur motif** : elle est
plafonnée par le système à ~200 dp par bord, soit environ un cinquième de la
hauteur d'une tablette — un garde-fou qui échoue précisément sur les grands
écrans. La solution retenue ne demande **aucun natif** : `MediaQuery.
systemGestureInsetsOf` dit où le système a posé sa zone, et notre bande ne
s'arme que là où cette marge est nulle (navigation à 3 boutons). **Rien à écrire
pour iOS non plus** — iOS ne réserve que le bord gauche, et ces marges y valent
zéro à droite.

## 7 ter. Installation d'une mise à jour depuis l'app — **OUTIL DE DEV**

**Rôle** : télécharger l'APK de la dernière release et lancer l'installateur
système. Demande de Jay du 2026-08-16, pour raccourcir la boucle de test.

**Canal** : `neovibe/install`. Méthodes : `publish` (dépose une copie dans les
Téléchargements via `MediaStore`), `install` (lance l'installateur).

**Android (fait, 2026-08-16)** : `NativeInstall.kt`, plus un `FileProvider`
d'autorité `${applicationId}.updates` et `res/xml/file_paths_updates.xml`.

⚠️ **Android n'autorise AUCUNE installation silencieuse.** Le système affiche
toujours sa confirmation ; seule une application propriétaire de l'appareil
(kiosque, MDM) y échappe. Le bouton supprime les gestes *avant* la
confirmation, pas la confirmation.

⚠️ **À RETIRER AVANT LA PROD**, avec trois choses qui ne sont pas dans le
dossier Développeur : la permission `REQUEST_INSTALL_PACKAGES` (Google Play la
restreint fortement), le `FileProvider`, et la table `dev_reports`. Voir
`RAPPELS.md` #19.

**iOS** : **sans objet**. Une app iOS ne peut pas en installer une autre ;
la distribution de test passe par TestFlight. Rien à porter.

---

## 8. Notifications push (à vérifier)

**Statut** : la logique de notifications existe côté Dart (`notification_service.
dart`). **À auditer** : le transport push (FCM ?) et sa config par OS (APNs pour
iOS) au moment du portage. Compléter cette entrée quand le mécanisme est confirmé.
