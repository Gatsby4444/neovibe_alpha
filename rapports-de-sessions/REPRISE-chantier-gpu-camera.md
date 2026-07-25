# REPRISE — Chantier « rendu caméra GPU/OpenGL »

> Document de reprise VIVANT. But : qu'une nouvelle session (ou une reprise après
> résumé de contexte / limite de tokens) puisse continuer le chantier sans rien
> re-déduire. **Mettre à jour à chaque étape.** À lire APRÈS `CLAUDE.md`,
> `RAPPELS.md` et le dernier rapport de session.

## Pourquoi ce chantier (contexte décidé le 2026-07-24)

Le double flux caméra FONCTIONNE mais le **rendu logiciel** (`Camera2Dual.kt`,
`lockCanvas` depuis un ImageReader YUV) plafonne à **~20-27 i/s avec freezes**.
Preuve qu'on peut faire mieux : l'app tierce **GoNext « Dual Vlog Camera »** fait
**~45 i/s constant + photo + vidéo double** sur le même Redmi Note 10 Pro. La clé
n'est PAS l'accès caméra (le concurrent marche) mais le **chemin de rendu** :
GoNext rend en **GPU/OpenGL**, nous en logiciel (CPU).

**Décision de Jay : réécrire le rendu caméra en OpenGL ES.**

## Principe (à ne jamais perdre de vue)

- **Toujours 1 flux par caméra** (contrainte matérielle mesurée). 2 caméras × 1
  flux = double live. Interdit : 2 flux sur UNE caméra (affame la frontale).
- Le flux unique de chaque caméra va dans une **`SurfaceTexture` matérielle**
  (texture externe OES), pas dans un ImageReader logiciel.
- Le **GPU** dérive TOUT de ce flux unique : aperçu (shader → texture Flutter),
  photo (rendu offscreen + readback), vidéo (rendu → surface d'un `MediaCodec`).
  Aucun de ces usages n'est un flux caméra supplémentaire → contrainte respectée.
- **On GARDE ce qui marche** : forçage FPS capteur (`CONTROL_AE_TARGET_FPS_RANGE`
  = [30,30] mesuré), séquence d'ouverture des 2 caméras (arrière puis avant),
  discipline de fermeture (attendre `onClosed`), et le moteur logiciel actuel
  (`Camera2Dual`) reste EN PLACE comme filet jusqu'à ce que le GPU le remplace.
- **Universalité** : sur appareils incapables du concurrent, repli séquentiel —
  lui-même rendu **instantané** (technique « dernière image »).

## Contraintes / leçons matérielles (durement acquises — ne pas refaire)

1. Instrumenter AVANT de corriger (journal `CamLog` persistant).
2. Une session Camera2 qui se configure ne prouve rien — seules les images
   REÇUES font foi.
3. Ne jamais sonder le matériel à l'usage (un essai raté tue le service caméra
   jusqu'au redémarrage de l'app).
4. Attendre le FAIT (images qui arrivent), jamais un délai en dur.
5. Toute API Flutter (TextureRegistry, MethodChannel) s'appelle sur le **thread
   principal** ; les callbacks caméra/GL arrivent sur d'autres threads.

## Architecture cible

- `Camera2Gl.kt` (NOUVEAU) : moteur de rendu GPU. Contexte EGL + thread GL dédié.
  Par caméra : texture externe OES + `SurfaceTexture` (sortie caméra) → shader →
  `EGLWindowSurface` adossée à une **texture Flutter** (`SurfaceProducer`).
- Branché dans `NativeCamera.kt` comme `Camera2Dual` (champ + previewInfoSink +
  cas `when(call.method)`).
- Côté Dart : `NativeCameraController` (méthodes), écran de test dev, tuile
  Réglages → Développeur.

## Feuille de route (statut par étape)

- [x] **Étape 1 — Harnais GPU, UNE caméra. VALIDÉE (v0.9.8).** ~30 i/s constant,
  zéro freeze. **Orientation trouvée par Jay au sélecteur : rotation 0, miroir
  off pour les DEUX caméras** (la matrice de la SurfaceTexture gère déjà le sens
  sur cet appareil). Figé dans le code.
