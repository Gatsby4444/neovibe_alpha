# NeoVibe — Contexte projet pour Claude Code

## Positionnement

> Réécrit le **2026-09-11** à partir de `NeoVibe_vision.docx` et des précisions
> de Jay du même jour. Le raisonnement complet est dans
> `docs/vision-produit.md` ; la version antérieure au 2026-09-11 est conservée
> telle quelle dans `docs/oldvision.md`.

**Le défaut qu'on attaque.** Les réseaux sociaux actuels sont payés à
l'attention : leur revenu vient de la publicité, donc leur intérêt est que tu
restes le plus longtemps possible devant l'écran. Le produit, c'est
l'utilisateur. Ce modèle pousse au contenu court, consommé **seul et
passivement** même quand on le partage — un utilisateur qui scrolle est seul
devant son écran. Des réseaux censés rapprocher les gens finissent par les
isoler.

⚠️ **Ce n'est pas un jugement de goût, c'est un mécanisme.** L'ancienne
formulation (« du contenu vide, des échanges sans valeur parce que trop
faciles ») décrivait un symptôme contestable — on peut y répondre « moi j'aime
bien ». Celle-ci décrit une chaîne de cause à effet : publicité → temps passé →
consommation passive → isolement. On peut construire contre.

**Ce que NeoVibe fait à la place.** NeoVibe est la **passerelle entre le
numérique et le réel** : un réseau qui te pousse à sortir, à vivre des choses
avec tes amis et tes cercles, et à en rapporter le contenu.

> **le feed te donne envie → tu sors → tu vis quelque chose → tu le filmes →
> tu le publies → ça nourrit le feed de quelqu'un d'autre**

**Cette boucle EST la thèse.** Le contenu n'est pas un **substitut** à
l'expérience : il en est le **résidu**. Ailleurs on regarde la vie des autres à
la place de vivre la sienne ; ici on ne peut alimenter le feed qu'en étant
sorti.

**Le temps passé n'est pas l'ennemi — ce dont il est fait l'est.** Une app sur
laquelle on passe 30 secondes par jour ne sert à rien (Jay, 2026-09-11). On
vise donc un engagement réel, mais nourri de contenu que quelqu'un a dû
**sortir de chez lui** pour produire. Stratégie assumée : *« commencer par jouer
au jeu des plus grands pour s'immiscer petit à petit dans le système, et une
fois qu'on a assez d'influence lui faire prendre un virage pour le bien des
utilisateurs. »*

---

**La présence physique est le mécanisme d'entrée** dans le réseau : on ajoute
quelqu'un en ami par proximité BLE, ou par recommandation d'un ami commun quand
la rencontre physique est impossible. C'est la barrière fondatrice, et elle est
**confirmée le 2026-09-11** — inchangée.

⚠️ **Ce qu'on découvre, ce sont des ACTIVITÉS, jamais des PERSONNES à ajouter.**
Les activités des commerçants partenaires et les jeux sont ouverts ; devenir
ami passe toujours par les deux seules portes ci-dessus. Ce sont deux objets
distincts avec deux chemins distincts — ne jamais les fusionner.

✅ **Le corollaire de la barrière est enfin résolu.** Il disait : *une barrière
sans contrepartie ne retient personne ; c'est la moitié du produit qui reste à
construire.* Cette moitié a désormais un nom — **la contrepartie, c'est le
réel**. La barrière cesse d'être un péage à faire pardonner : elle devient la
première marche de la promesse. Il est normal de devoir se rencontrer, puisque
tout le produit consiste à vous faire vous rencontrer.

---

**Le modèle économique pousse dans le même sens que le produit.** Partenariats
**directs** avec des commerçants locaux, qui s'intègrent à l'app ; activités
réservables depuis NeoVibe.

⚠️ **Ce n'est pas de la publicité, c'est une FONCTIONNALITÉ** (mot de Jay) — une
publicité interrompt ce que tu faisais, une activité réservable **est** ce que
tu cherchais. **Aucune publicité sur le feed au début.** La publicité classique
reste prévue, plus tard et au second plan, *« pour rassurer les
investisseurs »*.

🔴 **Ce que cette distinction engage** : elle ne tient que si un commerçant **ne
peut pas acheter sa place**. Le jour où payer plus fait remonter dans la liste,
c'est redevenu de la publicité, quel que soit le nom qu'on lui donne. Le modèle
cohérent avec la thèse est **la commission sur la réservation** : NeoVibe gagne
quand quelqu'un sort vraiment.

**Le feed n'est pas infini.** Passé un certain nombre de contenus (ordre de
grandeur donné par Jay : ~60), **le geste du scroll se durcit** et devient de
plus en plus coûteux. But : *« protéger nos utilisateurs, éviter de les enfermer
dans une boucle interminable qui perd leur esprit plutôt que de leur montrer ce
qui se passe autour d'eux »*. Même philosophie que l'anti-capture : **coûteux et
visible, pas impossible**.

⚠️ **Conséquence à ne pas rater** : un scroll qui résiste, pour qui ignore que
c'est voulu, **ressemble à une panne**. Le durcissement doit être **lisible au
moment où il arrive**, sans notice — sinon c'est un bug, pas une protection.

---

« l'Apple des réseaux sociaux » : interface **claire et épurée mais qui reste
cool**, et **contrôle total de l'écosystème** — *« ce qui se passe sur NeoVibe
reste sur NeoVibe »*. C'est la raison d'être du chiffrement et de la livraison
sécurisée des médias : ce ne sont pas des précautions d'ingénieur, c'est cette
phrase rendue vraie. Conséquence directe : **un média déchiffré écrit en clair
sur le disque est un manquement à la promesse**, pas un détail
d'implémentation. Corollaire de méthode : la bonne réponse est **le défaut
juste, pas l'option supplémentaire** — sans quoi « contrôle total » et
« épuré » se contredisent.

**Périmètre de cette phrase — deux précisions successives de Jay.**

1. *2026-08-20* — elle désigne **la difficulté de faire fuiter du CONTENU
   NeoVibe vers l'extérieur** : format card, anti-capture, livraison scellée.
   Ce n'est **pas** un argument sur les métadonnées côté serveur (qui croise
   qui, qui parle à qui). Ne pas la ressortir pour peser sur un arbitrage de ce
   type — les arbitrages sur les métadonnées se posent pour eux-mêmes, avec
   leur coût réel et leur rétention.
