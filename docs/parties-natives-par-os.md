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
| Proximité BLE | `neovibe/proximity` + `/events` | Service de premier plan qui POSSÈDE la radio (advertise/scan + GATT) | CoreBluetooth, **mode dégradé à concevoir** |
| Transfert média proximité | *(à venir)* | Wi-Fi Direct (Wi-Fi P2P) | MultipeerConnectivity |
| Hôte / cycle de vie | — | `MainActivity : FlutterFragmentActivity` | `AppDelegate` / `FlutterViewController` |
| Journal caméra (dev) | (dans `neovibe/camera`) | `CamLog` (fichier disque) | fichier disque (trivial) |
| Diagnostic appareil (dev) | `neovibe/diag` | `NativeDiagnostics` (`PackageManager` + `Build`) | `Bundle.main.infoDictionary` + `UIDevice` |

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
| `neovibe/proximity` | Dart → natif | les **ordres** : `probe`, `start`, `stop`, `updateAdvert`, `connect`, `disconnect`, `send` |
| `neovibe/proximity/events` | natif → Dart | les **constats** : `status`, `scan`, `link`, `frame` |

L'ancien code faisait remonter les événements par `invokeMethod` sur le canal de
commandes. Un flux qui remonte n'a pas les mêmes règles qu'un ordre qui descend —
il n'attend pas de réponse, il peut n'avoir aucun auditeur, et il doit survivre
au remplacement de l'interface.

**Android (fait, 2026-08-16)** — trois fichiers dans `ble/` :

- **`RadioStatus.kt`** — l'**état réel** de la radio, et le calcul des
  permissions réellement exigées selon la version d'Android. C'est le cœur du
  chantier : plus aucun échec silencieux.
- **`BleEngine.kt`** — advertising, scan, serveur et client GATT. **Ne dépend
  d'aucune `Activity`.** Écoute `ACTION_STATE_CHANGED` : le Bluetooth rallumé
  relance tout seul. Files d'écriture dans **les deux sens**.
- **`ProximityService.kt`** — service de premier plan qui **possède** le moteur
  et survit à la destruction de l'interface (décision de Jay). Sa notification
  dit l'état vrai.
- **`ProximityBridge.kt`** — le pont vers Dart. **Jetable** : il naît et meurt
  avec l'activité, le service reste.

⚠️ Déclarer le service au manifeste avec
`android:foregroundServiceType="connectedDevice"`.

**iOS (à faire)** — **CoreBluetooth**, et il faudra concevoir un **mode
dégradé** :

- `CBPeripheralManager` (advertising + serveur GATT), `CBCentralManager` (scan +
  client GATT) ;
- ⚠️ **Le modèle Android ne se transpose pas.** iOS n'a pas d'équivalent du
  service de premier plan : le scan en arrière-plan est très restreint
  (filtrage obligatoire par UUID de service, pas de scan continu, réveils
  limités) et **l'advertising en arrière-plan ne transporte pas les données de
  fabricant** — or c'est là que voyage notre ID rotatif. La reconnaissance
  silencieuse des amis app fermée devra donc être repensée, pas seulement
  portée.
- ⚠️ **Ce qui se porte tel quel, en revanche** : tout ce qui est au-dessus de la
  radio est en Dart pur et sans dépendance Android — transport, canal sécurisé,
  protocole, présence, fonctions. Seule la couche 0 est à réécrire.

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

## 8. Notifications push (à vérifier)

**Statut** : la logique de notifications existe côté Dart (`notification_service.
dart`). **À auditer** : le transport push (FCM ?) et sa config par OS (APNs pour
iOS) au moment du portage. Compléter cette entrée quand le mécanisme est confirmé.