- [x] **Étape 1 (détail) — Harnais GPU. CODÉE (v0.9.5), EN ATTENTE DE TEST.**
  EGL + thread GL + shader OES, caméra arrière/avant → texture Flutter. Écran de
  test dev ISOLÉ (Réglages → Développeur → « Aperçu GPU (étape 1) »). Fichiers :
  `Camera2Gl.kt` (moteur), `NativeCamera.kt` (cas `openGlPreview`/`closeGlPreview`
  + champ `camera2Gl`), `native_camera.dart` (`openGlPreview`/`closeGlPreview`,
  `glTextureId`), `gl_preview_test_screen.dart` (écran), `settings_screen.dart`
  (tuile). Compile + build OK. *À VÉRIFIER par Jay : aperçu **fluide** ? **bon
  sens** (pas pivoté ni miroir) ? Le journal trace « PREMIÈRE image rendue par
  le GPU » + le nombre d'images.*
  **Si orientation fausse** : ajuster dans `Camera2Gl.onFrame()` la
  construction de `mvpMatrix` (`Matrix.rotateM(..., sensorOrientation, 0,0,1)` —
  changer le signe / l'angle) et/ou le miroir. C'est le point que cette étape
  isole exprès — correctif d'une ligne.
- [x] **Étape 2 — Double aperçu GPU. VALIDÉE (v0.9.9).** Journal de Jay :
  « DOUBLE FLUX GPU vivant » + **les DEUX caméras à ~30 i/s CONSTANT en même
  temps** (arrière 30,0 ; avant 29,7 ; mesuré sur 240 images / 8 s chacune),
  zéro freeze, aucune affamée. Le rendu logiciel (20-27 i/s + freezes +
  frontale affamée) est battu. Détails ci-dessous.
- [x] **Étape 2 (détail) — Double aperçu GPU. CODÉE (v0.9.9), TESTÉE OK.**
  Deux instances `Camera2Gl` (`glBack`/`glFront`, clés preview distinctes),
  ouvertes en séquence : arrière → **attend sa 1re image RENDUE** (refactor :
  `open(...onReady)` signale « prêt » à la 1re image, pas à la config session)
  → avant. `openGlDual`/`closeGlDual` dans NativeCamera ; écran de test avec un
  mode « Double » (arrière plein + avant en vignette). `eglTerminate` retiré de
  `close()` (display EGL partagé entre les 2 instances). Orientation figée
  0°/off. *À VÉRIFIER par Jay : les deux aperçus s'affichent-ils en même temps,
  fluides ? Le journal doit montrer « DOUBLE FLUX GPU vivant ».*
  **Si une caméra affame l'autre / éviction** : revoir la choréographie
  (délai entre arrière et avant) — mais l'attente de la 1re image devrait
  suffire (c'est ce qui marche pour le double flux logiciel).
- [x] **Étape 3 — Photo instantanée GPU. VALIDÉE (v0.9.10).** Jay : « ça marche
  super bien, capture instantanée vraiment comme je voulais ». Journal :
  « capture GPU des deux faces en **83-119 ms** », caméras toujours à 30 i/s.
  **Correctif crash v0.9.11** : basculer les modes vite lançait 2 ouvertures de
  la même caméra en //  → « Error configuring streams -38 » NON rattrapée →
  crash. Fix : try/catch autour de `createCaptureSession` dans `Camera2Gl`
  (un souci caméra ne crashe plus) + garde anti-ré-entrance `_busy` dans
  l'écran de test (opérations sérialisées, boutons désactivés pendant).
- [x] **Étape 3 (détail) — Photo GPU. CODÉE (v0.9.10), TESTÉE OK.**
  `Camera2Gl.capturePhoto()` : rend la dernière image dans un FBO offscreen
  (720×1280, même shader → déjà droit), `glReadPixels`, miroir vertical
  (glReadPixels lit bas→haut), JPEG. `captureGlDual` (NativeCamera) capture les
  deux faces d'affilée (hors thread principal) → instantané. Bouton « Capturer
  les 2 faces (GPU) » en mode Double du test, affiche les 2 photos. *À VÉRIFIER
  par Jay : les 2 photos sortent-elles DROITES, non distordues, couleurs OK
  (pas de rouge/bleu inversé) ? Instantané ?* Si couleurs inversées → swizzle
  R/B ; si tête en bas → retirer le miroir vertical dans `renderToJpeg`.
- [x] **Étape 4 — Vidéo double. CODÉE (v0.9.12), EN ATTENTE DE TEST.** Chaque
  `Camera2Gl` encode son propre `.mp4` via un `MediaCodec` H264 alimenté par une
  **2e surface EGL** posée sur l'input Surface du codec (même contexte EGL → OES
  + shader partagés, aucun flux caméra en plus) + `MediaMuxer` par caméra.
  `onFrame` dessine la même image dans l'aperçu ET la surface du codec
  (`drawCurrentFrame` factorisé), timestamp = `SurfaceTexture.timestamp`.
  Canal : `startGlDualVideo`/`stopGlDualVideo`. Test : écran « Aperçu GPU » →
  Double → bouton « Vidéo (2 faces) » → lecture des 2 .mp4 côte à côte.
  **Débit 6 Mb/s** (local). **SANS AUDIO** (simplification assumée — incrément
  suivant). *À VÉRIFIER par Jay : 30 i/s tenus par les DEUX encodeurs sans
  s'affamer ? sens/couleurs OK (mêmes que la photo GPU) ? pas de crash si on
  quitte en cours d'enregistrement ?* Journal : « VIDÉO DOUBLE GPU démarrée » +
  tailles des fichiers à l'arrêt.
- [x] **Étape 4 vidéo — VALIDÉE (v0.9.13).** Jay : « approuvé ». Deux encodeurs
  à 30 i/s constants, fichiers cohérents, lecture propre (un lecteur à la fois).
- [x] **Étape 4 (suite) — Audio partagé. VALIDÉE (v0.9.14).** Jay : « approuvé ».
  Un seul micro → `DualAudioEncoder.kt` (`AudioRecord` 44,1 kHz mono → AAC
  96 kb/s) → **muxé dans les DEUX .mp4** (chaque `Camera2Gl` est un `AudioSink`,
  piste audio propre, accès muxer sous `muxerLock`). Démarrage muxer différé
  jusqu'à vidéo+audio connus ; PTS des deux pistes normalisés à ~0.
  `stopGlDualVideo` arrête l'audio EN PREMIER (flush) avant la vidéo. Repli vidéo
  muette si l'audio échoue. **Journal : « capture partagée démarrée », deux .mp4
  cohérents (9061/8995 Ko), 30 i/s tenus.** → **ÉTAPE 4 COMPLÈTE.**
- [x] **Étape 5a — Moteur GPU dans le VRAI Oneshot. CODÉE (v0.9.15), EN ATTENTE
  DE TEST.** `card_capture_screen.dart` passe de `dualActive`/`openDual`/
  `takeDualPictures` (moteur logiciel) à `glDualActive`/`openGlDual`/
  `captureGlDual` (moteur GPU) ; clés d'aperçu `glBack`/`glFront`. **Release
  universel** dans `NativeCamera.close` (ferme aussi `camera2Gl`/`glBack`/
  `glFront`) — sans ça, quitter l'écran laissait les caméras tenues. Échec de
  `openGlDual` traité comme `openDual` (`DualUnsupportedException` +
  `dualFailedThisSession`, pas de re-sondage). Comportement identique à avant :
  photo double instantanée ; l'appui long en Oneshot dit « photo pour l'instant ».
  *À VÉRIFIER par Jay : voir la liste du rapport 2026-07-25_12-23.*
- [x] **Étape 5b — Vidéo double dans le vrai Oneshot. VALIDÉE (v0.9.21).**
  Jay : « c'est beaucoup mieux, c'est correct ». Journal propre : deux fichiers
  de 8070 Ko, 30 i/s tenus par les deux encodeurs, plus aucune erreur Riverpod.
  Deux correctifs après le 1er test (v0.9.21) : **synchro audio** (les deux
  pistes partagent désormais une origine commune — l'audio démarre ~450 ms après
  la vidéo, le remettre à zéro le mettait en avance) et **lecture continue au
  retournement** (les deux lecteurs tournent en parallèle, seul celui de la face
  regardée a le son : les deux faces sont le même instant vu de deux côtés).
- [x] **Étape 5b (détail) — CODÉE (v0.9.20).** L'appui long en Oneshot filme les DEUX caméras (moteur GPU,
  audio partagé) → recto = arrière, verso = avant, deux `.mp4` dans une seule
  card. **Bonne surprise** : le modèle de card gérait déjà une vidéo PAR FACE
  (`front_is_video`/`back_is_video`), et l'upload comme le cache local sont
  génériques — rien à changer côté données. Le travail réel était ailleurs :
  1. **Débit ramené de 6 à 3,5 Mb/s** dans `Camera2Gl` (même plafond que
     CameraX) : 2 fichiers × 61 s tenaient sinon ~46 Mo chacun, trop près de la
     limite Supabase de 50 Mo (RAPPELS #7).
  2. **Un seul lecteur vidéo vivant à la fois**, partout où DEUX faces vidéo
     coexistent — le viewer construit ses deux faces simultanément et le récap
     affiche deux vignettes : c'est exactement la configuration qui gelait un
     lecteur en v0.9.12. Viewer : la face cachée devient `_SleepingVideoFace`
     (montée au passage du retournement, pas à la pose). Récap : seule la
     vignette recto joue, le verso reste sur sa première image.
  3. Plus de réouverture du double flux après l'arrêt : couper les encodeurs ne
     retire que leur surface EGL, les caméras continuent de rendre l'aperçu
     (le moteur logiciel, lui, débranchait les `ImageCapture`).
  *À VÉRIFIER par Jay : voir la liste du rapport 2026-07-25_12-23.*
- [x] **Étape 5c — Repli séquentiel. CODÉE (v0.9.22), EN ATTENTE DE TEST.**
  Le repli existait déjà ; ce qui manquait, c'était sa qualité. Les deux délais
  en dur de 250 ms sont remplacés par l'attente du FAIT : `switchLens` ne répond
  que lorsque `CameraState` dit la caméra OUVERTE (`awaitCameraOpen`, garde-fou
  1200 ms). L'écart réel entre les deux faces est mesuré et journalisé.
  La « technique de la dernière image » était déjà en place (texture conservée
  à travers la bascule + voile flouté, pas de trou noir).
  **Testable sur le Redmi** via Réglages → Développeur → « Forcer la vue simple
  Oneshot » (c'est cet interrupteur, activé chez Jay, qui donnait l'illusion
  d'un repli matériel).
- [x] **Étape 5d — Nettoyage du code mort. CODÉE (v0.9.23), EN ATTENTE DE TEST.**
  Décision de Jay, contre ma réserve : « je préfère ne pas avoir de backup plutôt
  qu'une backup médiocre au niveau UX » — le moteur logiciel plafonnait à
  20-27 i/s avec freezes, il n'aurait pas fait un repli acceptable.
  Supprimés : `Camera2Dual.kt`, `DualCameraProbe.kt`, les méthodes de canal
  `openDual` / `takeDualPictures` / `startDualVideo` / `stopDualVideo` /
  `probeDual`, leurs équivalents Dart, la tuile « Tester le double flux » des
  Réglages dev et la branche HUD « (soft) ».
  **Effet de bord CORRIGÉ au passage** : la barrière « attendre que le matériel
  soit rendu » avant de rouvrir CameraX portait sur `camera2Dual.close` — donc
  sur un moteur qui ne tenait plus rien depuis 5a. Elle porte désormais sur les
  moteurs GPU (`releaseDualEngines`, qui chaîne les trois fermetures et n'appelle
  la suite qu'une fois la dernière terminée). La réponse de `close` attend
  vraiment le matériel, ce qui n'était plus le cas.
  **Le repli séquentiel du Oneshot, lui, RESTE** : c'est CameraX, pas le moteur
  logiciel supprimé.

## État courant

**Étape 1 : la plomberie GPU MARCHE (v0.9.5) — rendu à ~30 i/s CONSTANT, zéro
freeze** (journal de Jay : 120 images / ~4,04 s, pile le [30,30] du capteur).
C'est la validation clé : le GPU tue les à-coups du rendu logiciel.

Défauts géométriques v0.9.5 : orientation fausse + image distordue. **Corrigé en
v0.9.6** : on ne tourne plus dans le GPU (tourner la géométrie dans un viewport
non carré distordait). Le GPU rend l'image **brute (paysage)** ; la rotation +
le miroir sont délégués au Dart (`NativeCameraPreview` : RotatedBox + cover),
exactement comme l'aperçu CameraX simple qui n'est pas distordu. `previewInfo`
renvoie désormais `(1280, 720, sensorOrientation)` ; l'écran de test passe
`mirror: !back`.

**v0.9.6 → paysage (rotation Dart non appliquée).** La délégation de la rotation
au Dart (previewInfo rotation=sensorOrientation + RotatedBox) N'A PAS marché sur
ce chemin — cause exacte non élucidée (le même widget tourne pourtant l'aperçu
CameraX). Abandonné.

**v0.9.7 → rotation FAITE DANS LE GPU, sur les coordonnées de texture.** Sortie
portrait 720×1280 ; positions plein écran ; on tourne l'échantillonnage
(`uTexRot` = rotation autour de 0.5,0.5 de `-sensorOrientation`, + miroir front).
Une rotation 90° des texcoords aligne 1280↔1280 et 720↔720 → **aucune
distorsion** (déterministe, contrairement à la rotation de géométrie de v0.9.5).
Côté Dart : rotation 0, `mirror: false`.

**v0.9.7 → toujours paysage, « autre sens ».** 3e essai raté à deviner
l'orientation. Décision : **arrêter de deviner**. `openGlPreview` prend
maintenant `rotation` (0/90/180/270) + `mirror` en PARAMÈTRES, et l'écran de
test a des boutons (Tourner / Miroir / Caméra) qui montrent la combinaison
courante. **v0.9.8** : Jay tourne jusqu'à ce que l'image soit droite et NOTE la
combinaison (caméra + rotation° + miroir) affichée à l'écran.

**Quand Jay aura la/les bonnes combinaisons (arrière + avant)** : les figer —
c.-à-d. déduire la formule `rotation = f(sensorOrientation)` (probablement
`rotation = sensorOrientation` ou `360 - sensorOrientation`) et `mirror = !back`,
la câbler par défaut dans `Camera2Gl` / l'appelant, retirer le bandeau de
réglage du test, puis passer à l'**Étape 2** (double aperçu GPU).

Autre point remonté par Jay (v0.9.7) : lancer la sonde/double cam PUIS le test
GPU juste après peut coincer (libération caméra entre deux tests). À traiter
après l'orientation (probable : attendre `isCameraServiceAlive` / fermeture
complète avant d'ouvrir le GPU).

**v0.9.8 → orientation 0°/off.** **v0.9.9 → Étape 2 VALIDÉE : double aperçu GPU,
2 caméras à 30 i/s constant simultanées.** Le socle GPU est prouvé de bout en
bout (interop Flutter, orientation, double flux fluide).

**Prochain pas : Étape 3 — photo GPU instantanée.** Approche prévue : au
déclenchement, chaque `Camera2Gl` rend sa dernière image dans un framebuffer
offscreen (ou lit la texture) → `glReadPixels` → JPEG. Les deux faces d'un coup,
instantané, toujours 1 flux/caméra. Puis Étape 4 (vidéo double : chaque texture
→ surface `MediaCodec`), puis Étape 5 (brancher ce moteur GPU dans le VRAI
Oneshot à la place de `Camera2Dual` logiciel + repli séquentiel universel).

Détail à ne pas oublier : les instances dual loguent encore « ÉTAPE 1 » (cosmé-
tique) ; le point Jay « sonde/double puis test GPU juste après coince » reste à
traiter (libération caméra entre tests).

**v0.9.10 → Étape 3 (photo GPU instantanée) codée**, en attente du test de Jay
(photos droites, non distordues, couleurs OK, instantané ?). Si OK → Étape 4
(vidéo double : chaque texture → surface `MediaCodec`).

**v0.9.10 → Étape 3 VALIDÉE (photo instantanée 83-119 ms).** **v0.9.11 →
correctif crash** (double ouverture caméra + exception non rattrapée).

**Prochain pas : Étape 4 — vidéo double.** Chaque `Camera2Gl` alimente un
encodeur : ajouter au rendu une 2e cible EGL (window surface sur l'input Surface
d'un `MediaCodec` H264) + un muxer `MediaMuxer` par caméra → deux .mp4
(recto/verso). Le rendu dessine alors dans DEUX surfaces (aperçu + encodeur).
Puis Étape 5 : brancher dans le vrai Oneshot (remplacer `Camera2Dual`) + repli
séquentiel universel + supprimer le code mort (Camera2Dual logiciel, sonde).

**v0.9.12 → Étape 4 (vidéo double GPU) codée.** Test Jay : capture OK (2 fichiers
~37 Mo animés, deux encodeurs à 30 i/s) mais LECTURE défaillante (arrière figée +
écrasée en largeur). Cause : deux `VideoPlayer` simultanés (un gèle) + deux
portraits côte à côte. **L'encodeur est bon** (37 Mo = vidéo animée réelle).

**v0.9.13 → correctif lecture** : `_DualVideoPlayback` = un seul lecteur à la
fois, plein écran, bascule Arrière/Avant. **Validé par Jay : étape 4 vidéo OK.**

**v0.9.14 → Étape 4 (suite) audio partagé** : un micro → `DualAudioEncoder` →
piste audio identique muxée dans les deux .mp4. En attente du test de Jay (son
présent dans les deux vidéos ? synchro ? pas de régression vidéo ?).

**v0.9.15 → Étape 5a** : le moteur GPU remplace le moteur logiciel dans le VRAI
Oneshot (aperçu double + photo double). En attente du test de Jay. Le moteur
logiciel `Camera2Dual` reste en place comme filet (non utilisé par le Oneshot),
il ne sera supprimé qu'en 5c.

**v0.9.16 → v0.9.19** : miroir de la frontale (réglage utilisateur ON par défaut,
Réglages → Caméra ; le flux GL frontal arrive DÉJÀ mirroré, d'où une inversion
explicite sur ce chemin — RAPPELS #9), et correctifs `ref` Riverpod.

**v0.9.20 → v0.9.21 : ÉTAPE 5b VALIDÉE.** Le Oneshot filme les deux caméras
(deux `.mp4` dans une card), audio synchronisé, lecture continue au retournement.

**Prochain pas : Étape 5c** — repli séquentiel universel (appareils incapables du
double flux) + suppression du code mort (`Camera2Dual` logiciel, `DualCameraProbe`)
une fois le GPU validé sur plusieurs appareils (RAPPELS #8).

Dernière release : **v0.9.21** (versionCode 111) — Oneshot filmé complet.

## Rappel build + release (toolchain hors PATH)

```
export JAVA_HOME="C:/Charles/dev/jdk17"
"C:/Charles/dev/flutter/bin/dart.bat" format <fichiers>
"C:/Charles/dev/flutter/bin/flutter.bat" analyze
"C:/Charles/dev/flutter/bin/flutter.bat" build apk --release
```
Puis : bump `pubspec` (versionName+versionCode, ex. 0.9.5+95), commit (FR),
`git tag vX.Y.Z`, `git push origin master` + `git push origin vX.Y.Z`,
`gh release create vX.Y.Z build/app/outputs/flutter-apk/app-release.apk ...`.
APK à installer depuis GitHub (Jay teste sur téléphone). Vérifier la 1re ligne
du journal : « démarrage — NeoVibe vX.Y.Z ».
