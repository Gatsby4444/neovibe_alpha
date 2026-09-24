# L'arrivée en soirée — l'inscription de NeoVibe

> Construite le **2026-09-24** (v0.9.257). Née comme interface de test
> (v0.9.253), validée par Jay le même jour : *« l'UI de test est validée, on
> l'implémente »*. Ce document décrit ce qui existe ; la vérité est dans
> `lib/features/arrival/`.

---

## 1. En une image

Quelqu'un est devant le bar, on lui dit « télécharge NeoVibe ». Il voit une
lumière (le rond), donne son prénom, se prend en selfie **dans** le rond,
crée son compte sans aller dans ses mails, dit trois « oui », et le radar
cherche la soirée où il est.

## 2. Les étapes

| # | Étape | Ce qui s'écrit (mode réel) |
|---|---|---|
| 0 | L'accroche — « J'entre » ou « J'ai déjà un compte » (→ `AuthScreen`, connexion seule) | rien |
| 1 | Le prénom | rien (gardé en mémoire) |
| 2 | Le selfie, **obligatoire**, caméra frontale dans le rond | rien — sauf si l'on est déjà connecté : le profil se crée à « Je garde » |
| 3 | Le compte (mail + mot de passe) — sauté si l'on est déjà connecté | **le compte** (avec l'empreinte du téléphone, `docs/inscription-et-appareil.md`), puis **le profil** (le prénom) et **la photo** (le selfie en carré 512 px : photo de profil temporaire) |
| 4 | Les autorisations : position précise, appareils à proximité, notifications | les vraies demandes Android |
| → | Fin : l'accueil, et **le vrai radar** (`EventFinderScreen`) par-dessus | — |

## 3. Deux modes, deux mémoires

`ArrivalMode.test` (Développeur › Outils, n'écrit rien, radar et soirée
simulés) et `ArrivalMode.real` (l'inscription). **Chaque mode a sa propre
mémoire** : `arrivalFlowProvider(mode)`. Un test lancé depuis les réglages ne
peut pas toucher une inscription.

## 4. Le branchement dans `RootGate` (`app.dart`)

- pas de compte → `ArrivalScreen(mode: real)` (l'accroche) ;
- un compte sans profil → le même écran, qui reprend **au prénom** ;
- **une inscription en cours garde la main** (`ArrivalState.active`) : le
  compte puis le profil apparaissent pendant le parcours, et sans cette règle
  l'app partirait vers l'accueil avant les autorisations ;
- à la fin, `arrivalWantsFinderProvider` fait ouvrir le radar une seule fois.

`OnboardingScreen` (l'ancien écran « Ton profil ») est **supprimé** : son seul
appelant était `RootGate`. L'inscription n'est plus dans `AuthScreen`.

## 5. Ce qu'il faut savoir

- 🔴 **Le nom affiché est UNIQUE dans NeoVibe** (index
  `profiles_username_unique` sur `lower(display_name)`, relevé le
  2026-09-24). Avec un prénom, ce sera fréquent. Le parcours renvoie alors
  au prénom avec un message (« ajoute l'initiale de ton nom »), compte et
  selfie conservés. **Décision produit à prendre par Jay** (RAPPELS #167) :
  garder un nom unique, ou séparer prénom affiché (libre) et identifiant
  unique.
- Retour arrière : jamais en deçà de ce qui est écrit (après le compte, on ne
  revient ni au compte ni au selfie). À l'accroche, « retour » quitte l'app.
- Le selfie est un fichier temporaire de la caméra, effacé à la fin.
