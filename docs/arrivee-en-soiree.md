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
| 1 | Le **username** (obligatoire, unique, 3-20, `a-z 0-9 . _`) et un **pseudo** facultatif (1-30) | rien (gardé en mémoire) |
| 2 | Le selfie, **obligatoire**, caméra frontale dans le rond | rien — sauf si l'on est déjà connecté : le profil se crée à « Je garde » |
| 3 | Le compte (mail + mot de passe) — sauté si l'on est déjà connecté | **le compte** (avec l'empreinte du téléphone, `docs/inscription-et-appareil.md`), puis **le profil** (username + pseudo) et **la photo** (le selfie en carré 512 px : photo de profil temporaire) |
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

- ✅ **Username unique, pseudo libre — tranché par Jay le 2026-09-24**
  (RAPPELS #167). Le username est pris ? Le parcours revient à l'étape du
  username avec une proposition, compte et selfie conservés. Règles et
  affichage : §6.
- Retour arrière : jamais en deçà de ce qui est écrit (après le compte, on ne
  revient ni au compte ni au selfie). À l'accroche, « retour » quitte l'app.
- Le selfie est un fichier temporaire de la caméra, effacé à la fin.

## 6. Username et pseudo (2026-09-24, v0.9.258)

Jay : *« un username unique ; un pseudo optionnel ; le pseudo est affiché s'il
y en a un, sinon le username ; on peut paramétrer si l'on veut que dans les
groupes et pour les autres ce soit notre pseudo ou notre username ; pour les
publications, c'est le username. »*

| | Username (`profiles.display_name`) | Pseudo (`profiles.tag_name`) |
|---|---|---|
| obligatoire | oui | non |
| unique | oui (`profiles_username_unique`, sur le minuscule) | non |
| format | `^[a-z0-9._]{3,20}$` (`profiles_display_name_check`) | 1 à 30 caractères (`profiles_tag_name_check`) |
| où il s'affiche | **toujours** sur les publications : Vibes, stories, profil, Drop | aux autres et dans les groupes, s'il existe et si `show_pseudo` |

**Le réglage** : Paramètres › Sécurité et confidentialité › « Montrer mon
pseudo » (`profiles.show_pseudo`, vrai par défaut).

**Il s'applique à UN endroit** : la colonne calculée `profiles.pseudo_shown`
(le pseudo si son propriétaire le montre, sinon rien). Les cinq fonctions qui
donnent un nom aux autres (`event_people`, `crossed_recently`,
`content_viewers`, `my_meetings`, `ping_nearby`) la rendent sous le nom de
colonne `tag_name` ; l'app la lit dans `Profile.pseudoShown` et le carnet
d'amis (`tag_name:pseudo_shown`). `tag_name` brut ne sert plus qu'à l'édition
du profil et à l'administration.

**Côté app** : `lib/core/username.dart` (règles, conversion de la frappe —
« Camille Martin » → « camille.martin »), `Profile.chatName` (pseudo montré,
sinon username), et `displayName` partout où c'est une publication.

**Migration** : `20260924180000_username_unique_et_pseudo_libre.sql`, puis
`20260924181000_usernames_repares.sql` — la première, appliquée avec un
`rpad` qui coupait les noms longs, avait réduit tous les usernames à trois
lettres ; la seconde les a reconstruits exactement (mails des comptes réels,
formule de `tool/figurants.sql`). Résultat vérifié : 48 usernames au format,
« charles », « testeur », « camille.martin »…
