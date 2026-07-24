# Stratégie multiplateforme de NeoVibe

> Décidé avec Jay le 2026-07-24. Ce document fige **comment** NeoVibe est
> construit pour tourner à terme sur Android ET iOS, et **pourquoi**. À lire
> avant toute décision touchant l'architecture ou une fonction matérielle.
> Le détail des morceaux natifs à écrire par OS est dans
> [`parties-natives-par-os.md`](parties-natives-par-os.md).

---

## Le principe : un seul codebase Flutter + des modules natifs par OS

NeoVibe est **une seule application Flutter/Dart**. La très grande majorité du
code est **partagée** entre les plateformes. Seules les fonctions **matérielles**
sont écrites en natif, **derrière des « ponts » (platform channels)** dont le
contrat (les méthodes appelées côté Dart) est identique sur tous les OS. Seule
l'**implémentation** derrière le pont change d'un OS à l'autre.

**On ne forke JAMAIS en deux codebases séparées.** « Supporter iOS » = écrire
l'implémentation iOS des ponts existants, pas réécrire l'app.

### Ce qui est PARTAGÉ (Dart/Flutter, écrit une fois)
- Toute l'**interface** et la navigation.
- L'**état** (Riverpod), la logique produit, les cards, l'éphémère.
- Le **backend** (Supabase : auth, données, storage, edge functions).
- Les **pilotes Dart** des fonctions natives (ex. `NativeCameraController`,
  et le flux de capture) : ils parlent à un canal, pas au matériel.

### Ce qui est NATIF, à réécrire par OS
- Le **moteur caméra** (aperçu, double flux, photo, vidéo).
- La **proximité** : BLE (détection + échange) et Wi-Fi Direct (transfert média).
- L'**anti-capture** (FLAG_SECURE et équivalents).

Voir le détail exhaustif dans [`parties-natives-par-os.md`](parties-natives-par-os.md).

---

## Pourquoi c'est comme ça (et pourquoi c'est normal)

NeoVibe est une app **matérielle** : sa thèse même (la présence physique) repose
sur la caméra, la proximité et l'anti-capture — précisément les fonctions les
plus liées à l'OS. Une app de ce type profite **moins** de la promesse « un seul
code » de Flutter qu'une app de contenu : les parties dures sont natives par OS,
quoi qu'on fasse.

**Cela ne remet PAS en cause le choix de Flutter.** Flutter fait gagner
énormément sur l'UI et la logique (la majorité du volume). Et le natif était
inévitable de toute façon : **aucun plugin cross-platform ne gère le double flux
caméra concurrent** — il fallait descendre au natif.

**Nuance importante « natif » ≠ « Camera2 brut ».** Le rendu GPU et l'accès
caméra sont deux choses distinctes ; on n'utilise Camera2 brut (Android) que pour
la SEULE chose que CameraX refuse : ouvrir deux caméras à la fois. Pour tout le
reste, on utilise l'outil le plus robuste de la plateforme (CameraX sur Android).
Détail dans [`systeme-camera-explique.md`](systeme-camera-explique.md).

---

## Feuille de route plateforme

1. **Maintenant → Android d'abord.** On développe et on valide tout le produit
   sur Android. On choisit **les meilleures options pour Android**, Dart ou
   natif, sans se brider « pour rester portable ».
2. **Discipline à tenir dès aujourd'hui** (coûte quasi rien, économise des
   semaines) : garder les **interfaces Dart↔natif propres et neutres** — le
   côté Dart ne suppose aucun « Android-isme ». Ainsi iOS sera **additif**.
3. **iOS plus tard, sur décision de Jay**, une fois le développement Android
   terminé. On implémentera alors le côté iOS des ponts (voir catalogue).

---

## Fiabilité de la fonctionnalité dual-cam (rappel important)

Le double flux **vrai** dépend du **matériel** : certains téléphones en sont
capables, d'autres non — limite physique, pas de notre code. « Fiable pour tout
le monde » ne veut donc pas dire « dual fluide sur 100 % des appareils » (impos-
sible), mais **« le Oneshot marche bien pour 100 % des utilisateurs »**, via :

- **appareils capables** → double flux GPU fluide ;
- **appareils incapables** → **repli automatique** sur capture séquentielle
  rapide (une caméra, deux prises d'affilée) rendue instantanée — universel.

Avant toute mise en production : **repli universel** en place ET **test
multi-appareils** (Firebase Test Lab / bêta-testeurs variés), car on ne valide
aujourd'hui que sur un seul appareil (Redmi Note 10 Pro). Consigné dans
`RAPPELS.md`.
