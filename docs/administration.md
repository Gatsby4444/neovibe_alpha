# L'administration et la modération — ce qui existe (2026-09-21)

> Jay, 2026-09-21 : *« de manière générale il faudra de la modération sur
> l'app, et on construira toute une plateforme d'administration complète
> avant la première release de production »* (RAPPELS #156). Ce document
> décrit **les fondations construites le jour même** et, sans détour, **ce
> qui manque pour « complète »**.

## En une phrase

Un serveur qui sait qui est administrateur, qui journalise chaque geste,
qui suspend un compte et retire un contenu ; une **console web** dans le
même dépôt, qui ne connaît que ces gestes.

## Le serveur — `supabase/migrations/20260921220000_administration.sql`

| Objet | Ce que c'est |
|---|---|
| `admins` | qui est administrateur. **Aucun client n'y écrit** : on y entre par SQL, à la main. En base de dev, le compte de Jay (« Charles ») y est depuis le 2026-09-21 |
| `private.is_admin(uid)`, `private.assert_admin()` | la question et la porte ; `am_i_admin()` pour la console |
| `moderation_actions` | **le journal** : admin, geste, cible (compte / contenu / événement), signalement lié, motif, date. Lisible par les admins seulement |
| `content_reports.status`, `profile_reports.status` | `open` → `resolved` / `dismissed`, avec `resolved_by` et `resolved_at` |
| `profiles.suspended_at`, `suspended_reason` | la suspension |
| `private.assert_not_suspended()` | **la règle, dite positivement** : une porte qui la cite refuse un compte suspendu |
| `my_suspension()` | ce que l'app lit au démarrage (`SuspendedScreen`) |

### Les portes gardées

Chaque fonction de la liste a été **enveloppée** : l'originale est
renommée `private.unguarded_<nom>`, le nom public appelle
`assert_not_suspended()` puis l'originale. Vérifié sous identité
(`scratchpad/t_admin.sql`) : un compte non suspendu passe, un compte
suspendu reçoit « Ton compte est suspendu ».

`publish_to_library` · `publish_story` · `add_vibe_to_library` ·
`create_open_event` · `create_private_event` · `post_challenge` ·
`add_to_feed`

⚠️ **Toute nouvelle porte qui crée du contenu, une soirée ou une relation
s'ajoute ici ET à la liste du bloc `do $$` de la migration** (une migration
suivante, pas celle-ci). Ce qui n'est PAS gardé aujourd'hui : l'envoi de
messages (`messages` s'écrit par la table, sous RLS — pas de RPC à
envelopper), les demandes d'ami, les likes, les commentaires. Un compte
suspendu peut donc encore écrire dans un chat. À compléter avant la prod
(voir « ce qui manque »).

### Les gestes d'administration (RPC, `security definer`, refusent un non-admin)

| RPC | Geste | Journal |
|---|---|---|
| `admin_stats()` | comptes, suspendus, signalements ouverts, événements en cours, contenus, actions / 24 h | — |
| `admin_reports(status)` | les signalements de contenu et de profil, avec le signaleur, la cible, le contexte du contenu | — |
| `admin_resolve_report(kind, id, dismiss, note)` | traiter / classer sans suite | `resolve_report` / `dismiss_report` |
| `admin_suspend_user(user, reason)` | suspendre (jamais soi-même, jamais un admin) ; sorti de tout événement | `suspend_user` |
| `admin_unsuspend_user(user, note)` | rétablir | `unsuspend_user` |
| `admin_delete_content(content, reason)` | retirer un contenu (`contents` → cascades, tombstones des octets) ; ses signalements ouverts passent à `resolved` | `delete_content` |
| `admin_events()`, `admin_close_event(event, reason)` | les événements en cours ; en fermer un | `close_event` |
| `admin_actions(limit)` | le journal | — |
| `admin_users(query, limit)` | chercher un compte, voir ses signalements et sa suspension | — |

## La console — `lib/admin/`

Un **second point d'entrée** du même dépôt, construit pour le web :

```
flutter build web --target lib/admin/admin_main.dart --release
# → build/web/  (à servir n'importe où : un dossier statique)
flutter run -d chrome --target lib/admin/admin_main.dart   # pour l'essayer
```

Connexion avec un compte NeoVibe (clé publique + mot de passe) ; si le
serveur ne le reconnaît pas comme administrateur, la console dit « ce
compte n'est pas administrateur » et rien d'autre. Quatre onglets :
**Signalements** (ouverts / traités / sans suite ; retirer le contenu,
suspendre, classer), **Comptes** (recherche, suspendre / rétablir),
**Événements** (en cours, fermer), **Journal**. Chaque geste demande un
motif, journalisé. Aucune clé secrète : la console est un client comme un
autre, c'est le serveur qui sait.

`lib/admin/admin_main.dart` (l'entrée), `admin_repository.dart` (les RPC,
et l'invalidation à l'écriture), `admin_app.dart` (les écrans).

## L'app

- `lib/features/auth/suspended_screen.dart` : au démarrage, `my_suspension()`
  ; si suspendu, l'écran « Ton compte est suspendu » avec la date et le
  motif, et « Se déconnecter » — rien d'autre.
- Le signalement et le blocage existaient déjà côté app
  (`core/content/moderation.dart`, `report_sheet.dart`,
  `content_overflow_menu.dart`).

## Ce qui manque pour « complète » — à construire avant la production

1. **Toutes les portes** : messages, demandes d'ami, likes, commentaires,
   waves — soit des RPC enveloppées, soit une politique RLS qui lit
   `suspended_at`. Aujourd'hui un suspendu est muet en publication, pas en
   chat.
2. **La révocation chez les autres** : un contenu retiré disparaît du
   serveur ; les copies locales (Enregistrements) sont révoquées par
   `purgeRevoked` au prochain démarrage de chaque app — vérifier que le
   chemin couvre bien les Vibes de chat et de Drop, pas seulement les
   publications.
3. ✅ **Voir le contenu signalé** — construit le 2026-09-25 (décision de
   Jay : le **scellé sur place**, gardé **jusqu'au traitement**). À la
   naissance d'un signalement, le serveur relève les fichiers visés et
   recopie leur clé dans `moderation_holds` (aucune politique : personne ne
   la lit). Tant qu'il est ouvert, le propriétaire ne peut plus effacer ces
   fichiers, le balai les saute, et un admin les lit (`moderation_read_held`
   + `admin_report_evidence`, journalisé `view_evidence`). Tranché ou
   écarté : libéré, le fichier retourne au balai. **Aucune clé de service
   n'a été nécessaire** : l'admin lit comme un utilisateur, le serveur sait
   qu'il est admin. Console : « Voir la preuve », déchiffrée en mémoire dans
   le navigateur (`lib/core/crypto/sealed_bytes.dart`). Migration
   `20260925120000_le_scelle_de_moderation.sql`.
4. **Les rôles** : un seul niveau (admin). Modérateur / administrateur, et
   qui peut nommer qui.
5. **Les bannissements durables** (suppression de compte, blocage de
   l'appareil ou de l'e-mail), les suspensions à durée.
6. **La traçabilité côté utilisateur** : prévenir le signaleur du sort de
   son signalement ; prévenir le suspendu (aujourd'hui il le découvre à
   l'ouverture).
7. **L'hébergement** de la console (un dossier statique suffit) et son
   accès (au moins une liste d'adresses IP ou un second facteur).
8. **Les établissements** : la plateforme des commerçants
   (`docs/plateforme-etablissements.md`) est un autre produit, avec ses
   propres rôles (`venue_managers`).
