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
| **Galerie du téléphone** *(2026-09-15, **albums et filtres le 2026-09-17** ; côté Dart sous `cards/editor/gallery/` depuis le 2026-09-21, ne sert plus qu'à l'autocollant image)* | `neovibe/gallery` | `NativeGallery` (`MediaStore` paginé par `Bundle`, **`albums()` agrégé par `BUCKET_ID`**, `list()` filtrable par dossier et par type, `loadThumbnail`, copie dans le cache) | `PHPhotoLibrary` / `PHImageManager` (`requestImage`, `requestExportSession`) + **`PHAssetCollection.fetchAssetCollections`** pour les albums |
| Média (hors caméra) *(étendu le 2026-09-18)* | `neovibe/media` | `NativeMedia` (couverture d'une vidéo, sonde, JPEG, **clair d'un scellé**) + **`MediaTranscoder`** (rognage, recadrage, matrice de couleurs, recompression H.264 par `MediaCodec` + GL) | `AVAssetImageGenerator`, `CGImageSource`, `AVAssetExportSession` + `AVVideoComposition` + `CIFilter` ; `unseal` : `CryptoKit` `AES.GCM` (le même lecteur de blocs que le lecteur vidéo) |
| Proximité BLE | `neovibe/proximity` + `/events` | Service de premier plan qui POSSÈDE la radio (advertise + scan) | CoreBluetooth, **mode dégradé à concevoir** |
| ~~Transport GATT (liens, trames)~~ | — | **SUPPRIMÉ le 2026-08-27** — le BLE ne fait plus que prouver la proximité | *sans objet* |
| ~~Transfert média proximité~~ | — | **ABANDONNÉ le 2026-08-27** — tout le contenu passe par le serveur | *sans objet* |
| **Présence à un événement, app fermée** *(2026-09-21)* | `neovibe/event_presence` + `/events` | `events/` : `EventPresenceService` (premier plan type **`location`**, une position par minute → `report_event_position` par `SupabaseHttp.rpcText`, s'arrête sur `away` / `none` / jeton refusé), `EventPresenceBridge`, `EventPresenceHub` | `CLLocationManager` avec `allowsBackgroundLocationUpdates` + mode d'arrière-plan « location » ; même RPC |
| **File de publication** *(2026-09-19 ; **les Vibes y passent depuis le 2026-09-21**)* | `neovibe/publish` + `/events` | `publish/` : `PublishService` (premier plan `dataSync`), `PublishPipeline`, `PublishStore`, `SessionStore`, `SupabaseHttp` (TUS par OkHttp), `PublishBridge`, `BootReceiver` | `BGProcessingTask` + `URLSession` en arrière-plan (`background` configuration, reprise par `Range`/TUS), même `job.json`, même pipeline — voir § 10 |
| Hôte / cycle de vie | — | `MainActivity : FlutterFragmentActivity` | `AppDelegate` / `FlutterViewController` |
| Journal caméra (dev) | (dans `neovibe/camera`) | `CamLog` (fichier disque) | fichier disque (trivial) |
| Diagnostic appareil (dev) | `neovibe/diag` | `NativeDiagnostics` (`PackageManager` + `Build`) | `Bundle.main.infoDictionary` + `UIDevice` |
| Identifiant du téléphone (plafond d'inscriptions, 2026-09-24) | `neovibe/device` (`androidId`) | `NativeDeviceIdentity` (`Settings.Secure.ANDROID_ID`, survit à la réinstallation) | `UIDevice.identifierForVendor` — ⚠️ plus faible : change quand toutes les apps de l'éditeur sont désinstallées ; envisager le trousseau (Keychain) ou App Attest. Voir `docs/inscription-et-appareil.md` |
| **Installation d'APK (dev)** | `neovibe/install` | `NativeInstall` + `FileProvider` + `MediaStore` | *sans objet — iOS n'installe que par l'App Store ou TestFlight* |
| **Finesse de position accordée** | `neovibe/location` | `LocationGrant` (`checkSelfPermission` sur `ACCESS_FINE_LOCATION`) | `CLLocationManager.accuracyAuthorization` (`.fullAccuracy` / `.reducedAccuracy`) |
| **Ce que le téléphone accorde en arrière-plan** *(2026-09-22)* | `neovibe/background_guard` | `BackgroundGuard` (`isIgnoringBatteryOptimizations`, fabricant, pages MIUI joignables ; ouvre la boîte `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, la page MIUI « Démarrage automatique », l'économiseur MIUI de l'app, la fiche de l'app) | *sans objet* — iOS ne tue pas les apps par surcouche constructeur ; le mode d'arrière-plan « bluetooth-central/peripheral » remplace tout ça |
| **Micro des messages vocaux** *(2026-09-13)* | `neovibe/voice` | `NativeVoiceRecorder` (`MediaRecorder`, AAC mono 24 kHz dans MPEG-4) | `AVAudioRecorder` (mêmes réglages, conteneur `.m4a`) |

### Natif **fourni par un paquet**, donc rien à écrire — mais à connaître

Ces blocs ne sont pas de notre code. Ils figurent ici parce que la règle de ce
fichier est de **ne rien découvrir au dernier moment lors du portage iOS**, et
qu'un moteur natif tiers pèse sur le portage autant qu'un fichier `.kt` à nous.

| Bloc | Paquet | Android | iOS |
|---|---|---|---|
| **Moteur de rendu Rive** | `rive` 0.14.11 → `rive_native` 0.1.11 | `.so` par ABI (~7,3 Mo en arm64) | fourni par le paquet — **rien à écrire** |
| **Carte Mapbox** *(2026-09-25)* | `mapbox_maps_flutter` 2.31.1 → SDK Android `com.mapbox.maps:android-ndk27` 11.31.1 | `libmapbox-maps.so` (18,7 Mo) + `libmapbox-common.so` (7,0 Mo) en arm64 : **l'APK passe de 36,9 à 67,0 Mo** ; aucune permission ajoutée (vérifié sur l'artefact : `ACCESS_WIFI_STATE` vient de `nearby_connections`, `VIBRATE` des notifications) | fourni par le paquet (SDK iOS Mapbox, iOS 14+) — **rien à écrire**, mais le jeton se pose aussi (`MapboxOptions.setAccessToken`, `main()`) |

| **Gestes de la carte** *(2026-09-26)* | `map/MapGestureTuner.kt` (canal `neovibe/map_gestures`, méthode `tune` → `{trouvees, reglees}`) + `res/values/mapbox_gestures.xml` | Règle les SEUILS du moteur de gestes de Mapbox pour la hiérarchie de Google Maps relevée par Jay. Ressources redéfinies (priorité de l'app à l'assemblage, vérifiée sur l'APK) : inclinaison après 25dp, zoom après 16dp, zoom pendant une rotation après 24dp. Écrits en dur, réglés par le code : angle de départ de rotation 10°, angle max des doigts pour incliner 60°, inclinaison ×2 (écouteur `OnShoveListener` qui ajoute la part manquante). La vue native est cherchée dans les vues de l'activité (introuvable en mode « écran virtuel »). Compilé contre `com.mapbox.maps:android-ndk27:11.31.1` en `compileOnly` (fourni par le paquet). iOS : `MapView.gestures.options` du SDK iOS (seuils à retrouver) |

⚠️ **Mapbox et AGP 9** : le paquet n'applique le plugin Kotlin que sous
AGP 8 et suppose au-delà le Kotlin intégré, que ce projet désactive
(`android.builtInKotlin=false`). `android/build.gradle.kts` le lui applique,
à lui seul (`plugins.withId("com.android.library")`). Sans ce bloc :
« Could not find method kotlin() » à la construction.

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

## 3. Proximité — BLE (preuve de proximité, et rien d'autre)

**Rôle** : **prouver qu'on est physiquement à côté de quelqu'un.** Le BLE crie
des jetons opaques et rapporte ceux qu'il entend. Il ne transporte plus rien.

⚠️ **Ce titre et ce rôle disaient encore « échange de contact + chat ping » et
« servir de tuyau d'octets » — corrigé le 2026-08-31.** Le transport GATT a été
supprimé le **2026-08-27** (décision de Jay : *« le BLE ne sert qu'à valider et
authentifier la proximité réelle »*), et le tableau des canaux juste en dessous
documentait déjà ces suppressions. **L'en-tête contredisait son propre tableau.**
Mini-profils, messagerie, demandes d'ami et certificats passent tous par le
serveur.

⚠️ **Entièrement reconstruit le 2026-08-16** (carte blanche de Jay). `NativeBle.kt`
et le canal `neovibe/ble` **n'existent plus**. Architecture complète :
`docs/architecture-proximite.md`.

**Deux canaux, et la séparation est volontaire** :

| Canal | Sens | Contenu |
|---|---|---|
| `neovibe/proximity` | Dart → natif | les **ordres** : `probe`, `start`, `stop`, `setAdvertPlan`, `setRecognitionTable`, `takeSightings`, `takePresences`, `publicHeartbeat`, `stats`, `advertCapacity`, `serviceJournal` *(2026-09-13)*, `openLocationSettings` — les douze ordres du `when` de `ProximityBridge.onMethodCall`, relevés le 2026-09-13. ⚠️ **`updateAdvert` supprimé le 2026-08-25** (second chemin vers l'émission, incapable de porter le TYPE du jeton) ; ⚠️ **`connect`, `disconnect` et `send` supprimés le 2026-08-27**, avec tout le transport GATT ; ⚠️ **`advertCapabilities` supprimé le 2026-08-28** — aucun appelant Dart depuis que `stats()` fusionne la map entière des capacités (2026-08-26). |
| `neovibe/proximity/events` | natif → Dart | les **constats** : `status`, `scan`. ⚠️ **`link` et `frame` supprimés le 2026-08-27.** Le Dart ne sait plus les décoder : `RadioEvent.fromMap` les rendrait `null`. ⚠️ **`scan` porte `atMillis` depuis le 2026-08-28** — voir ci-dessous. |
| `setAdvertPlan` | Dart → natif | *(2026-08-20)* dépose des heures de jetons d'avance — correction du point H |
| `setRecognitionTable` | Dart → natif | *(2026-08-20)* jetons attendus → rangs, pour reconnaître sans le Dart |
| `takeSightings` | Dart → natif | *(2026-08-20)* récupère et vide ce que le service a constaté seul |
| `publicHeartbeat` | Dart → natif | *(2026-08-29)* **le battement de cœur de la découverte** — voir ci-dessous |

### 🔴 L'HOMME MORT de l'identifiant public (2026-08-29)

**Fichiers : `ProximityService.kt`, `AdvertSchedule.kt`, `ProximityBridge.kt`.**

Le défaut corrigé : le plan porte **douze heures** de jetons d'avance, pour que
le service survive seul à la mort du Dart. C'est juste pour les jetons d'**ami** —
un ami reconnaît tout seul, sans réseau, app fermée. L'identifiant **public**,
lui, ne vaut rien sans la balise que le Dart republie au serveur toutes les
60 s et qui meurt 5 min après lui. L'appareil continuait donc de crier, **jusqu'à
la fin du plan**, un identifiant que plus personne ne pouvait traduire — mais
que n'importe quel scanner pouvait suivre.

⚠️ **Depuis le 2026-08-31, ce battement est le SEUL mécanisme qui borne
l'identifiant public.** Le Dart en avait un second — un « horizon public » de
cinq créneaux, posé le 2026-08-28 — supprimé parce qu'il rendait le nombre de
jetons variable d'un créneau à l'autre : le tampon à plat remis au natif se lit
par un pas constant, et le natif émettait donc les jetons **décalés** à partir
du sixième créneau, puis se taisait. Deux mécanismes pour un besoin, dont un
seul cassait le reste.

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
  🔴 **Une sonnerie avalée ne tue plus les suivantes (2026-09-14).** L'alarme
  est à coup unique et ne se reposait que dans sa propre sonnerie : le carnet
  de la nuit du 2026-09-14 montre l'alarme armée à 02:09 **jamais délivrée**
  (pas différée : perdue, y compris une heure durant où le processus tournait
  et les minuteurs Dart étaient à l'heure), et **26 frontières sans sonnerie**
  jusqu'à ce qu'un dépôt de plan la réarme par hasard à 08:30 — puis 7/7, avec
  41 s à 10,7 min de retard. `veille()` : à chaque passage du `cycleTick`, si
  l'échéance visée est dépassée **d'un créneau entier** (`estPerdue`, pure),
  l'alarme est reposée et la ligne `alarme perdue, reposee` va au carnet. En
  deçà, c'est un retard, et la reconnaissance l'absorbe. 3 tests de plus dans
  `SlotAlarmTest.kt` (en retard ≠ perdue, la frontière exacte, rien sans
  échéance).
  🍎 **iOS : aucun équivalent, et c'est un mur connu.** Il n'y a pas d'API de
  réveil périodique en arrière-plan ; `CoreBluetooth` fait tourner l'advertising
  mais l'app ne choisit pas quand réécrire sa charge utile. À traiter avec
  `AdvertSchedule` et `SightingBook`, qui butent sur la même limite.

- **`ServiceJournal.kt`** — *(nouveau, 2026-09-13)* **la vie du service radio,
  écrite sur le disque au fur et à mesure.** Le test de nuit du 2026-09-13 a
  montré que **tous** les compteurs de `stats()` (dont `slotAlarmReveils` et
  `advertSlotDriftMax`) vivent dans l'objet service — et meurent avec lui, et
  c'est la nuit qu'il meurt. Le rapport de 09:58 décrivait un service de
  30 secondes, sans rien dire du précédent. Ici chaque événement du cycle de
  vie est **ajouté à un fichier** (`proximity_service.log`) au moment où il se
  produit : `cree`, `demarre par l'app`, `relance par Android`, `reprise du
  disque : ok / rien`, `plan depose par l'app`, `alarme` (avec son retard),
  `radio : <état>`, `memoire basse`, `tache retiree par l'utilisateur`, `arret
  voulu`, `detruit`. Chaque ligne porte **deux horloges** : l'heure murale, et
  `up=` (`elapsedRealtime`) qui **redescend si le téléphone a redémarré** — la
  seule façon de distinguer « Android a tué l'app » de « le téléphone s'est
  éteint ». **Aucun identifiant, aucun jeton, aucune position** n'y entre.
  ⚠️ **Lu depuis le fichier, jamais depuis l'instance** (`ProximityBridge`
  `serviceJournal`) : c'est quand l'instance est morte qu'il a quelque chose à
  dire. ⚠️ **Fichier distinct de `PlanStore`** : le plan s'efface (il porte des
  jetons), le carnet ne s'efface jamais — il se borne à 24 Ko en gardant la
  fin. Points d'écriture dans `ProximityService` (`onCreate`, `onStartCommand`,
  `repartDuDisque`, `setAdvertSchedule`, `onStatus`, `onTrimMemory`,
  `onTaskRemoved`, `onDestroy`) et dans `SlotAlarm` (paramètre `onReveil`).
  Lecture côté Dart : `ServiceJournalReading` (pure, 8 tests) écrit la phrase
  « mort sans prévenir entre X et Y » au-dessus du carnet brut, section
  « SERVICE RADIO — SA VIE SUR LE DISQUE » du diagnostic. 3 tests JVM dans
  `ServiceJournalTest.kt` (forme des lignes, carnet absent, borne sur une
  frontière de ligne).
  🍎 **iOS : à écrire, même principe** — un fichier ajouté à chaque événement
  du cycle de vie de l'app (`applicationDidFinishLaunching`, arrière-plan,
  `applicationWillTerminate`, réveils `CoreBluetooth`), relu par le rapport.

