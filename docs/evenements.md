# Les événements et le mode événement — comment c'est construit

> Construit le **2026-09-12**, le jour même où Jay a cadré la vision
> (`docs/vision-produit.md` §8.4.1 et §8.4.2). Ce document décrit **ce qui
> existe dans le code et en base**, pas ce qui est souhaité ; ce qui n'est pas
> construit est listé à la fin, en clair.
>
> ⚠️ Règle du projet : un fait se vérifie à la source. Ce document dit *où*
> regarder ; la migration `20260912100000_les_evenements_et_les_etats_de_relation.sql`
> et `lib/features/events/` disent *ce qui est vrai*.

---

## 1. Les quatre mots, et l'objet derrière chacun

| Mot (Jay, 2026-09-12) | L'objet | Où il vit |
|---|---|---|
| **Cercle** | l'onglet d'accueil, inchangé ; **la porte** vers les événements (icône 🎉 en haut, bandeau quand on est dans un événement) | `lib/features/circle/circle_screen.dart` |
| **Événement** | ce qui est commun aux deux origines : un titre, un lieu (ou pas), une durée, des présents, un groupe d'événement | table `events` |
| **Mode événement** | la seconde face de l'app ; **n'existe que si je suis dans un événement** | `EventScreen`, `EventBanner` — tous deux lisent `currentEventIdProvider` |
| **Groupe** | l'objet existant (`conversation_type = 'group'`) ; les « cercles par passion » sont des groupes | inchangé |

Et un cinquième objet, que Jay a distingué exprès : le **groupe d'événement**
— *« un groupe avec des fonctionnalités différentes, spécialement conçu pour
l'événement, éphémère »*. C'est une conversation de type **`event`** : même
chat, même bibliothèque éphémère, mais **hors du Cercle**, avec sa propre règle
de reveal, et purgée avec l'événement.

---

## 2. Les deux origines — deux règles d'entrée, deux rangements

| | Événement **privé** | Événement **d'établissement** |
|---|---|---|
| créé par | `create_private_event` — n'importe qui, pour ses amis | `open_venue_event` — un **gérant** d'un lieu (`venue_managers`) |
| le droit d'entrer | être dans `event_group_members` **et** sur place | être sur place |
| qui invite | tout le monde, **admin par défaut** ; le créateur règle `members_can_add` / `members_can_remove` et les rôles | personne — c'est le lieu qui filtre |
| qui peut être invité | **les amis au sens strict** (`are_connected`) — le serveur refuse le reste | — |
| se ferme | **80 % des participants partis** (`event_rules.private_close_ratio`), après 30 min de grâce ; ou le créateur | **l'hôte** (`close_event`) ou **l'horaire** (`scheduled_end_at`) |

Les deux vivent dans `events` parce que **ce qui est commun** (lieu, durée,
présents, conversation, points chauds, fermeture, purge) l'est vraiment. Ce
qui donne le droit d'entrer, lui, ne partage rien : `join_event` branche par
`kind`, et la source de chaque droit est une table différente
(`event_group_members` / `venues`). Règle 2 de `CLAUDE.md`.

---

## 3. La présence — trois étages qui ne se mélangent pas

```
ACQUISITION     event_positions   ← report_event_position (l'app, 1×/min au premier plan)
                event_sightings   ← report_sightings (le BLE, en arrière-plan)
DÉRIVATION      event_hot_spots() ← les cases occupées par des positions fraîches
                event_crossings   ← sightings mutuels, ou présences qui se recouvrent
DÉCISION        join_event / report_event_position (« trop loin » → sorti)
                private.sweep_events() (chaque minute : away, fermetures, purge)
```

**Le système mixte, tel que Jay l'a demandé.** Une présence porte deux dates :
`last_position_at` (la localisation) et `last_ping_at` (le BLE, quand mon
téléphone a *entendu* un co-participant). Sans **aucune** des deux pendant
`away_after` (30 min), on est sorti. Un festival où les gens s'éloignent hors
de portée BLE tient par la position ; un bar où les téléphones restent dans
les poches tient par le ping.

**Les points chauds ne sont jamais stockés.** `event_hot_spots(event)` compte
les présents par case de 50 m (`hot_spot_cell_m`) à partir des dernières
positions, à la demande. Une position ne se lit **que par son propriétaire**
(politique `event_positions_own`) ; les autres ne voient que des nombres par
case. À la sortie et à la fermeture, la position est **effacée**.

