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

- [x] **Étape 1 — Harnais GPU, UNE caméra. CODÉE (v0.9.5), EN ATTENTE DE TEST.**
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
- [ ] **Étape 2 — Double aperçu GPU.** 2 caméras → 2 textures → GPU. Remplace le
  `lockCanvas`. Cible : ~45 i/s constant.
- [ ] **Étape 3 — Photo instantanée GPU.** Capture = rendu offscreen + readback,
  les 2 faces d'un coup.
- [ ] **Étape 4 — Vidéo double.** Chaque texture caméra → surface `MediaCodec` →
  2 vidéos (recto/verso).
- [ ] **Étape 5 — Repli & universalité.** Séquentiel propre + instantané
  (« dernière image ») sur appareils incapables.

## État courant

**Étape 1 CODÉE et releasée en v0.9.5 — en attente du test de Jay.** Prochain
pas : Jay ouvre Réglages → Développeur → « Aperçu GPU (étape 1) », dit si c'est
fluide et dans le bon sens, et envoie le journal. Selon le résultat :
- OK → **Étape 2** (double aperçu GPU : dupliquer la logique de `Camera2Gl` pour
  deux caméras + deux textures, ouvrir arrière puis avant comme `Camera2Dual`).
- Orientation/miroir faux → corriger `mvpMatrix` dans `Camera2Gl.onFrame()`.
- Aperçu noir / erreur → lire le journal (EGL/shader/caméra tracés) ; `close`
  puis diagnostiquer.

Dernière release : **v0.9.5** (versionCode 95).

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
