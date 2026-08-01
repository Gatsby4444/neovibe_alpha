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
| Proximité BLE | `neovibe/ble` | BLE natif (advertise/scan + GATT) | CoreBluetooth |
| Transfert média proximité | *(à venir)* | Wi-Fi Direct (Wi-Fi P2P) | MultipeerConnectivity |
| Hôte / cycle de vie | — | `MainActivity : FlutterFragmentActivity` | `AppDelegate` / `FlutterViewController` |
| Journal caméra (dev) | (dans `neovibe/camera`) | `CamLog` (fichier disque) | fichier disque (trivial) |

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

**Canal** : `neovibe/ble`. Méthodes : `start`, `stop`, `connect`, `disconnect`,
`send`. Événements natif→Dart : `onError`, `onLink`, `onFrame`, (scan) résultats.

**Android (fait)** : `NativeBle.kt` — **BLE natif complet** :
- **Advertising** (`AdvertiseCallback`) + **Scan** (`ScanCallback`) pour la
  détection ;
- **Serveur GATT** (on est périphérique) + **client GATT** (on est central) :
  un lien = un tuyau d'octets (write requests / MTU).
- Scan en arrière-plan via service de premier plan (voir `RAPPELS.md` :
  batterie à optimiser).

**iOS (à faire)** : **CoreBluetooth** :
- `CBPeripheralManager` (advertising + serveur GATT), `CBCentralManager` (scan +
  client GATT).
- **Points d'attention** : le scan en arrière-plan est **très restreint** sur
  iOS (filtrage obligatoire par UUID de service, pas de scan continu, réveils
  limités) → la détection de proximité « app fermée » se comportera différemment
  et devra être repensée. L'advertising en arrière-plan est aussi bridé.

---

## 4. Proximité — transfert média (Wi-Fi Direct)

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
Fragment fournit. Enregistre les canaux caméra + BLE + média, initialise
`CamLog`.

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

## 7. Notifications push (à vérifier)

**Statut** : la logique de notifications existe côté Dart (`notification_service.
dart`). **À auditer** : le transport push (FCM ?) et sa config par OS (APNs pour
iOS) au moment du portage. Compléter cette entrée quand le mécanisme est confirmé.