2. *2026-09-11* — elle ne couvre pas tout de la même façon :

   | Surface | Règle |
   |---|---|
   | **DM / chat** | **verrouillé** — pas de capture d'écran, pas d'enregistrement, pas d'export |
   | **Feed / publications** | **partageable** — c'est même le moteur de circulation |

   Les deux coexistent sans se contredire parce qu'un contenu appartient à **un
   seul contexte de diffusion** (`docs/stockage-et-acces.md`).

---

**Le partage, c'est ajouter au feed de l'autre — pas lui envoyer.** Partager une
publication à un ami ne la lui **envoie** pas : ça l'**ajoute à son feed**.
Envoyer crée une dette (l'autre doit répondre) ; ajouter est une invitation. Le
feed est donc fait de **ce qui se passe autour de toi** + **ce que tes cercles
t'ont tendu** : pas d'algorithme de recommandation, **les amis SONT
l'algorithme**.

**Et l'ajout est anonyme** (idée de Jay, 2026-09-11) : celui qui ajoute reste
anonyme pour le destinataire — *« sauf si cet ami like le contenu, il découvrira
qui lui a envoyé »*. But : *« empêcher que les utilisateurs se sentent obligés
de liker le contenu d'un ami uniquement parce que c'est lui »*. L'expéditeur ne
sait **pas** si son ajout a été vu ; il n'est notifié **qu'au like**, et le
contenu s'affiche alors dans le chat pendant 24 h. ➡️ **Le like cesse d'être un
accusé de réception et ouvre une conversation**, là où partout ailleurs il la
clôt.

**NeoVibe est aussi un jeu social géant** : des jeux à l'échelle d'une ville
entière (un loup-garou géant), des défis — à filmer et à publier. C'est la
« dynamique renouvelée en permanence » réclamée depuis le 2026-07-26, et elle
**exige** la densité locale : la barrière devient une récompense au lieu d'un
péage. *Conséquence de calendrier : le seed test se fait dans **une seule
ville**.*

---

## Grille de décision

*Remplace le 2026-09-11 l'ancienne grille (« présence physique OU valeur d'une
relation existante »), qui rejetait la moitié de la vision affinée — une sortie
photo avec des gens qu'on n'a pas encore rencontrés n'y entrait pas.*

**Une fonctionnalité passe si elle fait au moins l'une de ces quatre choses :**

1. **faire sortir** — elle mène à une activité ou une rencontre réelle ;
2. **rapporter** — elle transforme une expérience vécue en contenu partagé ;
3. **faire circuler par un geste humain** — partage vers un cercle, ajout au
   feed d'un ami ;
4. **augmenter la valeur d'une relation existante.**

**Elle échoue** si elle produit du contenu que personne n'a eu besoin de sortir
de chez lui pour faire, et qu'une machine ordonne pour retenir.

> ⚠️ **Le test, en une phrase : « ce contenu a-t-il obligé quelqu'un à sortir de
> chez lui ? »**

En cas de doute, trancher en faveur de l'authenticité de la relation et du
passage au réel, même si c'est moins pratique à développer.

La vision complète (le raisonnement, les mécaniques fondatrices, ce qui reste à
construire, les points de vigilance) est dans **`docs/vision-produit.md`** — à
relire en début de session avec `RAPPELS.md` et les derniers rapports.


---

## La chaîne des mécaniques sociales

*Précisions de Jay des 2026-09-11 et 2026-09-12. Détail complet et relevé
technique : `docs/vision-produit.md` §8. Questions ouvertes : §12.*

**Ce ne sont pas des fonctionnalités séparées, c'est un seul mécanisme.** Chaque
maillon fabrique la matière première du suivant :

> **le geocircle rassemble** (la soirée au bar)
> **→ la soirée produit des croisements** (on était là, tous les deux, longtemps)
> **→ les croisements nourrissent les suggestions** (3 jours pour le retrouver)
> **→ les suggestions font des amis** (par la porte physique, inchangée)
> **→ les amitiés montent en paliers** (discrètement, en arrière-plan)
> **→ les paliers débloquent** des choses
> **→ et tout du long, ça produit du contenu qui alimente le feed**

Et ça reboucle sur la boucle du Positionnement. **C'est « l'esprit NeoVibe »
selon Jay.**

### 🔴 L'événement et le mode événement — vocabulaire tranché le 2026-09-12

On passe devant un bar, on le **rejoint physiquement ET dans NeoVibe** : pour la
soirée, on est connecté à tous ceux qui y sont, avec des jeux, des défis et des
fonctionnalités réservés aux présents. Vaut aussi pour les **soirées privées**.

**Trois choses s'appelaient « cercle » ; Jay a tranché le 2026-09-12** — ces
mots finiront dans des noms de tables, ne pas les mélanger :

| Mot | Ce que c'est |
|---|---|
| **Cercle** | l'onglet d'accueil, mes amis — **inchangé** pour l'instant ; c'est aussi **la porte** par laquelle on rejoint un événement |
| **Événement** | ce qu'on appelait « le cercle d'un lieu » ; **deux origines** ci-dessous |
| **Mode événement** | la seconde face de l'app ; **n'apparaît que si on a rejoint un événement**, pour ne pas polluer l'app ; **un seul événement à la fois** |
| **Groupe** | l'objet existant ; les « cercles par passion » **sont des groupes**, on y entre parce qu'un ami vous y ajoute, la suggestion en est la découverte |

| Mode | Ce que c'est |
|---|---|
| **social classique** | l'app telle qu'elle est |
| **événement** | ouvre aux présents : jeux, mini-jeux sociaux, défis → qui produisent du contenu à poster |

**Un événement a deux origines, avec deux règles d'accès différentes :**

| | Événement **privé** | Événement **d'établissement** |
|---|---|---|
| créé par | son organisateur, qui construit un **groupe d'événement** éphémère (soirée, voyage, activité) — ⚠️ **jamais dans un groupe existant** | le commerçant, sur une **plateforme d'inscription dédiée** (produit web à part) |
| qui peut être invité | **les amis, au sens strict** (amitié acceptée des deux côtés) — Jay a écarté « toute connexion, même par un groupe » : *« cela contourne un peu la base du réseau »* | tout le monde — c'est le lieu qui filtre |
| qui invite | **tout le monde, paramétrable** : les invités sont **admin par défaut** (ajouter / retirer), le créateur peut modifier ces réglages — « comme sur WhatsApp » ; on n'ajoute que **ses propres amis** | — |
| accès aux fonctionnalités | être **du groupe d'événement ET sur place** | être **sur place** |
| se ferme | **automatiquement quand 80 % des participants sont partis** | par **l'hôte** (plateforme) ou à **l'horaire** paramétré |

