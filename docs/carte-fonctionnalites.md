# La carte — les fonctionnalités voulues par Jay (2026-09-26)

> Liste donnée par Jay le 2026-09-26, après la mise au point de la carte
> Mapbox (v0.9.273 → v0.9.292). Ce document dit ce qui est demandé, ce qui
> existe déjà (vérifié en base et dans le code ce jour-là), et les décisions
> à prendre AVANT de construire. Rien n'est encore construit.

## Ce que Jay a demandé (ses mots)

1. **Voir mes amis et les événements** sur la carte.
2. **Voir la dernière position relevée de mes amis** — réglage
   personnalisable : ne pas montrer ma position, ou la cacher à certains
   amis.
3. **Voir de loin les gros événements** qui rassemblent beaucoup de monde.
4. **Les zones chaudes, comme sur Snap** — cachées pour le moment, mais
   l'intégration est prévue.
5. **Mon rond de position = ma photo de profil** ; ceux de mes amis = leur
   photo de profil.
6. **Les Vibes publiques les plus populaires et les dernières prises
   autour de moi, dans 3 km** — réglage de la carte, désactivable.
7. **Élargir soi-même le rayon des événements visibles, jusqu'à 50 km** —
   réglage de la carte.
8. **Toucher la photo d'un ami** ouvre, avec une animation, une roue de
   petites icônes : **demander sa position actuelle** (notification + une
   demande dans le chat ; il doit accepter pour la révéler), **le
   rejoindre** (le trajet à pied le plus court), **voir son profil**,
   **message direct**.

## Ce qui existe déjà (vérifié le 2026-09-26)

| Besoin | Existant | Écart |
|---|---|---|
| événements sur la carte | épingles des soirées à portée (`nearby_events`) | rayon fixe 2 km (`event_rules.nearby_radius_m`) |
| position des amis | **rien** : la balise du ping (`ping_beacons`) n'est lisible par AUCUN client (aucune politique), elle ne sert qu'à la reconnaissance | un objet neuf, avec ses propres règles |
| Vibes situées autour | la source « localisé près de toi » de Pulse (`feed_items(p_lat, p_lng)`), à l'initiative de l'auteur, ancre gommée à 100 m | les afficher sur la carte, trier par popularité |
| photo de profil | partout dans l'app | à dessiner en repère de carte |
| message direct, profil | oui | — |
| notification quand l'app est fermée | **non** : aucune notification à distance (pas de Firebase) | à construire pour « demander la position » |
| trajet à pied | non | service d'itinéraires de Mapbox (payant au-delà d'un seuil gratuit, à vérifier) |

## ✅ Décisions de Jay (2026-09-26)

- **A. Position des amis** : **précise**, et **seulement si l'ami a
  choisi explicitement de la partager** dans les réglages de la carte
  (désactivé par défaut). La carte dit **de quand date** la dernière
  position (« il y a 45 min »).
- **Cadence** (Jay : *« il ne faut pas surcharger les services et les
  serveurs »*) : **au plus toutes les 10 secondes** quand on est sur la
  carte pour se retrouver ; **toutes les 30 minutes** sinon — jamais
  chaque seconde. À tenir par le SERVEUR (il refuse ou ignore plus
  fréquent).
- **B. Zones chaudes** : de CONTENU (Vibes publiques localisées), jamais
  de personnes — et **plus tard**, quand il y aura beaucoup
  d'utilisateurs.
- **C. Demander la position actuelle** : à faire. L'ami reçoit la demande
  (notification + chat) et doit accepter pour la révéler.
- **D. Rejoindre un ami (trajet à pied)** : à coder pour tester, mais
  **bloqué au premier lancement public**.
- **E. Gros événements** : seuils **réglables depuis le futur centre de
  contrôle** (lignes de `event_rules`).

## Ordre de construction

1. ✅ **v0.9.293** — ma photo de profil en repère ; événements dans un
   rayon réglable (roue, 2 à 50 km, borné par le serveur :
   `nearby_events(p_radius_m, p_min_present)`) ; gros événements de loin
   (≥ `big_event_min_present` = 30 présents, jusqu'à `big_event_radius_m`
   = 150 km, flamme).
2. ✅ **v0.9.294** — position des amis. Serveur
   (`20260926110000_la_position_des_amis.sql`, essai à blanc 13 cas) :
   `location_sharing` (éteint par défaut), `location_hidden_from`,
   `friend_locations` (lisible seulement par un ami, si partage, non caché,
   non bloqué — `private.may_see_location`), `map_rules` (10 s / 30 min /
   24 h), `share_my_location` (direct), la balise du ping dépose au plus
   toutes les 30 min, `friends_on_map()`, balai horaire. App :
   `lib/features/map/friends_map.dart`, ronds des amis (« Prénom · il y a
   … »), envoi toutes les 10 s carte ouverte si je partage, roue : partager
   / cacher à…. ⚠️ Hors de l'app, la mise à jour passe par la balise du
   ping : si la proximité est éteinte, la position n'est plus rafraîchie.
3. Vibes publiques autour de moi (3 km), réglage désactivable.
4. La roue d'actions sur un ami : profil, message, rejoindre (D) ;
   « demander la position » après les notifications (C).
5. Zones chaudes, cachées (B).
