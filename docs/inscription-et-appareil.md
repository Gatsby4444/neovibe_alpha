# L'inscription et le téléphone — comment c'est construit

> Construit le **2026-09-24** (v0.9.254). Jay : *« ok [pour couper la
> confirmation du mail] mais on ajoute une sécurité sur l'appareil en lui-même
> pour identifier l'appareil et l'empêcher de spammer la création de
> comptes »*. Plafond validé : **3 comptes par téléphone sur 30 jours**.
>
> ⚠️ Ce document dit où regarder ; la vérité est en base
> (`private.signup_rules`) et dans la migration
> `20260924100000_un_telephone_un_plafond_de_comptes.sql`.

---

## 1. En une image

Le videur ne demande plus d'aller chercher une lettre chez soi (le mail de
confirmation) : il regarde le **téléphone**, et il tient un carnet. Un même
téléphone qui revient pour la quatrième fois en un mois est refoulé.

## 2. Le chemin

| Étape | Où | Ce qui s'y passe |
|---|---|---|
| lire l'identifiant du téléphone | `NativeDeviceIdentity.kt` (canal `neovibe/device`, `androidId`) | `ANDROID_ID` : propre à l'app, survit à la réinstallation, change à la remise à zéro d'usine |
| en faire une empreinte | `lib/core/device_identity.dart` | SHA-256 de `neovibe-device-v1:` + l'identifiant. La valeur brute ne quitte jamais le téléphone |
| l'envoyer à l'inscription | `lib/features/auth/auth_repository.dart` | `signUp(data: {device_hash})` |
| décider | `public.hook_before_user_created` (hook d'authentification Supabase) | pas d'empreinte → *« Mets NeoVibe à jour »* (400) ; plafond atteint → *« Ce téléphone a déjà créé trop de comptes récemment. »* (429) ; téléphone exempté → accepté |
| retenir | trigger `record_device_signup` sur `auth.users` → `private.device_signups` | une ligne par compte créé avec une empreinte |

**Réglages serveur** (API de gestion, `config/auth`) :
`hook_before_user_created_enabled = true`,
`hook_before_user_created_uri = pg-functions://postgres/public/hook_before_user_created`,
`mailer_autoconfirm = true` — activés **ensemble**, pour que l'inscription ne
soit jamais ouverte sans la vérification.

## 3. Les règles, et pourquoi

- **On compte des créations, pas des comptes existants.** `device_signups`
  n'a pas de clé étrangère vers `auth.users` : supprimer un compte ne rend pas
  sa place au téléphone (sinon « créer, supprimer, recréer » contournerait le
  plafond). Vérifié le 2026-09-24 : après suppression des comptes de test, le
  registre comptait toujours leurs lignes.
- **On ne compte pas dans `raw_user_meta_data`** : l'utilisateur peut modifier
  cette colonne lui-même. Le trigger recopie l'empreinte à la création, dans
  une table que personne d'autre n'écrit.
- **Le plafond est une ligne** : `private.signup_rules` (`max_accounts`,
  `per_window`). Le changer ne demande aucun code.
- **Les exemptions sont des lignes** : `private.signup_device_exempt`
  (`device_hash`, `note`). Pour exempter un téléphone de Jay : lire son
  empreinte dans `private.device_signups` après une inscription, et l'y
  ajouter.
- **Les figurants et bots de test** sont insérés directement en SQL : ils ne
  passent ni par le hook ni par le registre (pas d'empreinte).

## 4. Ce qui a été vérifié, sur le vrai serveur (2026-09-24)

Inscriptions réelles par `/auth/v1/signup` avec une empreinte de test :
sans empreinte → 400 ; comptes 1, 2, 3 → acceptés, **session ouverte tout de
suite** (plus de mail à confirmer) ; compte 4 → 429 ; empreinte exemptée →
compte 5 accepté. Comptes et lignes de test supprimés ensuite.

## 5. Limites, dites

- 🔴 **Une app modifiée peut envoyer une fausse empreinte**, ou une nouvelle à
  chaque fois. « Coûteux et visible, pas impossible ». Le niveau au-dessus est
  **Play Integrity** (Google certifie que l'app et le téléphone sont
  authentiques) — il suppose l'app publiée sur le Play Store (RAPPELS #166).
- Deux inscriptions **au même instant** depuis le même téléphone peuvent
  passer toutes les deux (le compte est lu avant la création). Accepté : ça
  donne un compte de plus, pas une rafale.
- Les versions de l'app **antérieures à 0.9.254** ne peuvent plus créer de
  compte (pas d'empreinte) : elles affichent *« Mets NeoVibe à jour »*. La
  connexion à un compte existant n'est pas touchée.
- iOS : pas d'`ANDROID_ID` ; l'équivalent est `identifierForVendor`, qui
  **change** à la désinstallation de toutes les apps de l'éditeur — plus faible.
  Voir `docs/parties-natives-par-os.md`.