**Dans les deux cas** : la présence se prouve par un **système mixte ping ET
localisation** ; un participant **sort automatiquement en s'éloignant de
l'événement et de son cœur**, ou manuellement. **Le cœur = les points chauds**,
là où les participants sont — plusieurs possibles, « comme sur Snap » : un
festival dépasse la portée BLE, c'est pour ça que la présence est mixte. Les
points chauds sont une **vue dérivée** des positions, jamais un fait stocké.
**Le groupe d'événement survit 5 jours après la fermeture**, puis est purgé.

✅ **Deux origines, deux filtres nets** : le privé filtre par **la relation**,
l'établissement par **le lieu**. L'invitation privée réutilise la garde qui
existe (`are_connected`, statut `full`) — rien à inventer. Les états de
relation restent nécessaires **pour l'événement lui-même** (des inconnus dans
la même soirée doivent apparaître comme « présents », jamais comme amis).

⚠️ **Groupe ≠ groupe d'événement.** Le premier est durable ; le second vit le
temps de l'événement, avec ses propres fonctionnalités et **sa propre
bibliothèque éphémère et retardée, à d'autres paramètres**. Deux durées de vie
= deux objets (règle 2) — le précédent est `ConversationType.proximity`.

⚠️ Règle 2 de ce fichier : ce qui donne le droit d'entrer (du groupe / client du
lieu) **ne partage pas la même règle**, sinon la plus permissive gagne.

✅ **Ça n'ouvre AUCUNE porte nouvelle** — vérifié en base le 2026-09-12 : ajouter
quelqu'un à un groupe exige d'en être membre **et** d'être ami avec lui ; les
membres d'un groupe se voient mais **ne peuvent pas se demander en ami sans se
croiser**. Le privé exige d'être déjà du groupe, le public d'être sur place. Les
deux portes d'entrée restent intactes.

🟢 **Et le modèle économique s'emboîte là** : le bar est le commerçant
partenaire, et la plateforme d'inscription **est** le territoire commerçant. Ce
que NeoVibe lui vend n'est pas un encart, **c'est une soirée animée**.

### ⚠️ Trois durées de vie, trois objets, jamais le même rangement

| Objet | Durée | Nature |
|---|---|---|
| **l'événement** (la soirée) | quelques heures à quelques jours | temporaire, lié au **lieu** ou au **groupe**, révocable |
| **le croisement** | **24 h** aujourd'hui (`encounters`) ; voulu : **3 jours** s'il vient d'un ping, **d'autres règles** s'il vient d'un événement — **la fenêtre est un paramètre de l'ORIGINE, jamais une constante** (Jay, 2026-09-12 : *« d'abord les bases, ensuite les règles précises »*) | de personne à personne, un **fait**, qui porte son **origine** |
| **l'amitié** | durable | une **intensité** qui se gagne (`friendship_tier`) |

Règle 2 de ce fichier : les mélanger, c'est la règle la plus permissive qui
gagne — **en silence**.

### ⚠️ L'ordre de construction, fixé par Jay — ne pas l'inverser

**Les états de relation d'abord, le mode événement ensuite** (`RAPPELS.md` #99).
Tout ce qui entre au carnet de clés est aujourd'hui **présenté comme un ami** :
élargir la source avant d'avoir le libellé du lien ferait apparaître des
inconnus comme des amis.

➡️ **Le joint technique est CÔTÉ SERVEUR** : le ping ne demande jamais « qui sont
mes amis », il lit `device_keys` et prend ce que la politique RLS lui rend. Faire
reconnaître les participants d'une soirée = élargir une règle serveur, **sans
toucher au Dart ni au Kotlin du ping**.

✅ **Construit le 2026-09-12** (v0.9.175) — `docs/evenements.md` est la
description de ce qui existe : `private.relation_kind` + vue `key_book` (le
carnet porte `friend` / `event`), tables `events`, `event_group_members`,
`event_presences`, `event_positions`, `event_sightings`, `event_crossings`,
`venues`, paramètres dans `event_rules` et `crossing_windows`, balai
`neovibe_events`. Côté app : `lib/features/events/`. **Pas construit** : la
plateforme web des commerçants (contrat dans `docs/plateforme-etablissements.md`),
la position en arrière-plan, les jeux. `RAPPELS.md` #129.

### Les paliers d'amitié : discrets, d'arrière-plan

Consigne de Jay (2026-09-12) : comme sur Snap — ça vit dans un coin du profil,
ça **remonte les plus proches en haut de la liste au partage**, et ça débloque
des choses liées à la proximité. **Ça ne s'affiche pas partout.**
🔴 Le tri des destinataires par palier à l'envoi **n'existe pas encore**.
Règles complètes : `docs/paliers-d-amitie.md`.

---

## Règle impérative : UN FAIT SE VÉRIFIE À LA SOURCE, JAMAIS DANS UN DOCUMENT

*Consigne de Jay, 2026-08-25 — impérative, sans exception.*

> « Tu ne dois pas te fier aux rapports d'anciennes sessions, ni aux vieux
> documents explicatifs, ni aux commentaires : il faut **vérifier en base ou
> dans le code** pour contrôler une information avant d'en déduire quoi que ce
> soit. »

**Ce qui compte comme source** — et rien d'autre :

| Question | Où la vérifier |
|---|---|
| L'état des données (qui est ami avec qui, quelles lignes existent) | **en base**, par une requête |
| Ce que fait le code | **dans le code**, en déroulant la chaîne jusqu'au bout |
| Ce que produit un build | **sur l'artefact** (manifeste fusionné, `aapt`, `apksigner`) |
| Ce qui s'est passé sur l'appareil | **dans le rapport de diagnostic de CE test** |

**Ce qui ne compte PAS comme source** : un rapport de session antérieur, une
entrée de `RAPPELS.md`, un commentaire de code, un fichier de `docs/`, une
migration SQL, ou ma propre mémoire. Tous décrivent **ce qui était vrai le jour
où ils ont été écrits**. Ils servent à savoir **quoi aller vérifier** — jamais à
conclure.