- **`EnergyWatcher.kt`** — *(nouveau, 2026-09-14)* **l'énergie du téléphone,
  vue par le carnet.** Le carnet de la nuit du 2026-09-14 disait « Bluetooth
  éteint à 02:31, rallumé à 07:18 », « mémoire basse quatre fois en quatre
  secondes », « alarme jamais sonnée » — et Jay dormait ; il a dit après coup
  que sa batterie externe s'était arrêtée en cours de nuit. **Rien de ça
  n'était dans le carnet.** Deux pièces : `EnergyWatcher` écoute à l'exécution
  `ACTION_POWER_CONNECTED / DISCONNECTED`, `SCREEN_ON / OFF`, `BATTERY_LOW /
  OKAY`, `DEVICE_IDLE_MODE_CHANGED`, `POWER_SAVE_MODE_CHANGED` et, sur
  Android 13+, `LIGHT_DEVICE_IDLE_MODE_CHANGED`, et les remet à
  `ServiceJournal` en français (`chargeur debranche`, `ecran eteint`, `veille
  profonde : oui`…) ; `Energie.resume()` donne l'état du moment (`batt=57%
  chargeur=non eco=non veille=profonde ecran=eteint`, lu sur l'intent
  collant `ACTION_BATTERY_CHANGED` et `PowerManager`), joint aux lignes `cree`,
  `radio : …`, `alarme`, `alarme perdue, reposee` et `memoire basse`.
  **Sixième état depuis le 2026-09-22 : `exempt=oui/non`**
  (`PowerManager.isIgnoringBatteryOptimizations`, lu à chaque ligne car le
  réglage peut changer entre deux) — l'après-midi du 2026-09-21, le service
  est mort sur batterie sans relance ni réveil, et le carnet ne disait pas si
  l'app était exemptée à ce moment-là.
  ⚠️ **Un instrument, pas une règle** : il ne coupe rien et ne change aucune
  cadence. Le jour où une économie sera voulue, elle vivra ailleurs et lira
  ces mêmes signaux. La table action → libellé et la mise en forme sont
  **pures** — 2 tests dans `EnergyWatcherTest.kt` ; ces libellés sont ceux que
  `ServiceJournalReading` compte (ligne « énergie : … » du diagnostic) : les
  renommer d'un côté sans l'autre rend un compteur muet, sans erreur.
  🍎 **iOS : à écrire** — `UIDevice.batteryState / batteryLevel`,
  `ProcessInfo.isLowPowerModeEnabled`, notifications
  `UIApplication.didEnterBackground / willEnterForeground`. Pas d'équivalent
  du Doze exposé à l'app.

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

- **`AdvertCapacityProbe.kt`** — *(nouveau, 2026-09-01)* **combien de jeux
  d'annonces le contrôleur accepte réellement**. Il en demande un par un, avec
  les paramètres exacts de la production, et compte ceux que la pile démarre.
  🔴 **Il existe parce qu'aucune API Android ne donne ce nombre.**
  `BleEngine.MAX_PARALLEL_SETS = 6` était une borne *raisonnée* : au-delà, on
  retombe en mode cycle, où le jeton d'un ami n'est en l'air que 1/N du temps.
  La sonde remplace la supposition par un relevé (`RAPPELS.md` #113).
  ⚠️ **Elle refuse de tourner pendant que le service émet** — sinon elle
  mesurerait la capacité *restante*, un chiffre plus petit et indiscernable du
  vrai. Et **elle n'émet aucun jeton NeoVibe** : son en-tête n'est pas `NV`.
  ⚠️ **Bloquante, donc appelée hors du fil principal** (`ProximityBridge`) : les
  rappels d'annonce arrivent sur le fil principal, l'y attendre reviendrait à
  mesurer sa propre attente.
  ⚠️ **À porter sur iOS** — et la réponse y sera probablement « un seul jeu » :
  `CBPeripheralManager` n'expose pas d'annonces multiples. C'est exactement le
  genre d'écart qu'on veut connaître avant le portage, pas pendant.
  Méthode de canal : `advertCapacity`.

- **`AdvertCapacityStore.kt`** — *(nouveau, 2026-09-01 ; **absent de ce
  catalogue jusqu'au 2026-09-11**, oubli de la session interrompue)* **la
  mémoire du plafond d'annonces, par appareil**.
  🔴 **Pourquoi il existe** : `AdvertCapacityProbe` ci-dessous *mesure*, mais une
  mesure qu'on recopie à la main dans le code redevient une constante — la même
  erreur qu'avant, avec une meilleure source. Ce magasin retient ce que **cette
  puce-ci** a réellement accordé, et `BleEngine` le lit à l'exécution.
  ⚠️ **Signé par `Build.FINGERPRINT`** : une mise à jour d'Android change la
  pile Bluetooth, donc la mesure se périme avec elle.
  ⚠️ **Pas d'`effacer()`, délibérément** : rien ici n'appartient à un compte,
  c'est une propriété du **matériel**. Le vider au changement d'utilisateur
  ferait réapprendre pour rien ce que l'appareil sait déjà.
  ⚠️ **On n'écrit que vers le BAS, et jamais 0** : un refus passager ne doit pas
  condamner l'appareil au mode cycle pour toujours.
  ⚠️ **iOS (à faire)** : sans objet en l'état — `CBPeripheralManager` n'expose
  pas d'annonces multiples, il n'y a donc pas de plafond à apprendre. À
  reconsidérer seulement si iOS ouvre un jour cette capacité.
  Aucune méthode de canal : lu à travers `stats()` (`advertMaxSets`,
  `advertPlafondAppris`).

- **`AudioLink.kt`** — *(nouveau, 2026-09-10)* **y a-t-il un casque Bluetooth
  branché en ce moment ?** Rien d'autre.
  🔴 **Il existe parce que le BLE et l'audio Bluetooth partagent la même radio
  et la même antenne.** Signalé par Jay le 2026-09-10 : casque branché, puis
  ping allumé, et la musique se tait. Notre scan tournait en
  `SCAN_MODE_LOW_LATENCY` — **en continu, 100 % du temps** — et ne s'arrêtait
  jamais. `BleEngine` lit ce constat et passe en `SCAN_MODE_BALANCED`
  (~25 % du temps) tant qu'un casque est là.
  ⚠️ **Il CONSTATE, il ne décide de rien** (règle « dissocier l'acquisition de
  l'usage ») : il ne touche ni au scan, ni à l'émission. Il ne réveille son
  lecteur que si la réponse **change**.
  ⚠️ **`AudioManager`, et surtout pas `BluetoothProfile`** : la route Bluetooth
  exigerait la permission `BLUETOOTH_CONNECT`, que l'app n'a pas et qu'il
  faudrait demander à l'utilisateur pour une information de confort.
  `AudioManager` répond sans **aucune** permission, et voit en plus les casques
  BLE Audio (`TYPE_BLE_HEADSET`) que le profil A2DP ignore.
  ⚠️ **Ce qu'il ne sait pas** : si le casque **joue**. Un casque connecté et
  silencieux fait lever le pied pour rien — assumé, l'inverse demanderait de
  surveiller les sessions audio des autres applications.
  ⚠️ **iOS (à faire)** : `AVAudioSession.currentRoute.outputs`, en cherchant
  `.bluetoothA2DP`, `.bluetoothHFP` et `.bluetoothLE`, avec
  `AVAudioSession.routeChangeNotification` pour les changements. La question et
  la réponse se transposent directement. **Mais le remède, lui, ne se transpose
  pas** : `CBCentralManager` n'expose aucun équivalent de `setScanMode` — iOS
  décide seul de son rythme de scan. À relever au portage, pas maintenant.
  Aucune méthode de canal : lu à travers `stats()` (`casqueBluetooth`).

- **`ScreenState.kt`** — *(nouveau, 2026-09-22)* **l'écran est-il allumé, ou
  éteint depuis plus d'une minute ?** Seconde source de `BleEngine.modeDeScan`
  sur le modèle d'`AudioLink` : écran éteint depuis 60 s ⇒ `SCAN_MODE_BALANCED`
  (1 s d'écoute toutes les 4 s) ; écran rallumé ⇒ `LOW_LATENCY` tout de suite.
  Réétude du ping (Jay, RAPPELS #158) : l'écoute continue est **le** poste de
  dépense, et écran éteint personne ne regarde la liste — le besoin est « à
  côté pendant un moment », pas « vu à la première seconde ».
  🔴 **La minute de retard n'est pas du confort** : changer de rythme = arrêter
  et relancer le scan, et Android bannit au-delà de 5 démarrages par 30 s
  (`SCAN_FAILED_SCANNING_TOO_FREQUENTLY`, 35 s sans détection + bandeau). Le
  carnet du 2026-09-21 montre 6 allumages/extinctions en 36 s à 13:09.
  ⚠️ Lit `SCREEN_ON/OFF` à l'exécution (jamais au manifeste) et
  `PowerManager.isInteractive` à l'attache (un service relancé la nuit démarre
  écran éteint). `EnergyWatcher` écoute les mêmes signaux mais reste un
  instrument : deux lecteurs valent mieux qu'un instrument qui décide.
  Lu à travers `stats()` (`ecranAllume`) — `scanMode`, `casqueBluetooth` et
  `ecranAllume` se lisent **ensemble**.
  🍎 **iOS** : sans objet pour le remède (`CBCentralManager` ne règle pas son
  rythme) ; la question se lit par `UIApplication.applicationState`.

- **`ScanRecovery.kt`** — *(nouveau, 2026-09-23)* **quand reprendre l'écoute
  après un refus d'Android.** Décision pure (aucune radio, aucune horloge),
  testée par `ScanRecoveryTest`. Diagnostic de Jay du 2026-09-23 : à 10:53,
  une minute après l'extinction de l'écran, la relance du scan au rythme
  économe a été refusée (`SCAN_FAILED_APPLICATION_REGISTRATION_FAILED`), et
  **aucune reprise n'existait pour ce code** — téléphone sourd plus d'une heure,
  toujours visible des autres. Désormais `REGISTRATION_FAILED`, `INTERNAL_ERROR`
  et `OUT_OF_HARDWARE_RESOURCES` se réessaient à 5 s, 30 s, 2 min puis toutes les
  5 min tant que le ping est voulu (`BleEngine.repriseScan`). Instruments dans
  `stats()` : `ecouteVoulue`, `scanRefus`, `scanPanneDepuisMillis` ; le carnet
  écrit `running (ecoute coupee)` quand le service tourne sans écouter.
  🍎 **iOS** : `CBCentralManager` ne renvoie pas ces codes ; l'équivalent est de
  relancer `scanForPeripherals` sur `centralManagerDidUpdateState(.poweredOn)`.

- **`LocationBeat.kt`** — *(nouveau, 2026-09-22)* **mesurer où l'on est et
  republier la balise `ping_beacons`, sans le Dart.** Sa position vient de
  `location/PositionEngine.kt` depuis le 2026-09-25 (fenêtre : pas de 1 s,
  âge max 10 s). Jusque-là, la balise
  était publiée par le Dart toutes les 60 s, app ouverte seulement — or le
  jeton public ne vaut rien sans elle : **fermer l'app rendait invisible aux
  inconnus au bout de 5 min, en silence** (`graceBattement`). Le croisement
  d'amis, lui, n'a jamais eu besoin de rien (BLE pur, plan de 12 h).
  🔴 **Un seul écrivain à la fois** (règle 4) : le Dart publie tant qu'il
  vit ; ce battement prend le relais après 90 s de silence (`relaisApres`,
  deux battements manqués) et le rend dès que le Dart redépose un plan. La
  règle de passage de main est écrite dans `ProximityService.revoirLeBattement`
  et nulle part ailleurs.
  ⚠️ **Il ne tourne que si l'utilisateur l'a demandé** — le troisième
  interrupteur, `publicEnArrierePlan`, descend avec le plan (jamais relu du
  disque : le plan persisté est `friendsOnly`, donc un service repris après la
  mort du processus n'a aucun jeton public à crier).
  ⚠️ **Pas de second service** : `ProximityService` est déjà un service de
  premier plan de type `location` avec sa notification. C'est ce statut qui
  rend une position par minute tenable écran éteint (Doze ne s'applique pas),
  là où une alarme est plafonnée à ~9 min et `WorkManager` à 15 min.
  🔴 **PAR RAFALES depuis le 2026-09-22 au soir** (décision de Jay, à sa
  question *« app fermée on continue de demander la position en continu ? »* —
  la réponse était oui, et c'était trop). L'abonnement au moteur restait ouvert
  en permanence, à la précision maximale, pour publier une balise par minute :
  **quatre mesures pour en utiliser une**, GPS jamais froid. Désormais :
  `CADENCE_MS` **60 s** entre deux mesures, `FENETRE_MS` **10 s** d'écoute par
  mesure (pas interne `PAS_FENETRE_MS` 1 s), puis on **referme** et on publie —
  la publication est à la FERMETURE, sinon les dix secondes ne serviraient à
  rien. `RAPIDE_MS`/`LENT_MS` sont **fusionnées** : ce battement ne tourne que
  quand le Dart s'est tu depuis 90 s, donc app hors premier plan, et l'état de
  l'écran n'y change rien (`ScreenState` sert toujours au BLE).
  ⚠️ Garde de `start()` : elle lit `arme` (le battement est-il armé ?) et non
  `listening` (la fenêtre est-elle ouverte ?) — équivalents tant que l'écoute
  était permanente, opposés depuis la rafale, où `listening` est faux 50 s sur
  60. Avec l'ancienne garde, le battement se reposait à chaque appel et
  **n'aurait jamais publié**.
  Position périmée au-delà de `PERIMEE_MS` 5 min.
  Réutilise `SessionStore` + `SupabaseHttp` (`publish/`), éprouvés par
  `EventPresenceService`. Instruments dans `stats()` : `publicEnArrierePlan`,
  `beaconPublications`, `beaconEchecs`, `beaconDernierEchec`, `beaconMoteur`,
  `beaconAgeMillis`.
  🔴 **QUEL MOTEUR MESURE — changé le 2026-09-22 (soir).** Il écoutait le
  `LocationManager` d'Android, qui ne croise **rien** : GPS brut, ou antenne
  brute. Il passe désormais par le **moteur fusionné de Google**
  (`FusedLocationProviderClient`, `play-services-location:21.2.0`, version
  alignée sur celle que `geolocator_android` apporte déjà) — GPS + Wi-Fi +
  antennes + capteurs, celui qui sert Google Maps. Constat qui l'a déclenché :
  dans le métro, NeoVibe plaçait Jay à deux rues de l'endroit réel, Google Maps
  juste, au même instant sur le même téléphone.
  `demarreGoogle()` d'abord, **repli** sur `demarreAndroid()` si les services
  Google Play manquent (Huawei, ROM dégooglisée) ; `stopListening()` coupe
  **les deux**. `setWaitForAccurateLocation(false)` volontairement : on veut le
  point rapide **et** les meilleurs ensuite, c'est `listener` qui garde le
  meilleur. L'instrument `beaconMoteur` (`google` / `android` / `aucun`) dit
  lequel a tourné — les deux rendent le même objet avec les mêmes champs, donc
  sans lui une position fusionnée et une estimation d'antenne sont
  indiscernables dans un rapport.
  🔴 **Défaut corrigé le même jour** : `start()` changeait la cadence du
  battement sans reposer l'abonnement, qui gardait l'ancien intervalle — écran
  éteint, on annonçait « une position par minute » en continuant d'en demander
  une toutes les 15 s. La cadence est maintenant reposée
  (`changeDeCadence` → `stopListening()` puis `startListening()`).
  🍎 **iOS (à faire)** : `CLLocationManager` avec `allowsBackgroundLocationUpdates`
  et le mode d'arrière-plan « location », même RPC. ⚠️ Pas de question de
  moteur sur iOS : CoreLocation **est** le moteur fusionné d'Apple, il n'y a
  pas d'équivalent du `LocationManager` brut à éviter.

- **`AdvertSchedule.publicTokenAt`** *(2026-09-22)* — le jeton public du
  créneau courant et son numéro, **lus au plan, jamais recalculés** :
  recalculer serait réécrire en Kotlin une règle qui vit en Dart.

- **`ADVERT_INTERVAL`** *(`BleEngine.kt`, 2026-09-22)* — l'intervalle d'un jeu
  d'annonces en mode parallèle : **`INTERVAL_MEDIUM` = 250 ms** (était
  `INTERVAL_LOW` = 100 ms). Règle : l'intervalle d'émission reste **sous** la
  fenêtre d'écoute d'en face (1 s en `BALANCED`) avec plusieurs annonces par
  fenêtre pour absorber les paquets perdus. ⚠️ Le mode cycle (repli) garde
  100 ms : il tourne les jetons toutes les 400 ms, un intervalle plus long
  sauterait des jetons sans rien signaler.

- **`offloadedFiltering` / `offloadedScanBatching`** *(`advertCapabilities()`,
  2026-09-22)* — la puce sait-elle trier et grouper elle-même ? Instrument
  seulement : le filtre est vide depuis le 2026-08-16. RAPPELS #159 (v6).

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
| `slotAlarmReveils` / `slotAlarmRetardMaxMillis` | **`SlotAlarm`** | le réveil de veille a-t-il sonné, et avec quel retard. Sans eux, une dérive nulle ne distingue pas « c'est réparé » de « l'alarme n'a jamais été honorée ». ⚠️ **Meurent avec le processus** (constaté le 2026-09-13 : `0` après une nuit, parce que le service avait 30 s) — la trace qui survit est le carnet `ServiceJournal`, qui porte aussi depuis le 2026-09-14 les sonneries **perdues** puis reposées |

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

## 4 bis. Média hors caméra — couverture, sonde, JPEG, transcodage

**Rôle** : ce que l'app fait aux fichiers média **hors** caméra. À l'origine
(2026-07-25) une seule chose : produire une **image de couverture** (JPEG)
d'une vidéo locale, pour les vignettes — une vidéo ne se décode pas comme une
image côté Dart (« Invalid image data »). Depuis le **2026-09-15** (l'éditeur
d'album, `docs/plan-publications.md`), quatre de plus.

**Canal** : `neovibe/media`. Méthodes :

| Méthode | Rôle | Erreurs |
|---|---|---|
| `videoThumbnail(source, dest, width, atMs)` | une image JPEG de la vidéo — la première image-clé (`atMs` = 0, `OPTION_CLOSEST_SYNC`) ou l'image la plus proche d'un instant (`OPTION_CLOSEST`) | `BAD_ARGS`, `THUMB_FAILED` (jamais bloquant) |
| `fastStart(path)` | l'index MP4 en tête (`Mp4FastStart.kt`, bloc 7) | — |
| `probe(path)` | photo ou vidéo, dimensions **après rotation** (EXIF pour une photo, `KEY_ROTATION` pour une vidéo), durée | `PROBE_FAILED` |
| `encodeJpeg(rgba, width, height, dest, quality)` | des pixels RGBA rendus par Flutter → un JPEG (`dart:ui` ne sait écrire que du PNG) | `JPEG_FAILED` |
| `transcode(jobId, source, dest, startMs, endMs, corners[8], outWidth, outHeight, uniforms[24], rotation, overlayPath?)` | **`MediaTranscoder.kt`** : une vidéo de la galerie rognée, cadrée / tournée / redressée (les coins de `CropGeometry`), corrigée (le contrat `ColorGrade.toUniforms`), avec le calque des textes et autocollants (un PNG) brûlé dessus, recompressée ; progression par `transcodeProgress(jobId, progress)` du natif vers Dart, au plus une fois par pour cent | `TRANSCODE_FAILED` |
| `readAll(sealed, key)` *(2026-09-19)* | le **clair** d'un média scellé rendu en mémoire (les photos, les vignettes du profil) par `SealedChunkReader` — le déchiffrement Dart figeait l'écran ~85 ms par vignette | `BAD_ARGS`, `READ_FAILED` |
| `sealedPoster(sealed | url+cachePath, key, dest, width)` *(2026-09-20)* | **une image d'une vidéo scellée**, rescellée avec la même clé dans `dest` : le lecteur de blocs (`SealedChunkReader`, local ou `RemoteChunkStore` en flux) sert de `MediaDataSource` au `MediaMetadataRetriever` ; la JPEG est scellée **en mémoire** (`SealedChunkWriter.sealBytes`) — les vignettes des Vibes vidéo, sans clair sur le disque | `BAD_ARGS`, `POSTER_FAILED` |
| `seal(source, key, dest)` *(2026-09-19)* | **scelle** `source` au format `NVC1` dans `dest` (`SealedChunkWriter.kt`, le miroir du lecteur ; 4 tests JVM de va-et-vient) — le scellage Dart tournait sur le fil de l'interface, ~9 s d'écran figé par vidéo de 25 Mo | `BAD_ARGS`, `SEAL_FAILED` |
| `unseal(sealed, key, dest)` *(2026-09-18)* | le **clair** d'un média scellé `NVC1` écrit dans `dest`, bloc par bloc par `SealedChunkReader` (AES matériel, fil de travail) — ce que « Enregistrer » copie dans les Enregistrements. Le déchiffrement Dart plafonnait à ~2,7 Mo/s sur le fil de l'interface : un Flow de 36 Mo figeait l'écran treize secondes. `dest` est effacé sur échec | `BAD_ARGS`, `UNSEAL_FAILED` |

**Android (fait)** : `NativeMedia.kt`, tout sur un exécuteur dédié (jamais le
thread principal), écriture `.part` puis renommage. **`MediaTranscoder.kt`**
(2026-09-15) : `MediaExtractor` → décodeur `MediaCodec` sur une
`SurfaceTexture` OES (`KEY_ROTATION` forcé à 0 : c'est notre shader qui
redresse, avec la rotation lue par la sonde) → shader GL ES 2 — **la même
formule que `shaders/album_grade.frag`** côté Flutter : coins de cadrage en
coordonnées de texture, matrice 4×4 + offsets, ombres et hautes lumières
pondérées par la luminance, netteté par masque flou, vignette, puis le calque
PNG (alpha prémultiplié) mélangé par-dessus → encodeur H.264 sur sa `Surface`
(3,5 Mbit/s, `NativeCamera.VIDEO_BITRATE`) → `MediaMuxer` ; audio **AAC
recopié**, rogné et entrelacé ; sans AAC, la vidéo sort sans son et le résultat
le dit. Attentes bornées (image jamais rendue : 3 s ; fin de flux : 4 s), même
famille de code que `Camera2Gl` et volontairement séparé du chemin caméra.
⚠️ Le sens du redressement dans `cropTexCoords` et le retournement vertical de
la `SurfaceTexture` sont à **vérifier sur appareil** (comme le miroir de la
frontale, `RAPPELS.md` #9).

**`NativeGallery.kt`** (nouveau, 2026-09-15, canal `neovibe/gallery`) : la
galerie **dans l'app** (« Nouvelle publication »).

**Étendu le 2026-09-17** (Jay : *« une interface plus complète et pro comme sur
Instagram, qui permet d'afficher les albums et filtrer »*) : `albums()` rend
les dossiers du téléphone avec leur nom, leur compte et la couverture la plus
récente, et `list()` prend un `bucketId` et un `mediaType`. ⚠️ **Pas de
`GROUP BY`** : le `MediaProvider` le refuse comme il refuse `LIMIT` — on
parcourt le curseur trié par date **une fois** et on agrège en Kotlin (trois
colonnes : c'est une lecture d'index). **iOS** : `PHAssetCollection` +
`PHFetchOptions.predicate` sur `mediaType` ; l'agrégation y est native, la
question du `GROUP BY` ne s'y pose pas.

`list(offset, limit, bucketId, mediaType)` =
`MediaStore.Files` (images + vidéos) triés par date, **paginés par `Bundle`**
(`QUERY_ARG_LIMIT` / `OFFSET` — `LIMIT` dans l'ordre de tri est refusé depuis
Android 11) ; `thumbnail(uri, size)` = `ContentResolver.loadThumbnail` (API 29,
déjà orientée, mise en cache par le système), JPEG 82 ; `copy(uri, dest)` =
`openInputStream` → notre cache. Trois fils pour les vignettes, un pour le
reste. Permissions au manifeste : `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`,
`READ_MEDIA_VISUAL_USER_SELECTED` (14+, accès partiel), `READ_EXTERNAL_STORAGE`
(≤ 32) ; demandées côté Dart par `permission_handler` (`photos`, `videos`).
Lecture seule. **iOS** : `PHPhotoLibrary.requestAuthorization(.readWrite ou
.addOnly)`, `PHAsset.fetchAssets` paginé, `PHImageManager.requestImage` pour
les vignettes, `requestExportSession` / `requestImageDataAndOrientation` pour la
copie.

**iOS (à faire)** : `AVAssetImageGenerator` sur un `AVURLAsset`
(`appliesPreferredTrackTransform = true` pour respecter la rotation, comme le
fait `MediaMetadataRetriever` sur Android), `copyCGImage(at:)`, puis
`UIImage.jpegData(compressionQuality: 0.85)`. Même contrat de canal. Pour la
sonde : `AVAsset` (`naturalSize` × `preferredTransform`) et `CGImageSource`
(propriétés EXIF). Pour le JPEG : `CGImage` depuis les octets RGBA +
`UIImage.jpegData`. Pour le transcodage : `AVAssetExportSession` avec une
`AVMutableVideoComposition` (rognage `timeRange`, recadrage et rotation par
`AVMutableVideoCompositionLayerInstruction`) et un `CIFilter` (`CIColorMatrix`
+ `CIVignette`) alimenté par la même matrice — même contrat de canal, même
définition des réglages.

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

## 6 quater. Micro des messages vocaux

**Canal** : `neovibe/voice`. Méthodes : `start {path}`, `stop` →
`{path, durationMs}`, `cancel`, `amplitude` → entier 0..32767.

**Android (fait, 2026-09-13)** : `NativeVoiceRecorder.kt` — `MediaRecorder`,
source `MIC`, AAC mono 24 kHz 32 kbit/s dans un conteneur MPEG-4 (`.m4a`).
Un seul enregistrement à la fois (`BUSY` sinon). `stop` sur un enregistrement
trop court rend `TOO_SHORT` et supprime le fichier — jamais un fichier vide
présenté comme un succès. `dispose` (mort de l'activité) supprime un
enregistrement en cours.

**Pourquoi le même conteneur que la vidéo** : une fois scellé au format
`NVC1`, le vocal est lu par **le même lecteur natif** (§7, mode `audio`). Aucun
décodeur, aucun format, aucun chemin de clé à ajouter — seule la clé change de
porte (`open_voice_message` au lieu de `open_card_media`).

**Ce que ce fichier ne fait pas** : il ne scelle pas, n'envoie pas, ne décide
pas à qui. Le Dart (`ConversationsRepository.sendVoice`) scelle, dépose dans le
bucket `media`, pose le message et sa clé en une transaction
(`send_voice_message`), puis **supprime le clair**. Le clair ne vit que le temps
de l'envoi, comme la capture vidéo.

**Permission** : `RECORD_AUDIO`, déjà au manifeste pour la caméra ; demandée
par l'écran (`permission_handler`) avant `start`.

**iOS (à faire)** : `AVAudioRecorder` avec `AVFormatIDKey = kAudioFormatMPEG4AAC`,
mono, 24 kHz, 32 kbit/s, fichier `.m4a` ; `averagePower(forChannel:)` pour
l'amplitude (après `isMeteringEnabled = true`). Permission `NSMicrophoneUsageDescription`.

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

## 6 quinquies. Ce que le téléphone accorde en arrière-plan *(2026-09-22)*

**Canal** : `neovibe/background_guard`. Méthodes : `state` →
`{manufacturer, brand, model, batteryExempt, autostartPage, batterySaverPage}` ;
`requestBatteryExemption`, `openAutostart`, `openBatterySaver`,
`openAppDetails` → booléen (la page s'est ouverte, ou non).

**Android (fait, 2026-09-22)** : `BackgroundGuard.kt`. Pourquoi : l'après-midi
du 2026-09-21, le service radio est mort à ~13:45 sur batterie, après quatre
« mémoire basse », **sans relance `START_STICKY` ni livraison de l'alarme**
posée — la signature d'un « forcer l'arrêt » de MIUI, confirmée par les
captures de Jay (économiseur « recommandé », démarrage automatique désactivé).

| réglage | lisible ? | comment |
|---|---|---|
| exemption d'optimisation batterie | **oui** | `PowerManager.isIgnoringBatteryOptimizations` |
| économiseur MIUI « Pas de restriction » | non, mais c'est le même interrupteur sur MIUI récent | on lit l'exemption |
| démarrage automatique MIUI | **non** (aucune API publique) | on ouvre la page et on le dit |

MIUI n'est **pas** deviné à la marque : on regarde si ses pages existent
(`resolveActivity`), d'où les `<queries>` du manifeste pour
`com.miui.securitycenter` et `com.miui.powerkeeper` — sans elles, Android 11+
répond « n'existe pas » même sur un Xiaomi, et le bouton serait mort sans
erreur. Les pages : `com.miui.permcenter.autostart.AutoStartManagementActivity`
et `com.miui.powerkeeper.ui.HiddenAppsConfigActivity` (extras `package_name`,
`package_label`). Lancées depuis le contexte d'application avec `NEW_TASK`.

**Permission** : `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` au manifeste. ⚠️
Google Play exige une justification : la fonction principale (reconnaître ses
amis à côté de soi, écran éteint) en dépend — à écrire dans la Play Console.

**Côté Dart** : `lib/features/proximity/background_guard.dart` (acquisition,
`backgroundGuardProvider`), `background_guard_screen.dart` (l'écran « Écran
éteint » à trois étapes + le bandeau de l'écran Ping, qui n'apparaît que si
quelque chose de **lisible** manque), entrée Réglages › « Écran éteint »,
section « ARRIÈRE-PLAN — CE QUE LE TÉLÉPHONE ACCORDE » du diagnostic.

**iOS (sans objet)** : pas de surcouche qui tue ; le mode d'arrière-plan
Bluetooth se déclare dans `Info.plist`.

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
| `SealedChunkStore.kt` | d'où viennent les octets scellés : fichier local, ou **intervalles HTTP + cache partiel** (`RemoteChunkStore`, `HttpRangeFetcher`). **Lecture d'avance** *(2026-09-19)* : un bloc servi déclenche, sur un fil à part (`prefetchPool`, deux au plus), UNE requête pour les `READ_AHEAD = 4` blocs suivants (1 Mo) ; un saut ne coûte toujours que le bloc réclamé (`ReadAheadTest`) |
| `Mp4FastStart.kt` | déplace l'index MP4 (`moov`) en tête, pour décoder dès les premiers octets reçus |
| `NativePlayer.kt` | l'ExoPlayer lui-même, rendu dans un `TextureRegistry.SurfaceProducer` ; canal `neovibe/player` + `neovibe/player/events/<id>`. **Mode `audio`** *(2026-09-13)* : `create` accepte `audio: true` pour un média sans image (message vocal) — la surface est créée (c'est elle qui donne l'identifiant) mais pas donnée à ExoPlayer, et « prêt » n'attend plus une taille de vidéo qui ne viendrait jamais. Côté Dart : `SealedVideoController.audioStreaming` |

**Commandes ajoutées le 2026-09-19** (canal `neovibe/player`) : `suspend`
(rend le décodeur matériel — `exoPlayer.stop()` — en gardant la liste, la
position et la dernière image sur la surface), `resume(play)` (re-prépare,
~200 ms), `stats` → `{dropped, rendered, skipped, positionMs}` ; et
l'événement `dropped {total}` (compteur cumulé d'`onDroppedVideoFrames`).
Côté Dart : `SealedVideoController.suspend/resume`, `droppedFrames`. Une
cellule du fil hors de vue rend son décodeur ; le journal note les images
perdues à la fermeture d'un lecteur.

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

---

## 9. Les tests JVM du natif Android — l'inventaire

*Relevé le 2026-09-13 en fin de session : l'inventaire « fichiers `.kt` réels
↔ fichiers cités ici » laissait quatre tests sans mention. Ils sont listés pour
que le contrôle de fin de session compte juste.*

`android/app/src/test/kotlin/com/neovibe/neovibe/` — treize tests, exécutés sur
la JVM par `./gradlew test`, sans appareil :

| Fichier | Ce qu'il tient |
|---|---|
| `AdvertOnAirTest.kt`, `AdvertScheduleTest.kt` | le plan d'émission BLE et ses créneaux |
| `PlanPersistenceTest.kt`, `PlanStoreTest.kt` | le plan survit à la mort du processus |
| `ServiceJournalTest.kt` | *(2026-09-13)* le carnet de vie du service survit à sa mort, et se borne sans couper une ligne |
| `EnergyWatcherTest.kt` | *(2026-09-14)* les libellés d'énergie du carnet et la ligne d'état, stables parce que la lecture Dart les compte |
| `PresenceLogTest.kt`, `SightingBookTest.kt`, `SlotAlarmTest.kt` | présences, constats, réveil par créneau |
| `RecognitionVectorsTest.kt` | les vecteurs de reconnaissance partagés avec le Dart |
| `SealedChunkReaderTest.kt`, `Mp4FastStartTest.kt`, `PartialStreamingTest.kt`, `ReadAheadTest.kt` *(2026-09-19)* | le lecteur de médias scellés (§7), et la lecture d'avance |
| `SealedChunkWriterTest.kt` *(2026-09-19)* | le scelleur natif produit ce que le lecteur natif (et le Dart) lit : 0 octet, bloc partiel, bloc exact, plusieurs blocs |
| `publish/PublishPipelineTest.kt` *(2026-09-19, Vibe le 2026-09-21)* | la file de publication sans codec ni réseau : préparé et déposé avant « Publier », inscrit après (avec `p_card_type`) ; **une Vibe vidéo, face finale : pas de transcodage, index en tête avant le scellage, durée et couverture nulles** ; vidéo transcodée une fois (index en tête sur elle seule) ; **reprise à l'offset du serveur** après une coupure ; attente croissante ; jeton refusé → attente de l'app ; refus du serveur → échec avec message ; annulation → coffre et dossier effacés ; `job.json` se relit tel quel |

**iOS** : à réécrire en XCTest sur les mêmes vecteurs, au moment du portage.

## 10. La file de publication — `publish/` *(2026-09-19 ; Vibes depuis le 2026-09-21)*

**Rôle** : finir une publication **avec ou sans l'app** — tranché par Jay le
2026-09-19 (*« la publication est une file NATIVE et persistante »*, `CLAUDE.md`).
Écrite pour les albums ; **depuis le 2026-09-21 c'est la Vibe qui y passe**
(Jay : *« on fait la file native maintenant pour les vibes »*), les albums et
les Flows étant sortis du MVP le même jour. Le Dart copie les faces — déjà
finales, rendues par l'éditeur ou captées — dans le dossier de la
publication, écrit la couverture, tire la clé ; puis il **dépose** et
**libère** aussitôt (`LibraryRepository.publish` → `PublishBridge`). Tout le
reste est ici.

**Ce que le `job.json` d'une Vibe porte** : `cardType` (standard / oneshot /
bereal, passé en `p_card_type`), un ou deux `media` sans `source` ni
`transcode` (« déjà finale »), sans `poster`, `width`/`height` nuls. Plus de
`kind` ni de `aspectW`/`aspectH` : le service inscrit `p_kind = 'card'`,
ratio nul. Le pipeline sait toujours transcoder une vidéo qui arrive avec
`source` + `transcode` (testé sur la JVM) — c'est la voie prévue pour les
vidéos importées dans une Vibe, à venir.

**Canal** : `neovibe/publish` (méthodes) + `neovibe/publish/events` (flux).

| Méthode | Rôle |
|---|---|
| `configure(url, anonKey, accessToken)` | la session, à chaque connexion et renouvellement (`SessionStore`, `publish_session.json`). ⚠️ Le service ne renouvelle **jamais** le jeton lui-même — le jeton de renouvellement est à usage unique, l'employer d'ici déconnecterait l'app |
| `signOut()` | efface la session |
| `jobDir(id)` | le dossier de travail `<filesDir>/publish/<id>/` — **pas sous `work/`**, balayé au démarrage de l'app |
| `enqueue(job)` | dépose le JSON de `PublishJob` et réveille le service |
| `release(id, caption, isPublic, shareable, saveable, anchorLat?, anchorLng?)` | « Publier » → `release.json` ; **l'ancre** (2026-09-20, Pulse) n'est là que si l'auteur a choisi « Localiser » — déjà gommée à 100 m par le Dart, passée telle quelle à `publish_to_library` |
| `cancel(id)` | retour en arrière → marqueur `cancel`, le service efface (coffre et dossier) |
| `retry(id)` | après un échec : repart de ce qui est fait (scellé, déposé) |
| `ack(id)` | l'app a vu la publication dans sa liste : le dossier s'efface |
| `pending()` | l'état de tout ce qui est rangé |

Événements : `{jobs: [instantané…]}` à chaque changement (`PublishHub`), et
`{needToken: true}` quand le serveur refuse le jeton — le Dart (`main.dart`)
rafraîchit sa session et rappelle `configure`.

| Fichier | Rôle |
|---|---|
| `PublishJob.kt` | le contrat sur le disque : phases `preparing → uploading → waiting → registering → done` (ou `failed`, `cancelled`), les fichiers et où chacun en est. **Deux écrivains, deux fichiers** : `job.json` n'est écrit que par le service ; `release.json` et `cancel` que par l'app |
| `PublishStore.kt` | un dossier par publication, écriture `.tmp` + renommage ; les lectures ne créent rien |
| `SessionStore.kt` | url, clé publique, jeton — un autre fichier, une autre durée de vie |
| `SupabaseHttp.kt` | **TUS** (sondé sur le projet de dev le 2026-09-19) : `POST /storage/v1/upload/resumable` → `Location` ; `HEAD` → `Upload-Offset` ; `PATCH` par blocs de **6 Mo exactement** ; et l'inscription `POST /rest/v1/rpc/publish_to_library`. Range les réponses en `AuthExpired` (401, ou 400/403 « JWS » du coffre), `Rejected` (4xx : ne se réessaie pas seul), `IOException` (réseau : attente croissante 5 s → 5 min). **OkHttp** : `HttpURLConnection` ne sait pas émettre `PATCH`, et Supabase ignore `X-HTTP-Method-Override` (sondé) |
| `PublishPipeline.kt` | le travail, pas à pas, **reprenable à chaque pas** : transcode s'il le faut (`MediaTranscoder`, avec annulation entre deux images), couvre (`NativeMedia.extract`), **remet l'index MP4 en tête** (`Mp4FastStart`, 2026-09-21 — la caméra et le transcodeur l'écrivent à la fin ; avant, une vidéo transcodée par la file partait sans), scelle (`SealedChunkWriter`), envoie (deux fichiers à la fois, reprise à l'offset du serveur), attend « Publier », inscrit, copie les scellés dans le cache de mes contenus (`ownCache`), efface. Testé sur la JVM |
| `PublishService.kt` | **Purge** *(2026-09-20)* : une publication déposée mais jamais libérée depuis `UNRELEASED_TTL_MS` (24 h) est annulée — coffre et dossier effacés (Jay : « on purge si c'est pas confirmé publié »). Service de premier plan **`dataSync`** (`FOREGROUND_SERVICE_DATA_SYNC`) : une boucle qui fait avancer chaque publication et attend (jeton, « Publier », délai) ; réveillé par l'app (`kick`), le retour du réseau (`registerDefaultNetworkCallback`), Android (`START_STICKY`) ou le boot ; notification « Envoi… 43 % » ; s'arrête seul quand il n'y a plus rien ; une notification à part sur un échec |
| `PublishBridge.kt` | le pont, jetable (naît et meurt avec l'activité) |
| `PublishHub.kt` | l'`object` par lequel le service publie ce qu'il constate, que le pont soit là ou non |
| `BootReceiver.kt` | `BOOT_COMPLETED` (`RECEIVE_BOOT_COMPLETED`) : relance le service **s'il reste une publication en cours** — et rien d'autre, jamais la proximité |

Dépendances ajoutées : `com.google.code.gson:gson:2.11.0` (main, elle n'était
qu'en test), `com.squareup.okhttp3:okhttp:4.12.0`.

Et, pour la position (2026-09-22) :
`com.google.android.gms:play-services-location:21.2.0` — le moteur fusionné de
Google, pour `LocationBeat.kt`. ⚠️ **Version alignée sur celle que
`geolocator_android` apporte déjà** (relevée dans son `build.gradle:44`) : même
règle que media3, deux versions dans un même APK ne se concilient pas et la
plus haute gagnerait en silence. **Sans équivalent iOS à ajouter** : CoreLocation
est déjà le moteur fusionné d'Apple, et il est dans le système.

⚠️ **R8 et la réflexion** (v0.9.221, après le test de Jay) : Gson lit ces
classes **par leur nom** ; en release R8 les renommait (`x7.g`) et le dépôt
échouait avec « Abstract classes can't be instantiated ». Le paquet `publish`
est gardé par `android/app/proguard-rules.pro`. Toute classe future lue par
réflexion s'y ajoute, et se **vérifie dans `mapping.txt`** de l'APK.

**iOS (à faire)** : le même `job.json`, le même pipeline (`AVAssetExportSession`
pour le transcodage, `CryptoKit` pour le scellage) ; l'envoi par `URLSession`
en configuration `background` (il continue app tuée, le système rappelle
l'app à la fin), TUS identique ; la reprise après relance par
`BGProcessingTask`. Pas de service de premier plan sur iOS : c'est la session
d'arrière-plan qui porte « survit à la fermeture ».

---

## 11. La présence à un événement, app fermée — `events/` *(2026-09-21)*

**Rôle** : le prérequis §0 du programme du 2026-09-21 (« la position en
arrière-plan »). Tant que je suis dans un événement, relever ma position une
fois par minute et la déposer (`report_event_position`) — écran éteint, app
fermée. Le serveur répond `present` / `away` / `none` ; sur `away` ou
`none` le service s'arrête.

**Pourquoi sans `ACCESS_BACKGROUND_LOCATION`** : un service de premier plan
de type `location` fait compter l'app « au premier plan » pour la
localisation (le raisonnement de `ProximityService`, 2026-08-25) ; il suffit
de le **démarrer depuis l'interface** — ce qui est toujours le cas : on
rejoint un événement dans l'app. Android 14 exige que `ACCESS_FINE_LOCATION`
soit accordée au démarrage : elle l'est dès que le ping fonctionne.

**Un seul écrivain** : depuis ce jour, le Dart ne dépose plus de position
d'événement, même au premier plan (`event_presence_reporter.dart` démarre,
arrête, écoute). La session (url, clé publique, jeton) est celle du pont de
publication (`SessionStore`) ; le natif ne renouvelle pas le jeton — sur
refus, il s'arrête, le BLE tient la présence (`report_sightings`), et l'app
relance à son retour.

| Fichier | Rôle |
|---|---|
| `location/PositionEngine.kt` | *(2026-09-25)* **le moteur de position, en un seul exemplaire**, partagé par `LocationBeat` (proximité) et `EventPresenceService` (soirée) : Google fusionné d'abord, `LocationManager` en repli, garde le meilleur point (le plus précis s'il est récent), publie `moteur` (`google` / `android` / `aucun`). Chaque service lui passe ses propres intervalles. Il était écrit deux fois, et la correction du 2026-09-22 n'avait atteint qu'une copie. iOS : un `CLLocationManager` partagé de la même façon |
| `location/HeadingSensor.kt` | *(2026-09-25)* **la boussole de la carte** — canal `neovibe/heading/events` (pas de méthode). Capteur `TYPE_ROTATION_VECTOR` (boussole + accéléromètre + gyroscope fusionnés par Android), `SENSOR_DELAY_UI`, écouté SEULEMENT tant que le Dart écoute (`onListen`/`onCancel` ; la carte coupe à la mise en arrière-plan). Publie chaque mesure telle quelle : `{deg: 0..360, fiabilite: 0..3}`, ou une fois `{absent: true}` sans capteur ; aucun lissage (c'est la carte qui adoucit, `MyPointMotion`). App tenue en portrait : pas de réorientation du repère. Créé et libéré par `MainActivity`. iOS : `CLLocationManager.startUpdatingHeading` (`trueHeading`, `headingAccuracy`) |
| `events/EventPresenceService.kt` | le service : **moteur fusionné de Google** via `PositionEngine` (haute précision, toutes les 20 s) et `LocationManager` (GPS + réseau) **en repli seulement** — corrigé le 2026-09-25 : le moteur brut ne donnait plus rien à l'intérieur, la présence restait figée 30 min (même leçon que `LocationBeat`, 2026-09-22). Un tick par minute, dépôt sur un fil de travail, notification « Présent à … » (canal `neovibe_event_presence`, importance basse). **Carnet sur disque** `event_presence.log` (`ServiceJournal`) : démarré / arrêté / chaque dépôt ou `no_fix`, avec moteur, précision et âge de la position. `START_STICKY` ; relancé sans intention, il s'arrête |
| `events/EventPresenceBridge.kt` | `start(eventId, title)` (démarre ou re-cible), `stop()`, `running`, `journal` (le carnet, pour le diagnostic — 2026-09-25) ; événements `{eventId, outcome}` (`present`, `away`, `none`, `no_fix`, `offline`, `auth`, `rejected`, `error`, `stopped`) |
| `EventPresenceHub` (même fichier) | l'`object` par lequel le service publie, que le pont soit là ou non |
| `publish/SupabaseHttp.rpcText` | un appel RPC dont on lit la réponse (ajouté pour ce service) |

Manifeste : `<service android:name=".events.EventPresenceService"
android:foregroundServiceType="location">` ; la permission
`FOREGROUND_SERVICE_LOCATION` était déjà déclarée (§ProximityService).
Aucun test JVM : la logique est le tick et l'appel ; la mesure se fait sur
l'appareil (ligne `report_event_position` dans `event_presences.last_position_at`).