**Sorti quand on s'éloigne de tous les points chauds** — pour UNE personne,
les points chauds sont : le lieu déclaré (s'il y en a un) et les positions
fraîches des **autres** présents. Au-delà de `leave_radius_m` (300 m) de
tous, `report_event_position` répond `away` et ferme la présence. Sans lieu
ni autre présent, on n'est jamais loin de rien.

**Un seul événement à la fois** : index unique `event_presences_one_open`
(par utilisateur, présence ouverte). Rejoindre un événement sort du précédent.

---

## 4. Les états de relation — #99, livré

Le carnet de clés (`FriendKeys`) porte désormais un **libellé** :
`KeyRelation.friend` ou `KeyRelation.event`. Il vient du serveur, par la vue
`key_book` (`security_invoker`) qui lit **la même fonction** que la politique
de `device_keys` : `private.relation_kind(me, other)`.

```
'friend'  ← connections.status = 'full'
'event'   ← présents tous les deux dans un événement ouvert,
            ou invités tous les deux à un événement privé non fermé
null      ← personne d'autre, et jamais quelqu'un qui m'a bloqué
```

Ce que ça change, étage par étage :

| Étage | Avant | Après |
|---|---|---|
| `proximity_sync._pullFriendKeys` | lisait `device_keys` | lit `key_book`, garde le libellé |
| `proximity_controller._isFriend` | « est au carnet » | « est au carnet **et** `friend` » — waves, « presque », « tout près » restent entre amis |
| `report_sightings` (envoi) | amis seulement | tout ce que le carnet reconnaît ; **le serveur route** |
| `report_sightings` (serveur) | `sightings` → `encounters` → paliers | amis : inchangé ; co-participants : `event_sightings` → preuve de présence → `event_crossings` si mutuel. **Jamais `meeting_days`** : un inconnu de soirée ne monte pas un palier |
| tuile Ping | anneau de palier + bouton message | relation `event` : photo, nom, « À l'événement · à portée », pas de palier, pas de message |
| veilleur du carnet | relit quand mes amis changent | relit aussi quand les gens de mes événements changent (`eventPeerIdsProvider`) |

---

## 5. Le croisement porte son origine — la fenêtre est un paramètre

| Origine | Table | Fenêtre | Où elle est écrite |
|---|---|---|---|
| **ping** (le bus, la rue) | `ping_pairs` | **3 jours** (Jay) | `crossing_windows` where origin = 'ping' |
| **événement** | `event_crossings` | 3 jours, **défaut provisoire** | `crossing_windows` where origin = 'event' |

`crossed_recently()` unit les deux, chacune avec sa fenêtre, et rend `origin`
et `event_title` — d'où « Croisé(e) à Soirée au Temple » dans l'écran d'envoi.
`request_connection_with_vibe` accepte un croisement des deux origines
(`private.crossing_within_window`). `purge_ping` lit la table.

Changer une fenêtre = un `update` sur `crossing_windows`. Pas de migration,
pas de fonction à réécrire.

---

## 6. La bibliothèque retardée du groupe d'événement

Même mécanique que `docs/bibliotheques-ephemeres.md` (placeholder détruit,
scellé, clé retenue par le serveur), avec **une autre règle de reveal** : tant
que l'événement est ouvert, `reveal_at = private.jamais()` (l'an 9999) ; à la
fermeture, `private.close_event` date le reveal à `closed_at +
library_reveal_delay` (10 h) pour toutes les Vibes de la conversation. L'écran
de bibliothèque affiche « Après l'événement · à la fermeture » en attendant.

Le groupe (chat + bibliothèque) survit **5 jours** (`event_rules.survival`)
après la fermeture, puis `sweep_events` supprime l'événement **et** sa
conversation. Les croisements survivent (leur `event_id` devient nul, le
titre est copié).

---

## 7. Les paramètres — des lignes, pas des constantes

`public.event_rules` (une ligne) :

| Colonne | Valeur | Qui a décidé |
|---|---|---|
| `private_close_ratio` | 0.8 | **Jay** |
| `survival` | 5 jours | **Jay** |
| `private_close_grace` | 30 min | choix du 2026-09-12 |
| `away_after` | 30 min | choix du 2026-09-12 |
| `leave_radius_m` | 300 m | choix du 2026-09-12 |
| `hot_spot_cell_m` | 50 m | choix du 2026-09-12 |
| `nearby_radius_m` | 2 km | choix du 2026-09-12 |
| `crossing_min_overlap` | 30 min | choix du 2026-09-12 — question 6 du §12 |
| `library_reveal_delay` | 10 h | choix du 2026-09-12 |

