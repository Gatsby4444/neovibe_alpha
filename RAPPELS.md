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
| 6 | **Double flux Oneshot (Camera2 brut) instable** | Le matériel de Jay (Redmi Note 10 Pro) accepte le double flux (sonde OK), mais le moteur `Camera2Dual` affichait du noir + crashait. Crash corrigé en v0.8.3 (API Flutter appelées hors du thread principal). Reste **opt-in développeur** (défaut OFF), Oneshot par défaut = mode simple. Le **journal caméra** (Réglages → Développeur) tranchera : éviction matérielle ou problème de rendu. **Vidéo double simultanée** encore à faire. Si le matériel évince : fermer le chantier (BeReal lui-même capture les deux faces séquentiellement). | 2026-07-14 |
| 8 | **Journal caméra à retirer avant la prod** | `CamLog.kt` écrit une trace détaillée sur le disque de l'appareil + écran « Journal caméra » dans Réglages → Développeur. Outil de diagnostic : à retirer avec la section Développeur (voir ligne 4). | 2026-07-14 |
| 5 | **`contentType` d'upload** | Les fichiers sont des PNG mais uploadés en `image/jpeg`. Sans effet visible, à nettoyer. | 2026-07-12 |

## Décisions verrouillées à ne PAS reproposer

- **Pression du doigt** comme déclencheur vidéo : **abandonnée** (2026-07-13).
  L'appui maintenu suffit.
- **Streaming zéro-écriture** pour l'éphémère : évalué et rejeté (MVP).
