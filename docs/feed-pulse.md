# Pulse — le feed (construit le 2026-09-20, v0.9.232 ; Vibes seules depuis le 2026-09-21)

> Description de ce qui **existe**. Les règles viennent de Jay (2026-09-20) ;
> les nombres vivent en base (`feed_rules`, `crossing_windows`), pas dans le
> code.

## Ce que c'est, en une phrase

**La section « Jeux » devient Pulse** : LA section des contenus. En haut, les
stories de mes amis ; au milieu, une galerie de mini-cards — **des Vibes,
rien d'autre** (Jay, 2026-09-21 : *« le feed reste mais ce sera que des
vibes »* ; les Flows et les publications qui s'y mêlaient du 2026-09-20 au
2026-09-21 sont sortis du MVP, `docs/formats-mis-de-cote.md`) ; un tap ouvre
**directement le plein écran** (`VibesReelScreen`, l'écran du profil) avec
le sélecteur Tout / Amis / Autour de moi **posé sur le contenu, au centre
de la ligne du haut, sans bandeau, fond transparent** — la croix à droite
(Jay, 2026-09-21 : *« comme on avait fait pour les Flows »*).

Dans ce plein écran, une Vibe qu'un ami m'a ajoutée dit **« Ajouté par X »**
sous le pseudo de l'auteur **une fois que je l'ai likée** (`ReelIdentity`,
`revealedAdderProvider`) — l'ajout est anonyme jusque-là.

## Les trois sources — toutes humaines, aucun algorithme

| Source | Ce que c'est | Où c'est jugé |
|---|---|---|
| **Croisés** | le contenu **public** des gens croisés dans les **3 derniers jours** (`ping_pairs`, `event_crossings`, fenêtres de `crossing_windows`) | `private.crossed_within_window` |
| **Ajouts** | ce qu'un **ami** (connexion `full`) a **ajouté à mon feed** — anonyme jusqu'au like | `feed_adds`, `add_to_feed`, `feed_adders` |
| **Lieu** | ce que son auteur a **localisé**, à moins de **1 km** de là où je suis | `contents.anchor_lat/lng`, `private.distance_m` |

Fraîcheur : un contenu de plus de **3 jours** ne sort plus (`feed_rules.freshness`).

**Tout** = les trois. **Amis** = les ajouts seuls. **Autour de moi** = le lieu
seul. Le sélecteur est dans les trois fils ; la galerie montre « Tout ».

## Le seul juge

`private.publication_audience` gagne trois portes — et rien d'autre ne
change : public **et** croisé dans la fenêtre ; public **et** localisé ;
ajouté à mon feed. Les clés (`library_media_keys`, `open_content_media`) et
les médias (`library_media`) passent par lui : ce que `feed_items` liste se
lit, ce qu'il ne liste pas ne se lit pas. Rejoué en base sous identité le
2026-09-20 (`scratchpad/q_feed_test2.sql`) : ajout → visible dans Amis, adder
caché, like → révélé ; croisement du jour → les 7 publications publiques
récentes de Charles, par nature.

## L'ordre

`private.feed_rank` : aujourd'hui `created_at`. La pertinence (distance,
fraîcheur, likes, qui a ajouté) se branchera **là**, et seulement là — le
client ne trie pas.

## La localisation — un consentement à part

- **Non par défaut.** Une publication : l'interrupteur « Localiser » dans
  l'écran de légende. Une Vibe : la puce « Localisée (à 100 m près) » dans
  les réglages de la bibliothèque, sur « À qui ? ».
- **Gommée à 100 m, deux fois** : `ContentAnchor.gomme` dans l'app avant
  d'envoyer, `private.gomme_ancre` sur le serveur avant d'écrire — la même
  grille (test `anchor_test.dart` contre les valeurs relevées en base). Le
  point exact n'existe nulle part.
- La position est relevée **à la création** (début de l'import, première
  face capturée), avec la permission « pendant l'utilisation » déjà
  accordée au ping ; sans elle, l'interrupteur est grisé et le dit.
- **Localisé = visible de tous ceux qui passent là** : c'est ce que
  l'auteur demande en cochant.

## Le partage d'une publication à un ami

*« Partager, c'est ajouter au feed de l'autre — pas lui envoyer. »* Depuis
Pulse, repartager une publication à un **ami** l'ajoute à son feed
(`add_to_feed`), sans message dans le chat ; à un **groupe**, elle va dans
le chat comme avant. Une story va toujours dans le chat.

## Ce qui n'est PAS fait

- **Le seuil du scroll** (~60, le geste qui se durcit) : Jay le détaillera.
  `feed_rules.grid_limit` est prêt à le porter.
- **La notification au like** et le contenu dans le chat 24 h.
- **Une carte** : l'ancre existe, aucun écran ne la dessine.
- **Les anciens contenus** n'ont pas d'ancre : « Autour de moi » ne montre
  que ce qui sera localisé désormais.

`feed_items` garde son paramètre `p_kind` : l'app y passe toujours `'card'`
(`kLibraryKindVibe`), positivement.
