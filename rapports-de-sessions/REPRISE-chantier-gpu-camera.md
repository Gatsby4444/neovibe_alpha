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
- [x] **Étape 3 — Photo instantanée GPU. CODÉE (v0.9.10), EN ATTENTE DE TEST.**
  `Camera2Gl.capturePhoto()` : rend la dernière image dans un FBO offscreen
  (720×1280, même shader → déjà droit), `glReadPixels`, miroir vertical
  (glReadPixels lit bas→haut), JPEG. `captureGlDual` (NativeCamera) capture les
  deux faces d'affilée (hors thread principal) → instantané. Bouton « Capturer
  les 2 faces (GPU) » en mode Double du test, affiche les 2 photos. *À VÉRIFIER
  par Jay : les 2 photos sortent-elles DROITES, non distordues, couleurs OK
  (pas de rouge/bleu inversé) ? Instantané ?* Si couleurs inversées → swizzle
  R/B ; si tête en bas → retirer le miroir vertical dans `renderToJpeg`.
- [ ] **Étape 4 — Vidéo double.** Chaque texture caméra → surface `MediaCodec` →
  2 vidéos (recto/verso).
- [ ] **Étape 5 — Repli & universalité.** Séquentiel propre + instantané
  (« dernière image ») sur appareils incapables.

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

Dernière release : **v0.9.10** (versionCode 100) — photo GPU des 2 faces.

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
