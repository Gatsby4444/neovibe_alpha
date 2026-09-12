# La plateforme d'inscription des établissements — le contrat

> Jay, 2026-09-12 : *« pour les bars et gros événements publics, vu que ce
> n'est pas les mêmes organisations et les mêmes règles, je propose une
> plateforme d'inscription dédiée qui permettra aux établissements de gérer
> l'événement, des horaires d'ouverture aux mini-jeux et à la gestion des
> fonctionnalités et des participants. »*
>
> **La plateforme elle-même (le site web du commerçant) n'est pas construite.**
> Ce document fixe ce qu'elle appellera : le serveur est prêt, et testable
> sans elle.

---

## 1. Les objets

| Table | Ce que c'est |
|---|---|
| `venues` | un établissement : nom, adresse, position, **rayon** dans lequel on est « chez lui » (60 m par défaut) |
| `venue_managers` | qui gère quel établissement — un compte NeoVibe ordinaire, pour l'instant |
| `events` (kind = `venue`) | une soirée de cet établissement : titre, ouverture, **horaire de fermeture obligatoire** |

Un établissement **se voit par tout le monde** (c'est ce qui permet « autour
de moi ») ; il ne s'écrit que par RPC, par un gérant.

## 2. Les appels — tous en `rpc`, sous l'identité du gérant

| Appel | Qui | Effet |
|---|---|---|
| `create_venue(p_name, p_lat, p_lon, p_radius_m, p_address)` | n'importe qui | crée le lieu, et fait de l'appelant son gérant |
| `open_venue_event(p_venue, p_title, p_closes_at, p_starts_at)` | un gérant | ouvre une soirée : elle apparaît « autour de moi » dès `p_starts_at`, se ferme seule à `p_closes_at` |
| `update_event_settings(p_event, p_title, p_ends_at, …)` | un gérant | renomme, change l'horaire de fermeture |
| `close_event(p_event)` | un gérant | ferme tout de suite |
| `event_people(p_event)` | un gérant (il est « concerné ») | la liste des présents |
| `event_hot_spots(p_event)` | idem | où sont les gens, par case |
| `my_events()` | un gérant | ses soirées, ouvertes et fermées (`i_manage = true`) |

Ce qui manque pour le commerçant et qu'il faudra décider avec Jay : ajouter
un gérant, les mini-jeux et leur réglage, la fiche activité et la réservation
(question 12 du §12 de `docs/vision-produit.md`).

## 3. Tester sans plateforme — base de dev

`tool/ouvrir_une_soiree.sql` : à coller dans l'éditeur SQL du projet de dev
(ou à passer par le PAT). Il crée un lieu **à la position donnée**, en fait un
gérant du compte donné, et ouvre une soirée pour quelques heures. Ensuite,
dans l'app : Cercle → 🎉 → « Autour de moi » → « Je suis là ».

⚠️ Il faut être **physiquement** à moins de `radius_m` + 100 m du lieu déclaré
pour entrer : mettre la position du lieu à l'endroit où l'on teste.
