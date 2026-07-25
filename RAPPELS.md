# Rappels — NeoVibe

Fichier de mémoire de Jay. **Claude doit le tenir à jour** : y consigner tout
point que Jay demande de « garder pour plus tard » ou de « rappeler », et le
ressortir quand le contexte s'y prête (release de prod, chantier concerné).
Ne rien y supprimer sans validation explicite de Jay.

---

## Avant la mise en production

| # | Sujet | Détail | Depuis |
|---|-------|--------|--------|
| 1 | **Durée max des vidéos** | Fixée à **61 s** en dev. Jay veut repenser cette limite avant la prod. | 2026-07-12 |
| 2 | **Usurpation de username hors ligne** | En BLE, le mini-profil est signé par la clé de l'appareil mais **pas attesté par le serveur** : un pair jamais vu en ligne pourrait annoncer un username qui n'est pas le sien. Parade prévue : attestation serveur signée du couple (userId, username), distribuée avec les clés d'appareil. | 2026-07-13 |
| 3 | **Consommation batterie du scan BLE en arrière-plan** | Le scan tourne app fermée (service de premier plan, validé par Jay). À **mesurer et optimiser** (scan par intervalles / duty cycle) dès les premiers tests réels à deux appareils, et avant la prod. | 2026-07-13 |
| 4 | **Section Développeur des Réglages** | À retirer avant la prod : interrupteur anti-capture, diagnostic caméra, déclenchement BeReal manuel. | 2026-07-11 |
| 6 | **RÉACTIVER L'ANTI-CAPTURE (FLAG_SECURE)** | Il est **désactivé par défaut** pendant le développement (demande de Jay 2026-07-14 : pouvoir prendre des captures d'écran pour montrer les bugs). Le code fonctionne et reste testable via Réglages → Développeur → « Anti-capture ». **Repasser le défaut à ACTIF avant la prod** (`DevSecureEnabled` dans `lib/core/prefs.dart` + `main.dart`). | 2026-07-14 |
| 7 | **Limite d'upload Supabase (50 Mo/fichier)** | Cause du `StorageException 413` sur une vidéo Mono. Contourné en plafonnant le débit vidéo à 3,5 Mbit/s (61 s ≈ 28 Mo). Si la qualité vidéo doit remonter, il faudra un plan Supabase supérieur (limite d'upload plus haute) ou une compression côté client. | 2026-07-14 |
| 5 | **Fichiers orphelins du Storage** | Les fichiers des cards supprimées restent dans le bucket (`delete from storage.objects` est interdit par Supabase). Prévoir une edge function de purge physique. | 2026-07-12 |
| 8 | **Fiabilité dual-cam : repli universel + test multi-appareils** | Le double flux dépend du matériel (pas universel). Pour que le Oneshot soit fiable pour TOUS : (a) **repli séquentiel automatique** sur appareils incapables (étape 5 du chantier GPU), et (b) **test multi-appareils** avant la prod (Firebase Test Lab ou bêta-testeurs variés) — on ne valide aujourd'hui que sur le Redmi Note 10 Pro. Voir `docs/strategie-multiplateforme.md`. | 2026-07-24 |
| 9 | **Sens du miroir de la frontale en double flux GPU** | Sur le Redmi Note 10 Pro, le flux GL de la frontale arrive **déjà mirroré** (matrice de la `SurfaceTexture`), contrairement au flux CameraX du mode simple qui arrive brut. Le code compense par une inversion explicite dans `_dualPreviewFrame` (`mirrorFront = !_selfieMirror`). **Ce sens dépend du matériel** : à revérifier sur chaque nouvel appareil testé, en même temps que le point 8. Correctif éventuel = une ligne. | 2026-07-25 |

## Chantiers promis, à ne pas oublier