⚠️ **Le piège est qu'un document périmé est indiscernable d'un document juste.**
Il ne se contredit pas, il ne lève aucune erreur : il induit simplement un
raisonnement entier dans la mauvaise direction, avec l'assurance d'une source.

**Exemple de référence, 2026-08-25** : un rapport du 2026-08-17 mentionnait une
remise à zéro « Charles ↔ mimi pour le test de première rencontre ». J'en ai
conclu que les deux comptes n'étaient **pas** amis pendant le test du 2026-08-25,
et j'ai bâti tout un diagnostic dessus. **Ils étaient amis.** Une requête en base
aurait coûté dix secondes et évité une analyse fausse.

**Corollaire** : quand une conclusion repose sur un fait non vérifié, le dire
explicitement — « je suppose X, à confirmer » — au lieu de l'énoncer comme
acquis. Voir aussi la règle 7 ci-dessous (« ne jamais livrer un correctif fondé
sur une déduction ») : celle-ci en est l'amont.

---

## Règle impérative : la fiabilité vient de l'architecture, pas du colmatage

*Consigne de Jay, 2026-08-11 — impérative, applicable à tout chantier.*

> « On doit construire une architecture robuste et claire, ne pas tout mélanger
> et colmater les brèches. La fiabilité vient de l'architecture et de la
> structure, pas du rebouchage des failles. Et **on sépare clairement et
> distinctement tout ce que l'on peut**. »

Ce qui en découle, à appliquer avant d'écrire la moindre ligne :

1. **Devant un risque, chercher d'abord à supprimer la cause**, et seulement
   ensuite à empêcher qu'elle nuise. Un garde-fou est un aveu : il faut le
   maintenir, le comprendre et ne jamais le contourner par mégarde. Une cause
   supprimée ne coûte plus rien.
2. **Deux objets qui n'obéissent pas aux mêmes règles ne partagent ni le même
   stockage, ni la même table, ni le même chemin d'accès.** S'ils les
   partagent, c'est la règle la plus permissive qui gagne — toujours, et en
   silence.
3. **Compter les chemins qui mènent à un contenu.** Plusieurs chemins aux
   règles différentes = défaut de conception, pas contrainte à documenter.
4. **Une règle de sécurité doit s'énoncer positivement.** « Ce fichier n'existe
   pas » vaut infiniment mieux que « ce fichier existe mais rien ne le rend
   lisible ». Toute sécurité qui s'énonce par une négation (« tant que personne
   n'ajoute… ») a une date de péremption.
5. **Ne pas mélanger le contenu et le format.** Un même média diffusé selon
   plusieurs règles doit donner plusieurs objets distincts, chacun avec son
   cycle de vie. Un objet appartient à **un seul contexte de diffusion**.
6. **Après un changement d'architecture, rejouer les décisions qui en
   dépendaient** au lieu de dérouler un plan écrit avant.
7. **Ne jamais livrer un correctif fondé sur une déduction.** Reproduire la
   panne d'abord — en base, sous l'identité de l'utilisateur, avec la sécurité
   active (`set local role authenticated` + `request.jwt.claims`). Une
   hypothèse plausible qui ne corrige rien fait perdre un aller-retour de test
   à Jay **et** ajoute des changements non justifiés au diff.
8. **Toute suppression est une opération sur un réseau — relever les DEUX sens
   avant de couper.** *Consigne de Jay, 2026-08-12, après la panne
   `saved_cards` — impérative.*

   > « Quand tu supprimes quelque chose il faut impérativement toujours vérifier
   > où ce que tu supprimes est appelé, et ce que ce que tu supprimes appelle.
   > C'est comme si tu supprimais un nœud d'un réseau : tu casses le réseau, car
   > les autres nœuds appelaient le nœud supprimé et le nœud supprimé appelait
   > d'autres nœuds. »

   Avant de supprimer quoi que ce soit — table, colonne, fonction, politique,
   widget, provider, écran, fichier natif :

   - **Sens entrant : qui m'appelle ?** Balayer **toutes** les familles d'objets,
     pas seulement celle qu'on supprime : politiques RLS, corps de fonctions,
     triggers, jobs cron, vues, clés étrangères, appels Dart, et le catalogue
     natif. Un appelant oublié ne se voit **ni au diff, ni à
     `flutter analyze`** — il n'apparaît qu'à l'exécution, chez Jay.
   - **Sens sortant : qu'est-ce que j'appelais ?** Ce que le nœud supprimé
     utilisait devient peut-être orphelin à son tour (fonction sans appelant,
     table sans lecteur, bucket sans écrivain). Le supprimer dans la foulée, ou
     le justifier — un reste mort d'aujourd'hui est la panne de demain.
   - **Ne jamais se fier au `cascade` de PostgreSQL.** Il ne suit que les
     dépendances **déclarées**. Le corps d'une fonction SQL (`AS $$ … $$`) est
     stocké comme du **texte**, réanalysé à l'exécution : PostgreSQL n'y voit
     aucune dépendance. Une fonction survit donc à la table qu'elle interroge,
     et la politique qui l'appelle lui survit à son tour. *(C'est exactement la
     panne du 2026-08-12 : `saved_cards` supprimée le 2026-08-11, et toute
     lecture de `cards` échouait en 42P01.)*
   - **Vérifier par inventaire, pas par le diff** — corollaire de la règle 3.
     Lister les occurrences restantes du motif supprimé et les justifier **une
     par une**.

### Deux pièges Supabase déjà payés

- **Une fonction citée dans une politique RLS doit être exécutable par
  `authenticated`.** Une politique s'évalue avec les droits de celui qui
  interroge. Révoquer l'exécution d'une fonction du schéma `private` ne protège
  de rien — ce schéma n'est pas exposé par PostgREST — et casse toutes les
  politiques qui s'en servent. La consigne « révoquer les fonctions
  `SECURITY DEFINER` » ne vaut que pour le schéma **`public`**, le seul joignable
  sur `/rest/v1/rpc/`. *(Panne du 2026-08-11.)*
- **Une clé étrangère est aussi un chemin de jointure pour le client.**
  PostgREST résout les jointures par le **nom de la contrainte** :
  `profiles!stories_owner_id_fkey(*)` casse si cette contrainte cesse de
  pointer vers `profiles`. En reconstruisant une table, relever les contraintes
  de l'ancienne au lieu de les réécrire de mémoire. La convention du projet est
  `owner_id references public.profiles(id)`. *(Même panne.)*

