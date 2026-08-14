# Stockage et accès — où vit quoi, et qui peut le lire

> Relevé **en base** le 2026-08-10, **révisé le 2026-08-11** après la refonte
> « 1 contenu = 1 format » (étape 1 : la story devient autonome).
> À vérifier plutôt qu'à croire : les politiques évoluent, ce document date.

## La règle qui commande tout

> **Un contenu appartient à UN SEUL contexte de diffusion**, choisi à l'envoi
> et jamais modifié. Chaque contexte a son bucket, ses règles d'accès et son
> cycle de vie.

Le repartage n'y contrevient pas : il crée un **chemin** vers la source, jamais
une copie. Un média n'existe donc qu'en un seul exemplaire.

## Les six buckets

Un bucket est un espace de stockage **sur le serveur Supabase**. L'app n'en
possède aucun : elle y dépose et y télécharge, et le serveur décide de ce
qu'elle a le droit de lire. À ne pas confondre avec les **caches locaux**
(`CardMediaCache`, `StoryMediaCache`), qui sont des copies sur l'appareil.

| Bucket | Contexte de diffusion | Public ? | Qui peut lire | Cycle de vie |
|---|---|---|---|---|
| `avatars` | Photos de profil | Non (fermé le 2026-08-10) | `can_view_profile` | Permanent |
| `cards` | **Partage direct** dans le cercle | Non | `can_view_card_file` — **cinq** chemins | 24 h (message) |
| `stories` | **Story** | Non | `can_view_story_file` → `story_audience` | **24 h** |
| `library` | **Publication** de bibliothèque | Non | `library_read_via_acl` | **Permanent** (décision de Jay, 2026-08-11) |
| `library_vault` | **Bibliothèque de conversation** | Non | Membres, scellé jusqu'au reveal | Selon `ephemeral` |
| `media` | Photos et vidéos des messages | Non | `media_read_via_message` | 24 h (message) |

Un septième bucket est **réservé mais non créé** : celui du **BeReal**. Jay a
mis ce format de côté le 2026-08-11 et sa règle d'accès n'est pas connue —
créer le conteneur avant la règle reviendrait à inventer la règle plus tard
pour la faire entrer dedans. L'énumération `content_context` l'accueillera par
un simple `alter type ... add value`.

---

## Le cinquième contexte de diffusion : la **sauvegarde**

> Acté par Jay le **2026-08-14**, à partir de sa propre observation : « la card
> sauvegardée est presque un autre format, car les règles de visionnage ne
> s'appliquent pas sur les sauvegardées ». Elle l'est complètement.

Une sauvegarde n'est **pas** une Card avec ses limites désactivées. C'est un
objet distinct, avec ses propres octets, sa propre règle d'accès et son propre
cycle de vie — donc un contexte de diffusion à part entière, au sens de la règle
qui ouvre ce document. La seule chose qui le distingue des quatre autres : **il
ne vit pas sur le serveur.**

