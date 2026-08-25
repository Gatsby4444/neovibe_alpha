# Checkup — dissociation ACQUISITION / USAGE

*Demandé par Jay le 2026-08-20 (`RAPPELS.md` #52), réalisé le 2026-08-25.*

> « Une même donnée peut servir à plusieurs fonctions, modules, outils. Modifier
> un outil ou une fonction ne doit pas entraîner la modification du système de
> récupération des données — sinon on casse d'autres fonctions qu'on ne
> souhaitait pas modifier, mais qui cassent puisque la source de leurs données a
> changé d'une manière ou d'une autre. » — Jay, 2026-08-25

**Question de contrôle**, appliquée partout : *si j'ajoute un champ à cet écran,
dois-je toucher au code qui parle à la radio, au réseau ou au disque ?*

---

## 0. Avertissement de méthode — l'instrument avant la mesure

Ce checkup a produit **deux fausses réussites avant de produire un seul chiffre
juste**. Elles sont consignées ici parce qu'elles valent plus que le résultat :

1. **Un délai nul ne fait pas traverser un `StreamController`.** Le premier
   compteur affichait `0 notification` — non parce que rien ne notifiait, mais
   parce que **rien n'était encore arrivé**.
2. **Un flux `broadcast` ne rejoue pas ce qui a précédé l'abonné.** Un provider
   Riverpod est paresseux : il ne s'abonne qu'au premier lecteur. La première
   émission se perdait, et le compteur mesurait la deuxième en croyant mesurer
   la première.

Dans les deux cas, **un zéro ressemblait à une réussite**. D'où la règle posée
dans le fichier de test : *avant de compter, prouver que la source est arrivée*
(`_sourceArrivee`). Sans quoi l'instrument ne peut pas contenir la preuve du
contraire.

---

## 1. Le chiffre d'ensemble

Périmètre : **160 fichiers Dart, 40 419 lignes**.

| Mesure | Relevé | Lecture |
|---|---|---|
| `ref.watch` dans le code | **192** | |
| … dont `.select(…)` | **2** (1 %) | et **les deux sont dans le fichier de référence** `presence_feed.dart` |
| Appels Supabase | **128**, dans **25 fichiers** | |
| **Écrans contenant de l'acquisition** | **12** | Supabase, disque ou canal natif écrits directement dans un `_screen.dart` |
| Providers dérivés refabriquant une collection | **10** | en Dart l'égalité d'une `List` est **l'identité** : chaque recalcul notifie |
| Providers dont la valeur dépend de `DateTime.now()` | **5** | valeur périmable qui **ne se réévalue jamais seule** |
| Flux temps réel Supabase | **5**, dont **1 sans aucun filtre** | |
| `Timer.periodic` | **12** | |

**La lecture d'ensemble** : la technique d'abonnement fin (`select`) existe dans
le projet, elle est documentée, elle est testée — et elle n'est employée
**nulle part ailleurs** que là où elle a été inventée. Le reste du code observe
des objets entiers.

⚠️ **`.select` absent n'est pas un défaut en soi.** Il ne coûte que si la source
observée change plus souvent que le champ utilisé. Les défauts ci-dessous sont
donc ceux où **la source bouge pour des raisons étrangères au consommateur**.

---

## 2. Défauts mesurés

### D1 — Une connexion partielle qui bouge réveille 7 écrans qui ne s'y intéressent pas

**Mesuré** — `test/dissociation_connections_test.dart`, premier test :

```
attendu 0 notification, obtenu 1
```

`fullConnectionsProvider` (les amis) est notifié alors que **seule une connexion
partielle** a changé. La liste des amis est pourtant identique, champ pour champ.

**Rayon d'impact — 7 consommateurs, dans 6 modules différents :**

| Fichier |
|---|
| `cards/send/circle_settings_screen.dart` |
| `connections/friends_list_screen.dart` |
| `connections/heart_screen.dart` |
| `conversations/create_group_screen.dart` |
| `library/user_library_screen.dart` |
| `recommendations/recommendation_screens.dart` |
| `settings/sections/sharing_settings_screen.dart` |

**Cause** : `fullConnectionsProvider` et `partialConnectionsProvider` sont deux
vues du **même** flux non filtré (`connections`, sans `.eq()`), et chacune
refabrique une `List` à chaque passage. Deux listes au contenu identique ne sont
pas égales en Dart — donc Riverpod notifie, toujours.

**C'est exactement la phrase de Jay** : la source de données est commune, et ce
qui bouge dans une branche casse le silence de l'autre.

**Correctif** : donner à ces deux vues une **égalité de valeur** (comme
`PeerView`), ou les dériver par `select` sur la seule part qui les concerne. La
couche d'acquisition ne doit pas décider qui se redessine.

---

### D2 — Deux émissions identiques réveillent quand même

**Mesuré** — même fichier, deuxième test :

```
attendu 0 notification, obtenu 1
```

Le flux réémet **la même chose** (cas courant : une colonne sans rapport change
en base, ou le socle temps réel se réabonne — ce qui arrive à chaque
renouvellement de jeton, `realtimeEpochProvider`). L'affichage est identique,
les abonnés se reconstruisent quand même.

---

### D3 — Une valeur périmable qui ne se réévalue jamais seule

**Mesuré** — même fichier, troisième test :

```
attendu : liste vide après expiration
obtenu  : [Instance of 'Connection']
```

`partialConnectionsProvider` filtre sur `partialExpiresAt.isAfter(DateTime.now())`,
mais un provider **ne se recalcule que si sa source change**. Une connexion
partielle expirée reste donc affichée **tant que personne n'écrit dans la
table**.

⚠️ **Ce défaut a déjà été rencontré et corrigé ailleurs.** Le 2026-07-13, Jay
signalait la même chose sur les messages (« disparition buggée ») ; la correction
posée alors est un `Timer.periodic(10 s)` dans
`conversations_repository.dart:85`. **Elle n'a jamais été portée ici.**

**Les cinq providers concernés :**

| Provider | Fichier |
|---|---|
| `contentFaceProvider` | `core/content/content_face.dart:61` |
| `currentHourProvider` | `core/day_cycle_clock.dart:27` |
| `partialConnectionsProvider` | `features/connections/connections_repository.dart:45` |
| `wavesProvider` | `features/connections/heart_screen.dart:21` |
| `_visibleStoriesProvider` | `features/stories/stories_repository.dart:26` |

---

### D4 — Le correctif du 2026-07-13 est lui-même un défaut de dissociation

`messagesStreamProvider` (`conversations_repository.dart:54`) rejoue son filtre
d'expiration **toutes les 10 secondes**, en réémettant une nouvelle `List`.

**Par construction** (arithmétique, pas mesure sur appareil) : **6 notifications
par minute, 360 par heure**, chat ouvert et **totalement inactif**. Le seul
consommateur est `chat_screen.dart` — **1 311 lignes, 17 `ref.watch`, aucun
`select`**.

Le problème n'est pas la minuterie : c'est qu'elle vit dans la couche
d'**acquisition**. Celle-ci décide de la **visibilité** (ce qui est expiré) et
impose son **rythme** à tous ses lecteurs. Un futur second consommateur du même
flux héritera des 6 réveils par minute sans l'avoir demandé.

**Correctif** : l'acquisition publie les messages tels qu'ils sont ; la
**péremption est une décision d'affichage**, elle appartient au consommateur —
qui a une horloge et sait ce qu'il montre.

---

### D5 — Une chaîne d'amplification entre deux modules sans rapport

Statique, dérivé de D1 :

```
une connexion PARTIELLE change
  └─> fullConnectionsProvider notifie          (mesuré : 1)
        ├─> friendStoriesProvider   recalculé  → bandeau du Cercle redessiné
        └─> crossedStoriesProvider  recalculé  → bandeau du Ping redessiné
```

`stories_repository.dart:73` et `:96` observent `fullConnectionsProvider` en
entier pour n'en tirer qu'un `Set` d'identifiants. Une personne croisée dans la
rue — donc une connexion **partielle**, sans le moindre rapport avec les stories
de mes amis — fait recalculer les deux bandeaux de stories.

*Vérifié : le cache de `_visibleStoriesProvider` tient, il n'y a donc **pas** de
nouvelle requête réseau. Le coût est en recalcul et en redessin, pas en octets.*

---

### D6 — Douze écrans contiennent leur propre acquisition

C'est le défaut le plus direct au regard de la question de contrôle : ici,
ajouter un champ à l'écran **oblige** à toucher au code qui parle au réseau ou
au disque, puisque c'est le même fichier.

| Écran | Supabase | Disque |
|---|---|---|
| `conversations/chat_screen.dart` | 3 | — |
| `cards/saved_items_screen.dart` | — | 3 |
| `cards/card_capture_screen.dart` | — | 3 |
| `connections/heart_screen.dart` | 2 | — |
| `settings/sections/day_cycle_preview_screen.dart` | — | 2 |
| `settings/sections/privacy_settings_screen.dart` | 1 | — |
| `library/profile_edit_screen.dart` | 1 | — |
| `auth/onboarding_screen.dart` | 1 | — |
| `profile/avatar_cropper_screen.dart` | — | 1 |
| `library/profile_screen.dart` | — | 1 |
| `cards/gallery_import_screen.dart` | — | 1 |
| `cards/face_editor_screen.dart` | — | 1 |

`chat_screen.dart` cumule le pire : **3 requêtes Supabase écrites dans le
fichier de l'écran**, dont deux dans des providers privés (`_mediaUrlProvider`,
`_cardProvider`) que **rien d'autre ne peut réutiliser** — alors que
`cards_repository` sait déjà faire la même chose.

