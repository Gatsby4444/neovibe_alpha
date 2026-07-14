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

## Chantiers promis, à ne pas oublier

| # | Sujet | Détail | Depuis |
|---|-------|--------|--------|
| 1 | **Streaks de proximité** | Chantier dédié. La fondation est posée (certificats de croisement co-signés, 10 s de contact continu) : paliers de couleur + dégradation progressive restent à faire. | 2026-07-13 |
| 2 | **Stories** | Format à part ; les cards pourront être mises en story. Emplacement déjà réservé en haut du hub Cercle. | 2026-07-12 |
| 3 | **Wi-Fi Direct pour les cards en conversation ping** | Le chat ping est en BLE (texte et petits paquets). L'envoi de cards/médias dans les conversations éphémères passera par Wi-Fi Direct. | 2026-07-13 |
| 4 | **Vignettes des grilles (bibliothèque / enregistrements)** | Elles passent encore par le réseau : seul le viewer utilise le cache local. À câbler sur le cache. | 2026-07-13 |
| 6 | **Double flux Oneshot — VALIDÉ (v0.9.0), reste la vidéo double** | Le double live FONCTIONNE sur le Redmi Note 10 Pro : 1 flux par caméra, rendu logiciel, capture simultanée. Reste **opt-in développeur** (le bouton « Double live » n'apparaît que si l'option est active). **La vidéo double simultanée reste à faire** (deux encodeurs). Ne JAMAIS revenir à : 2 flux par caméra (frontale affamée), reconfiguration de session pendant que l'autre caméra tourne, sonde de configurations à l'usage (casse le service caméra). | 2026-07-14 |
| 8 | **Journal caméra à retirer avant la prod** | `CamLog.kt` écrit une trace détaillée sur le disque de l'appareil + écran « Journal caméra » dans Réglages → Développeur. Outil de diagnostic : à retirer avec la section Développeur (voir ligne 4). | 2026-07-14 |
| 5 | **`contentType` d'upload** | Les fichiers sont des PNG mais uploadés en `image/jpeg`. Sans effet visible, à nettoyer. | 2026-07-12 |

## Bugs connus, à corriger

| # | Sujet | Détail | Depuis |
|---|-------|--------|--------|
| 1 | **Changement de mode pendant la prise Oneshot** | Retour de Jay (v0.9.0) : la capture Oneshot est **longue** (temps de prise + chargement), et **pendant ce chargement le sélecteur de type reste actionnable** → Jay a changé de mode et l'app lui a affiché l'aperçu/récap **en One of One** alors que la prise était un Oneshot. Deux choses à corriger : (a) **verrouiller le sélecteur de type dès le déclenchement** et jusqu'à la fin du traitement (le type d'une card est figé à la prise) ; (b) **réduire le temps de traitement** de la capture Oneshot (recadrage 9:16 + normalisation 900×1600 des deux faces, en série sur l'isolate principal — à mesurer, puis paralléliser ou passer en `compute`). | 2026-07-14 |

## Décisions verrouillées à ne PAS reproposer

- **Pression du doigt** comme déclencheur vidéo : **abandonnée** (2026-07-13).
  L'appui maintenu suffit.
- **Streaming zéro-écriture** pour l'éphémère : évalué et rejeté (MVP).