---

## 8. Le code, côté app

```
lib/core/models/event.dart              NeoEvent, EventPerson, HotSpot, NearbyVenueEvent (tous avec ==)
lib/features/events/
  events_repository.dart                 la cuisine : les RPC, et l'invalidation à l'écriture
  events_providers.dart                  les vues : currentEventId, myEvents, eventById, people, hotSpots, nearby, eventPeerIds
  event_presence_reporter.dart           l'acquisition : ma position, 1×/min au premier plan
  events_screen.dart                     la porte : en cours / mes événements / autour de moi
  create_event_screen.dart               créer un événement privé
  event_screen.dart                      LE MODE ÉVÉNEMENT
  event_settings_screen.dart             les réglages du créateur / du gérant
  event_invite_screen.dart               inviter ses amis
  event_banner.dart                      le bandeau dans le Cercle
```

Tests : `test/events_providers_test.dart` (ce qui se compte),
`test/event_relation_test.dart` (le libellé du lien, de bout en bout).

---

## 9. Ce qui N'EST PAS construit — à lire avant de tester

1. **La plateforme d'inscription des établissements** (le site du commerçant)
   n'existe pas. Le **contrat** existe : `create_venue`, `open_venue_event`,
   `update_event_settings`, `close_event`, table `venue_managers`. Pour
   tester, `tool/ouvrir_une_soiree.sql` crée un lieu et ouvre une soirée en
   base de dev. Voir `docs/plateforme-etablissements.md`.
2. **La position en arrière-plan.** L'app ne dépose sa position que **au
   premier plan** (Android exige un service de premier plan de type
   « location » pour le reste). Entre deux ouvertures, la présence tient par
   le BLE. Consigné dans `RAPPELS.md`.
3. **Les jeux et défis** du mode événement : la place est réservée (bouton
   « Jeux »), le contenu est la question 16 du §12.
4. **Une carte.** Les points chauds s'affichent en nombres, pas sur un plan.
5. **Les notifications** (« Alice est arrivée », « l'événement se ferme »).

---

## 10. Le 2026-09-21 — le scénario de bout en bout (v0.9.239)

Décisions de Jay (`docs/raison-d-entrer-2026-09-21.md` §5). Ce qui est
**construit** ce jour-là, vérifié en base sous identité
(`scratchpad/t_scenario.sql`, annulé par exception) :

| Brique | Ce qui existe |
|---|---|
| **Événement ouvert** (`kind = 'open'`) | `create_open_event(titre, lat, lon, fin, rayon)` : n'importe qui, là où il est, ≤ 24 h ; l'organisateur est admin du groupe et présent d'office. Entrée = **sur place** (la règle d'un établissement). `nearby_events(lat, lon)` remplace `nearby_venue_events` : établissements **et** ouverts, avec `present_count` — « tel événement, N personnes connectées ici » (Jay). Fermeture à l'horaire (`sweep_events`) ou par l'organisateur. App : `EventKind.open`, `NearbyEvent`, l'interrupteur « Ouverte à tous ceux qui sont là » dans `create_event_screen.dart` |
| **Bibliothèque visible PENDANT** | `add_vibe_to_library` : `reveal_at = now()` pour une conversation d'événement ; `close_event` ne date plus rien (`library_reveal_at` = « depuis »). Les Vibes déjà déposées à reveal « jamais » ont été révélées par la migration |
| **La mémoire des rencontres** — `meetings` | Une ligne par personne et par rencontre (`origin` ping / event, `event_id`, `event_title`, lieu **gommé à 100 m**, `met_at`, `last_at`). Écrite par déclencheur quand un `ping_pairs` NAÎT (`on_ping_pair_born`) et quand un `event_crossings` naît à la fermeture (`on_event_crossing_born`) — donc **jamais sans croisement symétrique**. RLS : lecture et suppression de MES lignes seulement. **2 ans** (`crossing_windows.origin = 'meeting'`, Jay), balai `neovibe_purge_meetings` (04:23). RPC `my_meetings()`, `met_before(uuid[])`. App : onglet **Rencontres** du cœur (`meetings_tab.dart`, glisser = oublier), « Déjà rencontré(e) à … » sur les tuiles d'inconnus du Ping (`metBeforeProvider`, une requête par grille) |
| **Le récap** | `event_recap(event)` : présents (passés), Vibes, gens rencontrés là, nouveaux amis depuis le début, amis présents. App : `_Recap` sur l'écran d'un événement fermé, et la galerie |
| **Les moments** (3.7) | `private.form_moments()`, appelée par `sweep_events` chaque minute : deux **amis** (`are_connected`, dit positivement) avec des vues **mutuelles** (`sightings`) sur `moment_min_slots` créneaux consécutifs (2 × 15 min) et sans événement ouvert commun → un événement **privé `auto_created`** s'ouvre (« Moment du 21/09 à 19:10 »), les deux y sont membres admin et présents (preuve = le ping, `last_ping_at` rafraîchi tant qu'ils se voient). Un troisième ami vu par un membre rejoint. Se ferme par les règles existantes (30 min sans preuve → sorti ; 80 % partis → fermé). Vérifié : pas de moment entre non-amis, pas de doublon au passage suivant. Paramètres : `event_rules.moment_enabled / moment_min_slots / moment_min_friends` |
| **Les défis** (premier « jeu ») | `event_challenges` (une phrase, par un **présent** : `post_challenge`), `library_vibes.challenge_id`, `add_vibe_to_library(…, p_challenge_id)`. App : bouton **Défis** de l'événement (`event_challenges_screen.dart`), « Répondre par une Vibe » → la caméra en mode Drop avec `LibraryTarget.challengeId` |
| **La position en arrière-plan** (§0) | `EventPresenceService` (Kotlin, premier plan type **`location`**) démarré depuis l'interface quand je rejoins : une position par minute → `report_event_position` par `SupabaseHttp.rpcText` avec la session du pont de publication ; s'arrête sur `away` / `none` / jeton refusé. **Un seul écrivain** : le Dart (`event_presence_reporter.dart`) ne relève plus rien, il démarre, arrête et écoute (`neovibe/event_presence`). Sans « Autoriser tout le temps » — le type `location` suffit, démarré depuis l'app |
| **Pulse — « Mes soirées »** | Une rangée au-dessus de la galerie : les événements où j'ai été, en cours ou fermés depuis < 5 jours → leur Drop. Le Drop d'un événement est **un autre objet** que les publications du feed : il n'y est pas mêlé, il y est tendu |
| **Ma galerie** (sur le téléphone) | `lib/features/gallery/` : `Moment` + `MomentStore` (`<support>/gallery/moments.json`), `GalleryKeeper` (observe `my_events`, copie titre / quand / où / amis présents / récap ; à la fermeture, **garde dans les Enregistrements** les Vibes du Drop que leur auteur a laissées **sauvegardables**, et les miennes — la règle de sauvegarde existante, telle quelle), `GalleryScreen` / `MomentScreen`. Entrée : Profil › « Ma galerie ». Test : `test/moment_store_test.dart` |

