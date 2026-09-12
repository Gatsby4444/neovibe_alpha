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