---

## 3. Ce qui est déjà juste — et qui sert de modèle

- **`features/proximity/presence_feed.dart`** — la référence. Trois objets, trois
  rythmes, l'égalité de `PeerView` **est** la règle de redessin. Vérifié : la
  chaîne `presence → keys → nearbyUserIds → isNearby` traverse trois `select` et
  ne réveille une tuile que si **cette** tuile change.
- **`core/content/content_face.dart`** — tous les `ref.watch` avant le premier
  `await`, avec la panne du 2026-08-11 citée en commentaire. La discipline est
  là ; c'est le `DateTime.now()` interne qui est à revoir (D3).
- **Les dépôts** — 128 appels Supabase pour 25 fichiers, et l'écrasante majorité
  est bien rangée dans un `*_repository.dart`. La structure existe ; ce sont les
  12 écrans de D6 qui la contournent.

---

## 4. Ordre de traitement proposé

| # | Quoi | Pourquoi d'abord | Ampleur |
|---|---|---|---|
| 1 | **D1 + D2 + D3 — les connexions** | 7 écrans en dépendent, c'est mesuré, et le correctif est le patron à reproduire | petite |
| 2 | **D4 — sortir la péremption de l'acquisition** | 360 réveils/heure à l'arrêt, sur le plus gros écran du projet | petite |
| 3 | **D5 — les stories ne lisent que les identifiants d'amis** | tombe presque tout seul une fois D1 fait | petite |
| 4 | **D3 — les quatre autres providers périmables** | même défaut, quatre endroits | moyenne |
| 5 | **D6 — rapatrier l'acquisition des 12 écrans** | c'est le plus gros, et le moins urgent : ça ne coûte rien à l'exécution, ça coûte à la modification | grande |

⚠️ **Le point 5 est aussi le prérequis de la couche d'abstraction Supabase**
(`RAPPELS.md` #12), elle-même prérequis d'une éventuelle sortie de Supabase.
Tant que 12 écrans parlent directement au réseau, cette couche ne peut pas être
étanche.

---

## 5. La preuve exécutable

`test/dissociation_connections_test.dart` — **3 tests, qui ÉCHOUENT
volontairement**. Ils ne vérifient pas que l'écran affiche la bonne chose : il
l'affiche. Ils **comptent les reconstructions**.

C'est la seule façon de voir ce défaut. Il ne lève aucune erreur, les 188 autres
tests passent, et l'application se comporte correctement — elle coûte simplement
plus qu'elle ne devrait, et elle est plus dure à modifier qu'elle ne devrait.