| # | Sujet | Détail | Depuis |
|---|-------|--------|--------|
| 1 | **Streaks de proximité** | Chantier dédié. La fondation est posée (certificats de croisement co-signés, 10 s de contact continu) : paliers de couleur + dégradation progressive restent à faire. | 2026-07-13 |
| 2 | **Stories** | Format à part ; les cards pourront être mises en story. Emplacement déjà réservé en haut du hub Cercle. | 2026-07-12 |
| 3 | **Wi-Fi Direct pour les cards en conversation ping** | Le chat ping est en BLE (texte et petits paquets). L'envoi de cards/médias dans les conversations éphémères passera par Wi-Fi Direct. | 2026-07-13 |
| 4 | **Vignettes des grilles (bibliothèque / enregistrements)** | Elles passent encore par le **réseau** : seul le viewer utilise le cache local. À câbler sur le cache. (Le décodage d'une face vidéo en image — « Invalid image data » — est corrigé en v0.9.2 : widget `FaceThumb`.) | 2026-07-13 |
| 6 | **Double flux Oneshot — VALIDÉ (v0.9.0), reste la vidéo double** | Le double live FONCTIONNE sur le Redmi Note 10 Pro : 1 flux par caméra, rendu logiciel, capture simultanée. Reste **opt-in développeur** (le bouton « Double live » n'apparaît que si l'option est active). **La vidéo double simultanée reste à faire** (deux encodeurs). Ne JAMAIS revenir à : 2 flux par caméra (frontale affamée), reconfiguration de session pendant que l'autre caméra tourne, sonde de configurations à l'usage (casse le service caméra). | 2026-07-14 |
| 9 | **CHANTIER MAJEUR — rendu caméra en GPU/OpenGL** | Direction validée par Jay (2026-07-24). Le rendu logiciel actuel (`lockCanvas`) plafonne à ~20-27 i/s avec freezes ; une app tierce (GoNext « Dual Vlog Camera ») fait **~45 i/s constant + photo + vidéo double** sur le même Redmi → prouve que le GPU/OpenGL est la clé (1 flux/caméra en **SurfaceTexture matérielle**, composité GPU pour aperçu + photo readback + encodeur vidéo). Objectif : fluide + instantané + vidéo double sur appareils capables, **repli séquentiel instantané** (technique « dernière image ») sur les autres = universel. Feuille de route en 5 étapes testables (voir rapport 2026-07-24). Garder le moteur dual logiciel actuel comme filet jusqu'à ce que le GPU le remplace. | 2026-07-24 |
| 8 | **Journal caméra à retirer avant la prod** | `CamLog.kt` écrit une trace détaillée sur le disque de l'appareil + écran « Journal caméra » dans Réglages → Développeur. Outil de diagnostic : à retirer avec la section Développeur (voir ligne 4). | 2026-07-14 |
| 5 | **`contentType` d'upload** | Les fichiers sont des PNG mais uploadés en `image/jpeg`. Sans effet visible, à nettoyer. | 2026-07-12 |
| 7 | **FPS double live — levier n°2 (rendu)** | Le levier n°1 (forçage de la plage capteur `CONTROL_AE_TARGET_FPS_RANGE`) est fait en v0.9.x. **Si insuffisant après mesure de Jay** : alléger le rendu logiciel — n'afficher qu'UNE face (saut du dessin de la face cachée côté natif, `renderEnabled` par caméra), la face cachée restant vivante pour la capture simultanée ; éventuellement supprimer l'aller-retour JPEG du pipeline de dessin. Ne pas égaler le natif (rendu GPU inaccessible en flux unique) est assumé. | 2026-07-24 |

## Bugs connus, à corriger

| # | Sujet | Détail | Depuis |
|---|-------|--------|--------|
| 1 | ~~**Changement de mode pendant la prise**~~ **CORRIGÉ en v0.9.1** | Jay avait pu créer une **Mono à deux faces** en changeant de mode pendant le traitement d'une capture Oneshot. Corrigé par trois barrières : type figé au déclenchement (`_lockedType`), sélecteur inerte et grisé pendant la prise, et vérification de cohérence faces/type avant le récap. Capture accélérée dans la foulée (écriture des deux faces en parallèle + un seul encodage ; recadrage/mise au format en natif au lieu d'un encodage PNG en Dart). **À revérifier au test** : durées affichées dans le journal caméra. | 2026-07-14 |

## Décisions verrouillées à ne PAS reproposer

- **Pression du doigt** comme déclencheur vidéo : **abandonnée** (2026-07-13).
  L'appui maintenu suffit.
- **Streaming zéro-écriture** pour l'éphémère : évalué et rejeté (MVP).