---

## Règle impérative : dissocier l'ACQUISITION de l'USAGE

*Consigne de Jay, 2026-08-20 — impérative, applicable à tout chantier.*

> « Lorsque tu codes, tu dois totalement dissocier le code qui se charge
> d'acquérir des données du code qui utilise ces données. Avoir une base solide,
> cela veut dire avoir un système d'acquisition et de transmission de données
> robuste, dissocié et indépendant, de sorte à pouvoir ensuite brancher
> n'importe quelle fonctionnalité utilisant ces données. Sinon, à chaque
> modification d'une fonctionnalité on doit toucher à des fonctions qui cassent
> d'autres fonctionnalités. Il faut un code compartimenté et localement
> indépendant. »

C'est le prolongement direct de la règle d'architecture (« la fiabilité vient de
l'architecture, pas du colmatage ») appliquée au **sens de circulation** des
données. Ce qui en découle, à appliquer avant d'écrire la moindre ligne :

1. **Une couche d'acquisition publie ce qu'elle constate, fidèlement, et ne
   décide de rien d'autre.** Elle ne sait pas qui la lit, ni ce qu'il en fera,
   ni s'il faut redessiner un écran. Dès qu'elle filtre « pour économiser », elle
   prend une décision d'affichage qu'elle n'a pas les moyens de prendre.
2. **Qui consomme décide de ce qui l'intéresse**, avec sa propre définition de
   « différent ». Le coût d'une publication trop fréquente se règle **du côté
   consommateur**, par une comparaison de valeurs — jamais en amont.
3. **Deux sources qui ne changent pas au même rythme ne partagent pas le même
   objet d'état.** Les mélanger impose le rythme de la plus rapide au coût de la
   plus lente : une donnée radio à 10 Hz forçait deux lectures de fichier à
   10 Hz. *(C'est exactement le défaut du 2026-08-18, point C.)*
4. **Le test de la règle** : « si j'ajoute un champ à cet écran, dois-je toucher
   au code qui parle à la radio / au réseau / au disque ? » Si oui, la
   séparation n'est pas faite.
5. **Ce type de défaut ne lève aucune erreur.** L'écran affiche la bonne chose,
   les tests passent, seul le coût explose. Il ne se voit qu'en **comptant** —
   les notifications, les lectures disque, les reconstructions. Un test qui
   compte vaut mieux qu'un commentaire qui promet. Exemple de référence :
   `test/presence_feed_test.dart`.

Mise en œuvre de référence dans le projet : `lib/features/proximity/presence_feed.dart`.

---

## Règle impérative : ON SÉPARE TOUT CE QUI PEUT L'ÊTRE

*Consigne de Jay, 2026-08-25 — impérative, applicable à tout le code, sans
exception ni cas particulier.*

> « On sépare tout ce qui peut l'être dans notre code, et on code intelligemment
> et de manière scalable. **On ne mélange plus backend et frontend. On ne mélange
> plus cuisine, serveurs et clients.** »

C'est la généralisation des deux règles précédentes — « la fiabilité vient de
l'architecture » et « dissocier l'acquisition de l'usage » — érigée en principe
par défaut. **Les deux règles ci-dessus en sont désormais des cas particuliers,
pas des exceptions.**

### L'image de référence, à garder en tête

| Rôle | Ce qu'il fait | Ce qu'il ne fait JAMAIS |
|---|---|---|
| **La cuisine** (acquisition, dépôts, natif, SQL) | prépare et publie fidèlement | décider qui est servi, ni quand redessiner |
| **Le serveur** (vues dérivées, providers) | choisit ce qui l'intéresse, à son rythme | aller cuisiner lui-même |
| **Le client** (widgets, écrans) | affiche | aller en cuisine chercher son plat |

**Le test, à s'appliquer avant d'écrire une ligne** : *pour changer la
présentation, dois-je toucher à ce qui prépare la donnée ?* Si oui, la séparation
n'est pas faite.

### Ce qui en découle

1. **Un écran ne parle jamais au réseau, au disque ou au natif.** Il demande à un
   dépôt. Une requête écrite dans un fichier d'écran n'est réutilisable par
   personne, et se retrouve dupliquée — *constaté le 2026-08-25 :
   `chat_screen.dart` avait sa propre copie de `cardByIdProvider`, mot pour mot,
   avec son propre cache.*
2. **L'invalidation de cache appartient à l'ÉCRITURE, jamais à l'appelant.** Deux
   écrans qui écrivent la même table doivent laisser le lecteur dans le même
   état ; sinon l'un affiche du périmé et l'autre non, selon lequel a servi.
3. **Le temps est une SOURCE, pas une commodité.** Tout filtre qui appelle
   `DateTime.now()` dépend d'une donnée qu'il n'observe pas. On s'y abonne
   (`core/clock.dart`) ou on assume l'instantané **en l'écrivant**.
4. **Un chemin, une donnée.** Deux chemins vers la même chose, c'est deux caches
   et un désaccord futur que rien ne signalera.
5. **Scalable veut dire : le coût d'ajouter le prochain cas.** Une solution qui
   marche pour deux écrans mais demande d'en toucher cinq au troisième n'est pas
   une solution, c'est une dette. Compter le nombre d'endroits à modifier
   *avant* de choisir.
6. **Ce défaut ne lève aucune erreur** — il ne se voit qu'en **comptant**.
   Un test qui compte vaut mieux qu'un commentaire qui promet.

### Les outils du projet, à utiliser plutôt qu'à réinventer

| Besoin | Outil |
|---|---|
| une vue dérivée **sans paramètre** qui ne réveille que si son résultat change | `DerivedList` / `DerivedSet` (`core/derived_list.dart`) |
| une vue dérivée **paramétrée** (idem) | `ValueList<T>` (`core/derived_list.dart`) |
| tout ce qui **périme** | `expiryClockProvider` (`core/clock.dart`) |

⚠️ **Ces outils sont inopérants en silence si le type de l'élément n'a pas
d'égalité de valeur.** Tout modèle placé dans une liste dérivée doit porter son
`==` — c'est ce qui manquait à **tous** les modèles avant le 2026-08-25.

Audit fondateur et état avant/après : **`docs/checkup-acquisition-usage.md`**.
Tests de référence : `test/derived_list_test.dart`,
`test/dissociation_connections_test.dart`, `test/presence_feed_test.dart`.

---

## Règle impérative : UN DÉFAUT TROUVÉ SE RÉPARE TOUT DE SUITE

*Consigne de Jay, 2026-08-30 — impérative, sans exception.*

> « On ne laisse jamais des défauts trouvés en attente. Après, c'est cela qui
> nous perd et qui crée de plus grosses erreurs. »

**Le moment où un défaut est trouvé est le seul moment où il est entièrement
compris.** Une heure plus tard il ne reste que sa description ; un jour plus
tard, une ligne dans `RAPPELS.md` que quelqu'un devra ré-instruire depuis zéro.

### Ce qu'il faut faire

1. **Réparer dans la foulée**, dans la même session, avant de passer à la suite.
   Consigner ne remplace jamais réparer : `RAPPELS.md` sert à ce qui demande une
   DÉCISION de Jay, pas à ranger ce qu'on sait déjà corriger.
2. **Le défaut qu'on vient de créer soi-même passe en premier.** Il est encore
   frais, et personne d'autre ne sait qu'il existe.
3. **Si la réparation ne peut vraiment pas se faire maintenant**, le dire à Jay
   avec la raison — et c'est *lui* qui reporte, pas moi.

### Pourquoi c'est un principe, et pas de la propreté

Un défaut en attente ne reste pas de la même taille : le code continue de
s'écrire **par-dessus** lui. Les correctifs suivants se posent sur une base dont
on sait qu'elle est fausse, et chacun devient un point à démêler le jour de la
vraie réparation. Le coût ne croît pas linéairement, il se ramifie.

⚠️ **Et le cas le plus coûteux est celui d'un INSTRUMENT défaillant** — une
mesure illisible, un libellé qui ment, un compteur jamais incrémenté. Il ne
gêne rien tout de suite : il fausse simplement toutes les décisions prises
ensuite, sans que rien ne le signale. *Le 2026-08-30, deux instruments ont été
livrés le même jour sans sortie lisible ; le second promettait de répondre à une
question qu'il ne pouvait pas atteindre.*

### ⚠️ Le test à s'appliquer

**« Est-ce que je viens d'écrire, ou de dire, que quelque chose ne va pas ? »**
Si oui, ça se répare maintenant. Une phrase qui commence par *« à corriger plus
tard »* ou *« à noter pour la prochaine session »* doit être justifiée devant
Jay, jamais décidée seul.

Voir aussi la règle 8 (« toute suppression est une opération sur un réseau ») :
un reste mort d'aujourd'hui est la panne de demain — c'est la même règle, vue
depuis la suppression.

---

## Règle impérative : rapport de session

**À chaque nouvelle session**, créer un rapport dans le dossier `rapports-de-sessions/` à la racine du repo.

- **Nom de fichier** : `AAAA-MM-JJ_HH-MM.md` (date de création du rapport, précise à la minute — heure de début de session)
- **Le rapport est un document vivant** : il doit être mis à jour à chaque modification significative du code ou du projet au cours de la session, pas seulement écrit à la fin.
- **Contenu obligatoire** :
  1. **Modifications apportées** — liste factuelle des fichiers touchés, fonctionnalités ajoutées/modifiées, décisions d'implémentation prises
  2. **Difficultés rencontrées ou erreurs commises** — ce qui a coincé, ce qui a été essayé et n'a pas marché, et **comment ne pas les reproduire** (cause identifiée + solution ou contournement adopté)
  3. **Notes et consignes de Jay** — toute instruction, préférence ou clarification donnée pendant la session, même orale/informelle dans le chat, à consigner pour référence future
- Avant de commencer une nouvelle session, **relire les 1 à 3 derniers rapports** pour ne pas répéter une erreur déjà documentée ou contredire une consigne déjà donnée.
- Un rapport reste factuel et concis. Pas d'auto-satisfaction, pas de reformulation commerciale — c'est un outil de mémoire technique, pas une présentation.

---

## Règle impérative : fichier de rappels

Le fichier **`RAPPELS.md`** à la racine du repo est la mémoire longue de Jay.

- **Tenir ce fichier à jour** : dès que Jay demande de « garder ça pour plus
  tard », de « me le rappeler », ou dès qu'une limite/dette connue est
  identifiée, l'y consigner (sujet, détail, date).
- **Le ressortir au bon moment** : avant une release de production, ou quand
  le chantier concerné revient sur la table, rappeler à Jay les entrées
  pertinentes — sans attendre qu'il le demande.
- Ne rien y supprimer sans validation explicite de Jay.
- Le relire en début de session, avec les derniers rapports.

---

## Règle impérative : catalogue des parties natives

Le fichier **`docs/parties-natives-par-os.md`** recense tout le code natif
(non-Dart) et son équivalent iOS à écrire. C'est la source de vérité du périmètre
natif, pour ne rien découvrir au dernier moment lors du portage iOS.

- **À chaque changement du code natif** (fichier `.kt`/`.swift` ajouté, supprimé
  ou renommé ; méthode de platform channel modifiée ; nouvelle capacité
  matérielle), **mettre ce fichier à jour**.
- **En fin de session**, **vérifier** que ce fichier reflète l'état réel du code
  natif ; le corriger sinon.
- Stratégie plateforme (Android d'abord, iOS additif, pas de fork) :
  `docs/strategie-multiplateforme.md`. **On développe Android d'abord** ; iOS ne
  démarre que sur décision explicite de Jay, une fois Android terminé.

---

## Stack

- **Frontend** : Flutter/Dart (choisi pour perf caméra, cohérence cross-platform, écosystème BLE)
- **Backend** : Supabase
- **State management** : Riverpod
- **Connectivité proximité** : **BLE uniquement, et uniquement pour PROUVER la
  proximité** (décision de Jay du 2026-08-27). Il ne transporte plus rien : ni
  messages, ni demandes d'ami, ni médias. *« Notre objectif n'est plus une app
  de messagerie pair-à-pair, mais une app sociale qui mise sur la proximité. »*
  **Wi-Fi Direct est abandonné** — il n'avait jamais été écrit. Tout le
  contenu passe par le serveur, avec sa livraison scellée.
- **Repo** : GitHub privé, releases taguées → APK compilés
- **Test** : APK natif Android, testé manuellement par Jay (pas de CI de test automatisé pour l'instant)

---

## Décisions verrouillées — ne pas remettre en question sans validation explicite de Jay

- **Connexions** : formées uniquement via proximité BLE ou recommandation tierce (plafond 10/mois, chaîne A→B→C). Pas de découverte par recherche/annuaire. ✅ **Reconfirmé par Jay le 2026-09-11**, malgré la vision affinée : *« la base pour devenir ami c'est soit de se connecter en étant physiquement/géographiquement proche, soit une recommandation/lien par un ami en commun »*. ⚠️ **Les activités des commerçants partenaires n'y contreviennent PAS** : on y découvre des activités à vivre, jamais des personnes à ajouter. Deux objets distincts, deux chemins distincts.
- **Le serveur PEUT voir la vidéo en clair, le temps de la traiter** (tranché par Jay le 2026-09-19 : *« J'accepte que la vidéo soit en clair sur le serveur pour qu'il puisse calculer des versions différentes, enfin faire comme les autres »*). Ce que ça change et ce que ça ne change pas : le média reste **scellé sur le stockage** et **scellé sur les téléphones** ; ce qui est nouveau, c'est **un service à nous** (le VPS tranché le 2026-08-13) qui, à la réception, déchiffre **en mémoire**, fabrique les versions (qualités, segments, couvertures) et les rescelle avec la clé du contenu — **jamais de clair écrit sur un disque serveur**. Précision d'honnêteté qui a fondé la décision : les clés sont **déjà** sur le serveur (`content_media_keys`) — « le serveur ne voit pas » voulait dire « ne regarde pas », pas « ne pourrait pas ». La promesse « ce qui se passe sur NeoVibe reste sur NeoVibe » vise la fuite vers l'EXTÉRIEUR (capture, export, stockage volé), pas notre propre serveur. Contrat : `docs/serveur-media.md` (écrit le 2026-09-19 ; **rien de construit** — il faut d'abord un VPS, décision de Jay). ⚠️ Tant que ce service n'existe pas, tout le calcul reste sur le téléphone.
- **La publication est une file NATIVE et persistante** (Jay, 2026-09-19 : *« faire comme les autres, les 5 points, même le 5ᵉ car c'est essentiel »*) : le Dart dépose une tâche et affiche son état ; un service Kotlin transcode, scelle, envoie par morceaux reprenables et enregistre, avec une notification, et survit à la fermeture de l'app. La publication apparaît tout de suite dans la grille avec sa progression ; l'export commence dès « Suivant ». ✅ **Construit le 2026-09-19** (v0.9.220) : `android/…/publish/`, `lib/core/publish/`, `PublishPreparer`, `PendingCell` — description dans `docs/file-de-publication.md`. Corollaire de rangement : le dossier d'une publication est `<filesDir>/publish/<id>/`, **jamais sous `work/`** (balayé au démarrage) ; `job.json` n'est écrit que par le service, `release.json` et `cancel` que par l'app — deux écrivains, deux fichiers.
- **Une Vibe ne se garde JAMAIS à l'insu de celui qui l'a prise** (Jay, 2026-09-20). Les brouillons (Réglages › Brouillons, 3 jours) enregistrent **d'eux-mêmes** les publications et les Flows — des imports de la galerie — mais une **Vibe**, format façon Snap souvent pris à la caméra pour un envoi privé, n'est écrite sur le disque **que si l'utilisateur choisit « Garder en brouillon »** dans la popup de sortie. Sans ce choix (app tuée, téléphone éteint, « Supprimer »), ses fichiers sont effacés au prochain démarrage. `VibeDraftKeeper` n'écrit que sur `flush()`, jamais seul.
- **Architecture éphémère** : upload en fichier temporaire, transmission côté serveur, vue unique, suppression après TTL 24h. Le replay nécessite un consentement explicite de l'émetteur, routé par le serveur. Le streaming zéro-écriture a été évalué et rejeté (trop coûteux en ressources pour le MVP) — ne pas le proposer à nouveau sans nouvelle contrainte business.
- **Vibes** (nom public depuis le 2026-08-10 ; le code et la base gardent `card`) : **3 types**, après la refonte du 2026-08-10. **Standard** — une ou deux faces, le verso est facultatif (bouton « Passer ») ; **Oneshot** — avant et arrière capturés d'un seul déclenché, caméra pure sans outils, et **sinon régi comme une standard** — à **une exception** près, tranchée par Jay le 2026-09-14 : **jamais de limite de temps de lecture** (ses seules limites : le nombre d'ouvertures et, s'il est filmé, la barre de lecture) ; et **ses deux faces filmées restent synchronisées** (un instant vu des deux côtés), là où une standard filmée des deux côtés a deux lecteurs indépendants ; **BeReal** — capture contrainte, sans post-production, déclenché par notification. Le **One of One** n'est plus un type sélectionnable : il s'applique automatiquement à l'envoi (un destinataire, aucune publication), sauf en bibliothèque partagée. **Mono et Hot sont supprimées.** ⚠️ La « vue unique puis destruction » du Oneshot **n'existe plus** — elle avait en réalité disparu dès le 2026-07-11 (migration `cards_v2_mechanics`, fonction `destroy_oneshot` supprimée) ; ce fichier l'a affirmée à tort jusqu'au 2026-08-10.
- **La sauvegarde est le CINQUIÈME contexte de diffusion** (acté par Jay le 2026-08-14). Une sauvegarde n'est pas une Vibe avec ses limites éteintes : c'est un objet distinct — octets **en clair sur l'appareil**, aucune clé, aucune règle de visionnage, aucune ligne serveur, permanent. **Ne jamais la refusionner avec la Card** ; en particulier, ne pas créer la Card au clic sur « Enregistrer pour moi ». Les quatre raisons et le seul lien admis (`SavedStore.rekey`) sont dans `docs/stockage-et-acces.md`.
- **Rétention** : streaks de proximité avec paliers de couleur et dégradation progressive ; notification FOMO "le presque" pour les quasi-rencontres physiques (différée par défaut, opt-in temps réel).
- **Anti-capture** : positionnement assumé "coûteux et visible, pas impossible" (pas de promesse d'impossibilité technique). Architecture 4 couches : flags OS, watermarking stéganographique dynamique, détection d'anomalie comportementale, couche contractuelle/sociale.

## Explicitement hors scope MVP — ne pas implémenter sans demande explicite

- **Feed algorithmique global type TikTok** (contredit la thèse du produit). ⚠️ **À ne pas confondre avec le feed LOCAL — « Pulse », construit le 2026-09-20 (`docs/feed-pulse.md`)**, dont Jay a précisé les sources le même jour : **(1) les gens croisés dans les 3 derniers jours** (leur contenu public — la géographie « ta ville » de 2026-07-26 devient la présence physique, plus fidèle à la thèse), **(2) ce que tes amis ont ajouté à ton feed** à la main (2026-09-11, anonyme jusqu'au like), **(3) ce qui a été localisé près de toi** — à l'initiative de l'auteur, jamais par défaut, ancre gommée à 100 m. Trois sources, toutes humaines ; l'ordre est « le plus récent » aujourd'hui, la pertinence se branchera dans `feed_rank` côté serveur. Et il **n'est pas infini** : le scroll se durcit (voir Positionnement — seuil à détailler par Jay). Périmètre et points de vigilance dans `docs/vision-produit.md`.
- Détection d'événements publics à grande échelle par clustering géographique (reporté — nécessite d'abord l'infrastructure de confiance). ⚠️ **À ne pas confondre avec les activités des commerçants partenaires** (2026-09-11), qui sont **déclarées** par le commerçant et non devinées par un algorithme — elles, sont dans le périmètre
- Modération IA complexe, systèmes lourds en général : privilégier des heuristiques simples validables tôt

---

## Conventions de code

- Formatage : `dart format` systématique avant de considérer une tâche terminée
- Analyse statique : `flutter analyze` doit être propre (0 erreur) avant commit
- Structure de dossiers et conventions de nommage : suivre l'existant dans le repo, ne pas réorganiser sans consigne
- Un commit = un changement logique. Messages de commit en français, format court et descriptif (pas de conventional commits imposé sauf préférence contraire de Jay)

## Sécurité

- **Ne jamais committer de clé Supabase, token, ou credential en clair.** Si une clé apparaît dans un diff, le signaler avant commit plutôt que de le committer silencieusement.
- Le MCP Supabase utilisé en session de dev doit être scopé à un projet Supabase de développement — jamais de manipulation de données de production via Claude Code.

## Méthode de travail avec Jay

- Jay tranche les décisions produit ; Claude Code exécute et peut signaler les cas limites mais ne décide pas seul sur les points listés dans "décisions verrouillées"
- Le scoping MVP se coupe agressivement : en cas de doute sur la complexité d'une fonctionnalité, proposer la version la plus simple d'abord et signaler explicitement ce qui a été simplifié
- Livrables destinés à Claude Code (specs, prompts) sont prêts à copier-coller — garder cette logique pour toute documentation produite en retour
- Travail mené en français : commentaires de code, messages de commit et rapports de session en français ; le code lui-même (noms de variables, fonctions) reste en anglais par convention Dart/Flutter standard
- **En cas de doute sur une instruction ou une vision de développement, demander à Jay avant d'agir plutôt que de supposer.** Ne pas interpréter en silence une consigne ambiguë ou incomplète — poser la question de clarification, même si ça ralentit la tâche.

---

## Règle impérative : PARLER SIMPLEMENT — Jay est débutant

*Consigne de Jay, 2026-08-28 — impérative, elle s'applique à toutes les réponses.*

> « Explique-moi les choses clairement et simplement, en gardant en tête que je
> suis débutant. »

**Ce n'est pas une préférence de style : c'est une condition pour que Jay puisse
décider.** Il tranche les décisions produit (voir plus haut). Une explication
qu'il ne peut pas suivre ne lui retire pas seulement du confort — elle lui retire
le pouvoir d'arbitrer, et il se retrouve à valider ce qu'il n'a pas compris.

### Ce qu'il faut faire

1. **Le fait d'abord, en une phrase de tous les jours.** Ce qui se passait, vu de
   son téléphone. Le nom technique vient après, s'il sert encore.
2. **Une image concrète quand le mécanisme est invisible.** Une radio, un
   veilleur de nuit, un carnet, une liste — quelque chose qui existe dans le
   monde réel. Presque tous les défauts de ce projet sont invisibles : sans
   image, il ne reste qu'un vocabulaire.
3. **Distinguer explicitement les mots qui se ressemblent.** *« App fermée »* et
   *« application tuée par Android »* ne sont pas la même chose, et c'est
   exactement ce genre de confusion qui a fait croire qu'une fonction marchait
   alors qu'elle avait un trou. **Quand deux mots proches désignent deux choses
   différentes, le dire avant de continuer.**
4. **Dire ce que ça change POUR LUI.** « Ton téléphone arrêtait de reconnaître
   tes amis pendant la nuit » vaut mieux que « le plan d'émission ne survivait
   pas à la mort du processus ».
5. **Un nom de fichier ou de fonction n'explique rien.** `refreshPlan()` ne veut
   rien dire pour lui. Le citer est utile pour retrouver l'endroit, jamais pour
   faire comprendre le problème — donc **après** l'explication, pas à la place.

### Ce qu'il ne faut pas faire

- ❌ Empiler les termes techniques en supposant qu'ils sont acquis (« provider »,
  « notifier », « RLS », « foreground service », « égalité de valeur »).
- ❌ Répondre par un tableau de symboles quand la question était « qu'est-ce que
  c'est ? ».
- ❌ Confondre **court** et **simple**. Une réponse de deux lignes pleine de
  jargon est plus dure qu'un paragraphe en français clair.
- ❌ Cacher un désaccord ou une incertitude derrière du vocabulaire.

### ⚠️ Le test à s'appliquer avant d'envoyer

**« Si Jay ne connaissait pas ce mot, sa question serait-elle répondue ? »** Si
la réponse dépend d'un terme qu'on n'a pas expliqué, elle n'est pas finie.

Et quand il dit **« je ne comprends pas »**, ce n'est pas une demande de répéter :
c'est le signe que l'explication précédente était construite pour quelqu'un
d'autre. **On recommence autrement, on ne reformule pas plus fort.**

---

## Avant de considérer une tâche terminée

1. `dart format` + `flutter analyze` propres
2. Rapport de session à jour avec les modifications de la tâche
3. Aucun secret en clair dans le diff
4. Si la tâche touche une décision verrouillée ci-dessus sans validation de Jay : s'arrêter et demander confirmation plutôt que d'implémenter