| **La carte** (étape 5, v0.9.240) | `events_map_screen.dart` : les soirées à portée (épingles « nom · N »), ma position, et — pour l'événement où je suis — ses points chauds en cercles. Fond **OpenStreetMap** (`flutter_map` + `latlong2`, `User-Agent` = le paquet). ⚠️ Fond gratuit et limité : pour tester, pas pour la production (RAPPELS #157). Entrées : icône carte de l'écran Événements, puce « Carte » des points chauds |
| **Les notifications** (étape 5) | `event_notifier.dart` : « X est là » (un AMI arrive dans l'événement où je suis — jamais un inconnu, états de relation #99), « … c'est fini » (récap et Drop), « Un moment s'est ouvert ». **Locales, app vivante, hors premier plan seulement** (au premier plan l'écran le montre). Pas de push serveur : app tuée, rien — dit et assumé |

### Ce qui n'est PAS fait (2026-09-21 soir)

- **La plateforme des établissements** : inchangé (§9.1).
- **« Une soirée s'ouvre près de toi »** : exigerait un push serveur (aucun
  FCM) ET la position en continu hors événement (sorti du scope, 3.4).
- **Les micro-contextes d'un festival** (zones, sous-groupes rejoignables) :
  non construits — les points chauds existent en nombres et sur la carte,
  pas comme des sous-événements. Dépend d'une présence fiable à grande
  échelle, à mesurer d'abord (§0).
- **Les Vibes non sauvegardables** du Drop d'un moment ne survivent pas à la
  purge (5 jours) : c'est la règle de sauvegarde existante ; la galerie garde
  l'album (où, quand, avec qui) sans elles. À trancher par Jay si la galerie
  doit garder plus.
- **Le compteur « N connectés ici » n'est vérifié que par ce qui est
  déposé** : position (natif, 1/min) et vues BLE (`report_sightings`). Un
  téléphone sans l'un ni l'autre sort au bout de 30 min.
