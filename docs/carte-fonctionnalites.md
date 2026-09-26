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

## ⚠️ Décisions à prendre par Jay

### A. La position partagée avec les amis (point 2) — la plus lourde

C'est un **nouvel objet**, qui ne partage ni la table ni les règles de la
balise du ping (règle 2 de `CLAUDE.md` : deux règles, deux objets).

1. **Par défaut, un nouvel utilisateur partage-t-il sa position avec ses
   amis ?** (Snap : oui, mode fantôme au choix.)
2. **Quelle précision est montrée** : le point exact, ou arrondi (au
   quartier, à 100 m) ?
3. **Combien de temps une « dernière position » reste visible** avant de
   disparaître (Snap : quelques heures) ?
4. **Quand est-elle mise à jour** : seulement app ouverte, ou aussi app
   fermée (même cadence que la balise, une fois par minute — coût
   batterie) ?
5. Réglages : mode fantôme (personne), « tous mes amis sauf… »,
   « seulement… » — lesquels ?

### B. Les zones chaudes (point 4) — ⚠️ touche une décision verrouillée

Deux textes de `CLAUDE.md` : *« Ce qui compte les présents ne le fait que
dans un événement (le lieu filtre), jamais dans la rue »* (symétrie du
croisement, reconfirmée le 2026-09-21), et *« Détection d'événements
publics à grande échelle par clustering géographique »* hors du MVP.

Proposition compatible : **des zones chaudes de CONTENU, pas de
PERSONNES** — la densité des Vibes publiques localisées (déjà publiées
volontairement par leurs auteurs), jamais celle des téléphones. À
confirmer par Jay.

### C. Demander la position actuelle (point 8)

Il faut une **notification même app fermée** : aucune n'existe encore
(Firebase non installé). Chantier à part, et condition de ce bouton.

### D. Rejoindre un ami (point 8)

Le trajet à pied passe par le service d'itinéraires de Mapbox (API
« Directions ») : quota gratuit puis payant — tarif à vérifier sur la page
officielle avant de construire.

### E. Les gros événements de loin (point 3)

À partir de combien de présents une soirée est-elle « grosse » ? Et
seulement les soirées ouvertes et d'établissement (jamais les privées) ?

## Ordre proposé (à valider)

1. Photos de profil en repères (moi, amis) + événements dans un rayon
   réglable jusqu'à 50 km (règle au serveur) + gros événements de loin.
2. Position des amis et ses réglages de confidentialité (décisions A).
3. Vibes publiques autour de moi (3 km), réglage désactivable.
4. La roue d'actions sur un ami : profil, message, rejoindre (D) ;
   « demander la position » après les notifications (C).
5. Zones chaudes, cachées (B).