| | Card (cercle) | **Sauvegarde** |
|---|---|---|
| Octets | scellés, bucket `cards` | **en clair, sur l'appareil** |
| Clé | retenue par le serveur, rendue par `open_card_media` | **aucune — il n'y en a pas besoin** |
| Règles de visionnage | `max_views`, durée, `scrubbable` : **c'est l'objet même** | **n'existent pas** |
| Lignes serveur | `cards` + `card_media_keys` + `card_deliveries` | **aucune** |
| Cycle de vie | TTL, épuisement, destruction | **permanent** |
| Révocation | garantie (le serveur retient la clé) | **coopérative** (le serveur demande, l'app obéit) |

Implémentation : `lib/core/content/saved_store.dart`. Le clair sur le disque y
est **délibéré**, et c'est la seule exception de l'app — il est ce qui rend la
sauvegarde indépendante du serveur, conformément à la décision de Jay du
2026-08-11 (« pas d'espace serveur dédié »).

### Ce que ça interdit

**Ne jamais refusionner la sauvegarde et la Card.** La tentation revient
naturellement — « créer la Card au clic sur Sauvegarder, puis la partager » —
et elle a été examinée le 2026-08-14. Quatre raisons de s'en tenir à deux
objets :

1. **La sauvegarde cesserait d'être instantanée.** Créer une Card, c'est
   sceller, téléverser deux faces et écrire trois lignes : plusieurs secondes en
   4G, **impossible hors ligne**. Une copie locale est une recopie de fichier.
2. **Des Cards orphelines.** Sauvegarder puis abandonner l'envoi laisserait une
   ligne `cards` et des médias scellés **sans aucune `card_deliveries`** — que
   rien ne purge aujourd'hui.
3. **Les règles n'existent pas encore au moment du clic.** Il faudrait créer la
   Card avec des règles provisoires puis les **modifier** — et dès que
   `max_views` devient modifiable après création, la garantie du 2026-08-10 (le
   décompte et la remise de la clé sont le même geste) se ramollit.
4. **Les octets ne sont pas les mêmes.** Fusionner obligerait soit à mettre du
   clair là où vit du contenu contrôlé, soit à faire dépendre une sauvegarde
   d'une clé serveur — ce qui casse la promesse « gardé ».

### Le seul lien entre les deux, et ce qu'il est

`SavedStore.rekey` : après un envoi réussi, la copie locale **adopte le Content
ID** du contenu envoyé. Les octets restent locaux et en clair ; seul le **nom**
est partagé, et il ne sert qu'à une chose — permettre à la révocation de
modération (`revoked_contents`) de retrouver la copie. **C'est un pointeur, pas
une fusion.**

Avant l'envoi, la sauvegarde porte un identifiant `local-<uuid>`
(`localIdPrefix`). Ces clés sont **écartées** de `purgeRevoked` : le serveur ne
les connaît pas, et les lui envoyer ferait échouer le cast en `uuid[]` — ce qui,
l'échec étant avalé pour le hors-ligne, suspendrait en silence la purge de
**toutes** les autres.

⚠️ **Asymétrie assumée** : une Vibe sauvegardée **puis** envoyée devient
joignable par la révocation ; sauvegardée et jamais envoyée, non. C'est
inévitable — une prise jamais envoyée n'a aucune existence serveur à modérer.

---

## Le socle de traçabilité — `contents`

Depuis le 2026-08-11, tout contenu naît avec une identité **permanente** :

| Table | Rôle | Politiques RLS |
|---|---|---|
| `contents` | Content ID, contexte, propriétaire, **révocation** | Lecture/écriture de ses propres lignes ; **aucun UPDATE** (la révocation est un acte serveur) |
| `content_grants` | Le **graphe de propagation** : une ligne = une arête (qui a donné accès à qui, par quelle conversation) | **Aucune** — table illisible par tout client |
| `content_views` | Qui a vu, quand, combien de fois — **toujours nominatif** | **Aucune** — l'agrégation est une décision d'affichage, pas une perte de donnée |

⚠️ **Ces trois tables survivent au contenu.** Une story meurt à 24 h ; son
identité, son graphe et ses vues restent. C'est ce qui rend la traçabilité et
la révocation utiles *après* la disparition du média. C'est aussi la seule
chose de l'app qui contredise l'éphémère — arbitrage explicite de Jay.
**Aucune durée de conservation n'est fixée à ce jour** (`RAPPELS.md` #7).

### La révocation

`contents.revoked_at` non nul ⇒ plus aucune clé n'est délivrée, par personne,
**y compris l'auteur**. Les octets restant sur les appareils sont chiffrés et
deviennent donc inertes. Pour le contenu **sauvegardé** (étape 5, fichiers en
clair sur l'appareil), la révocation sera **coopérative** — faille connue et
acceptée par Jay le 2026-08-11.

---

## L'accès à une story — une question, un endroit

`private.story_audience(story, uid)` répond à **une seule** question : cette
personne est-elle dans l'audience de cette story ? Trois façons d'y entrer :

1. l'auteur ;
2. l'audience initiale (`can_view_stories` : mes amis, plus les croisés de
   moins de 24 h si « stories publiques » est actif) ;
3. un **repartage reçu** — une arête de `content_grants`.

Plus l'expiration et la non-révocation, vérifiées en tête.

**Ce n'est pas le défaut de `can_view_card_file`** : là-bas, six branches
venaient de six FORMATS différents partageant un stockage, et la plus
permissive l'emportait en silence. Ici il n'y a qu'un format, qu'un stockage et
qu'un régime — seule la façon d'entrer dans l'audience varie.

### La propagation

Une story marquée `shareable` peut être relayée par **toute personne de son
audience**, y compris quelqu'un qui l'a lui-même reçue par repartage —
d'où une propagation **sans limite de sauts** (décision de Jay, 2026-08-11).
`shareable` est **faux par défaut** et se décide à chaque publication : il n'y
a volontairement **pas** de réglage global « compte public ».

Le partage direct dans le cercle, lui, n'est **jamais** repartageable.

---

## Ce qui reste imparfait : `can_view_card_file`

L'accès à une face de Vibe **envoyée** ouvre le fichier si **au moins l'une**
de ces conditions est vraie :

1. tu es le propriétaire ;
2. tu as reçu une **livraison** non détruite ;
3. la Vibe est dans la bibliothèque de profil de quelqu'un dont tu peux voir la
   bibliothèque ;
4. elle est dans une bibliothèque **publique** et tu peux voir ce profil ;
5. tu l'as **sauvegardée**.

**La branche story a disparu le 2026-08-11** — de six chemins, il en reste
cinq. Les branches 3 et 4 tomberont à l'étape 2 (publication autonome), la 5 à
l'étape 5 (sauvegarde locale). L'objectif est **un seul chemin** : la livraison.

### Ce que la refonte a déjà supprimé

| Défaut du 2026-08-10 | État |
|---|---|
| Une story annule la limite de vues d'une livraison | **Supprimé** — les deux objets n'ont plus rien en commun |
| Compteur de vues partagé entre le chat et la story | **Supprimé** — une story n'a pas de compteur |
| Supprimer une story emportait la publication et l'envoi | **Supprimé** — un contenu, un format |

### Défaut préexistant, non corrigé

La politique `cards_select_library` (table `cards`) compare `li.card_id = li.id`
— `library_items.card_id` contre `library_items.id`. Elle n'est donc jamais
vraie : **c'est une règle morte**. Sans effet visible (les autres branches
couvrent les cas), à supprimer à l'étape 2 quand ces politiques seront
réécrites.

---

## Les caches locaux

Deux espaces **séparés**, parce que deux cycles de vie différents :

| Cache | Contenu | Règle de rétention |
|---|---|---|
| `CardMediaCache` | Faces de Vibes | Budget de vues + TTL du message, quota `own` paramétrable, 200 Mo pour `others` |
| `StoryMediaCache` | Faces de stories | **L'expiration de la story**, 100 Mo pour `others` |

Les deux ne contiennent que des **scellés** : le clair vit dans le répertoire
temporaire et meurt avec l'écran.

⚠️ **Limite connue, à traiter à l'étape 5** : les octets de MES propres
contenus sont bien locaux, mais **la clé vient du serveur** — rouvrir ma propre
story ou ma propre Vibe demande donc encore le réseau. Le volet 2 de Jay (« la
source n'est pas le serveur mais le téléphone ») ne sera tenu qu'une fois la
clé de mes propres contenus conservée localement.
