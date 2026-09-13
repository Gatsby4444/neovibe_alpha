# Plan — refonte du partage d'une Vibe, et le nouveau point d'entrée « publication »

> Écrit le 2026-09-13 sur demande de Jay (*« revoir le système de partage d'une
> card/vibe […] d'abord dresse un plan de la refonte. L'architecture je la
> validerai »*), **révisé le 2026-09-14** avec sa vision plus claire (deux
> séries de précisions).
>
> **Rien n'est codé.** Ce document décrit ce qui existe (relevé dans le code le
> 2026-09-13), ce que Jay a tranché, l'architecture, l'ordre de construction,
> et ce qui reste à trancher.

---

## 0. Ce que Jay a tranché le 2026-09-14

| Sujet | Décision |
|---|---|
| Un seul « Sauvegardable » pour tout l'envoi ? | **Non.** Il reste **par personne** — mais il **quitte les lignes**. Les réglages sont **centralisés** derrière deux roues ⚙︎ (§2.3) |
| Retour à la caméra après l'envoi | **Oui** |
| Le chat d'un événement privé listé comme un groupe | **Oui** |
| Réglages **par défaut** | L'utilisateur règle ses défauts **par ami** — depuis les sur-écrans de réglage (bouton « Défauts ») **ou** depuis les Réglages généraux de l'app (nouvelle entrée) |
| Titres | « Publier sur… » → **« Publier »** ; « Conversations & groupes » → **« Groupes et amis »** |
| **Nouveau** point d'entrée pour publier | Un bouton dans la **bibliothèque du profil** : publier soit une **Card** (caméra Card **restreinte aux publications**), soit une **publication classique façon Instagram** (images ou vidéo) avec **un système d'édition dédié**. *« L'app sera comme un mixte entre Instagram et Snapchat. »* → chantier **B**, §6 |
| Rangée rapide « Ma story + 5 derniers » | **Non.** Deux sous-sections, « Publier » et « Groupes et amis » |
| L'ordre de « Groupes et amis » | **Comme sur Snap** : les **10 amis les plus proches** en tableau 2 colonnes (pseudo tronqué, coche) · puis **les groupes**, triés par ma **participation** la plus récente (message, Vibe, réaction — pas encore codée) · puis **tous les amis et tous les groupes**, une colonne, par interaction la plus récente |
| Les limites de vues / durée | **communes et centralisées, mais par section** : un réglage pour la story, un pour la publication, un pour le partage aux groupes et amis — **jamais par ami ou par groupe** |
| Un événement en cours | un bouton **« nom de l'événement »** tout en haut, **avant** « Publier » ; coché = partage dans la **bibliothèque du groupe d'événement** |
| Chat ou bibliothèque, pour un groupe ? | question ouverte par Jay ; ma proposition en §2.7 |

---

## 1. Ce qui existe aujourd'hui — relevé dans le code (2026-09-13)

### 1.1 Le parcours

```
capture recto → (verso ou « Passer ») → RÉCAP (les deux faces, modifier / refaire)
   → « Continuer » → ÉCRAN DE PARTAGE → « Partager ma Vibe · N » → attente (rond)
   → retour à l'ACCUEIL + « Envoyé à N ✓ »
```

`card_capture_screen.dart` (`_RecapStep`) → `send/share_screen.dart`
→ `send/share_publisher.dart`.

### 1.2 Ce qu'on garde tel quel

Un seul geste pour plusieurs destinations ; **un objet par contexte**
(`SharePlan`, pur et éprouvé, et ses **lots** : une Card par jeu de réglages
distinct) ; l'échec par destination, jamais « envoyé » quand une a échoué ; le
coût annoncé avant d'appuyer (`televersements`) ; la règle du 1/1 ;
« Enregistrer pour moi » hors du plan ; **aucune règle serveur d'accès
touchée**.

### 1.3 Ce qui freine — sept constats

| # | Constat | Où |
|---|---|---|
| 1 | **Cinq listes « à qui »** : `ShareScreen`, `CircleSettingsScreen` (depuis un chat), `LibraryShareScreen`, et deux `_ConversationPicker` recopiés (`story_viewer_screen`, `publication_viewer_screen`) | ces fichiers |
| 2 | **L'écran liste les CONVERSATIONS, pas les AMIS** : un ami sans chat n'apparaît pas — alors que `friendshipsProvider` connaît tous mes amis avec leur palier et que `get_or_create_direct_conversation` sait ouvrir le DM à l'envoi | `_Conversations` |
| 3 | **Aucun tri par proximité** (ordre = dernière activité) ; la vision dit « les plus proches en haut au partage » | `conversationsProvider` |
| 4 | **Deux écrans** avant d'envoyer (récap, puis partage) | `_RecapStep` |
| 5 | **On attend l'envoi** (rond), puis retour à l'accueil | `_envoyer` |
| 6 | **Les réglages sont sur les lignes** (« Sauvegardable », « Aussi dans la bibliothèque » par ligne ; palier / partageable / sauvegardable dépliés sous la story) — c'est ce qui « perturbe » | `_LigneConversation`, `_Reglages*` |
| 7 | **Rien ne mémorise** à qui on envoie d'habitude, ni ce qu'on règle d'habitude pour tel ami | — |

---

## 2. La cible — chantier A, le partage d'une Card

### 2.1 Le parcours

```
capture → [flèche] → UN écran « À qui ? » → [Envoyer] → retour CAMÉRA immédiat
                                              (l'envoi part en arrière-plan)
```

### 2.2 L'écran « À qui ? », de haut en bas

1. **La Vibe en petit**, retournable — le récap intégré. Toucher = modifier /
   refaire. Le type en badge.
2. **« Nom de l'événement »** — *seulement si je suis dans un événement* : un
   bouton cochable, tout en haut. Coché = la Vibe va dans la **bibliothèque du
   groupe d'événement** (voir §2.7 pour le chat).
3. **« Publier » ⚙︎** — deux petits boutons alignés, cochables : `Story` ·
   `Bibliothèque`. Ils prennent une ligne. La roue ouvre les réglages de
   publication (§2.3).
4. **« Groupes et amis » ⚙︎** — trois blocs, dans cet ordre, une seule liste
   qui défile :
   - **Les 10 plus proches** — tableau **2 colonnes**, avatar + pseudo
     tronqué + coche. « Proche » = palier (inséparables → proches → amis),
     départagé par l'interaction la plus récente.
   - **Les groupes** — une colonne, triés par **ma participation la plus
     récente** (mon dernier message, ma dernière Vibe ; les réactions quand
     elles existeront). Le chat de l'événement privé en cours y figure.
   - **Tout le monde** — une colonne, tous les amis et tous les groupes,
     par **interaction la plus récente** (le dernier message du fil, de qui
     que ce soit).
   - **Croisé(e)s récemment** en dessous (inchangé : une demande d'ami qui
     porte la Vibe).
   **Aucun réglage sur les lignes** — la coche, et pour un groupe le choix
   chat / bibliothèque (§2.7). La recherche filtre les trois blocs.
5. **La barre d'envoi** : « Envoyer · N » (+ « 2 fichiers » si les réglages
   font plus d'une Card). « Enregistrer pour moi » à côté, hors du plan.

### 2.3 Les deux sur-écrans de réglage — « une branche, pas une étape »

Optionnels : on peut envoyer sans jamais les ouvrir, les défauts s'appliquent.
**Chaque section a SES réglages**, jamais partagés avec l'autre.

**⚙︎ Publier**

| Bloc | Réglages |
|---|---|
| Story | visible par (palier) · partageable · sauvegardable *(+ durée d'affichage par face ? — §7)* |
| Bibliothèque | visible par les gens croisés · partageable · sauvegardable · légende |
| bouton **« Défauts »** | enregistre ces valeurs comme mes défauts de publication |

**⚙︎ Groupes et amis**

| Bloc | Réglages |
|---|---|
| En haut, **pour tout l'envoi de cette section** | limites de vues · durée par face (portées par la Card, donc communes à tous les destinataires de l'envoi) |
| **La liste des sélectionnés, et eux seuls** | une ligne par ami / groupe coché, avec **« Sauvegardable »** |
| bouton **« Tout sélectionner »** | coche « Sauvegardable » pour tous d'un coup |
| bouton **« Défauts »** | enregistre le réglage de **chaque** ami affiché comme **son** défaut (« pour Léa, toujours sauvegardable ») |

➡️ Le coût reste honnête : deux amis avec un `saveable` différent = deux
Cards = deux montées, **annoncé dans la barre** avant d'appuyer, comme
aujourd'hui.

### 2.4 Les défauts — trois niveaux, un seul ordre

Quand on coche un ami, son réglage vient, dans l'ordre :

1. **son défaut à lui** (« pour Léa : sauvegardable ») s'il existe ;
2. sinon **mon défaut général** (Réglages de l'app → « Partage », nouvelle
   entrée) ;
3. sinon le **défaut du produit** (non sauvegardable ; limites = celles
   déjà dans les Réglages).

Les deux sur-écrans et l'entrée des Réglages écrivent **la même chose au même
endroit** : un réglage a un seul propriétaire, jamais deux copies.

### 2.5 Après « Envoyer »

Retour **à la caméra tout de suite**. Bandeau fin en bas : « Envoi… 1/3 »,
puis disparaît. Une destination échoue → le bandeau reste, la nomme, propose
**Réessayer** (elle seule).

### 2.6 Le même écran partout

- **Depuis un chat** (bouton Vibe) : ce chat **pré-coché**, modifiable.
- **Depuis une story / une publication** (repartage) : même écran, en mode
  « repartage » — amis et groupes seulement (un repartage est un chemin vers la
  source, jamais une copie). **C'est ce qui prépare le feed** : « ajouter au
  feed de l'autre » sera une ligne de plus, ici.
- **Bibliothèque de groupe** : même liste pour la partie « à qui ».

### 2.7 Chat ou bibliothèque ? — la question de Jay, et ma proposition

**Le constat** : envoyer une Vibe *dans le chat* d'un groupe et l'*ajouter à
sa bibliothèque* sont deux gestes qui n'ont ni le même sens ni le même objet.
Le chat, c'est « regarde ça maintenant » ; la bibliothèque, c'est « on
construit une collection ensemble, révélée à l'heure du reveal ». Deux
intentions, deux objets (`cards` / `library_vibes`), deux cycles de vie. Et
**les DM ont aussi une bibliothèque** (le bouton « + » du chat existe pour les
deux) — la question vaut donc pour les amis autant que pour les groupes.

**Ce qui ne va pas aujourd'hui** : le choix est un interrupteur caché sous la
ligne (« Aussi dans la bibliothèque du groupe »), donc invisible tant qu'on
n'a pas coché, et formulé comme une option de l'envoi alors que c'est une
destination.

**Ce que je propose** : sur une ligne de groupe (et de DM), **pas une coche
mais deux cibles côte à côte**, à droite du nom :

```
  [avatar]  Les Copains du jeudi          [ 💬 ]  [ 📚 ]
```

- 💬 = dans le chat (le défaut : un tap sur la ligne coche 💬) ;
- 📚 = dans la bibliothèque (révélée au reveal) ;
- les deux cochées = les deux (deux objets, comme aujourd'hui).

C'est **une destination par cible**, exactement ce que la règle « un objet,
un contexte » demande — et ça se voit avant de cocher, pas après. Ce n'est
pas un réglage sur la ligne : c'est le choix de *où* ça va, qui appartient à
la ligne. Le sur-écran ⚙︎ ne garde que ce qui est un réglage (« Sauvegardable »).

**Pour l'événement en haut** : la même ligne à deux cibles, avec 📚 cochée
par défaut (c'est ce que Jay décrit) et 💬 disponible — le chat de
l'événement est une conversation comme les autres. Un seul mécanisme pour
les trois cas (événement, groupe, DM) au lieu de trois façons de dire la même
chose.

**Alternative écartée** : deux lignes par groupe (« Groupe X » et
« Bibliothèque de Groupe X ») — ça double la liste pour dire ce que deux
icônes disent en une ligne.

---

## 3. L'architecture — chantier A

Trois étages, jamais mélangés.

| Étage | Objet | Rôle | Ne fait jamais |
|---|---|---|---|
| **Cuisine** | `RecipientSource` | publie **fidèlement** : mes amis (avec palier, `friendshipsProvider`), mes groupes (conversations collectives, événement privé en cours compris), mes croisés (`crossedRecentlyProvider`) | trier, filtrer |
| **Cuisine** | `InteractionSource` | publie, **par conversation**, deux dates : **ma** dernière participation (mon dernier message, Vibe comprise — les réactions quand elles existeront) et la **dernière activité** du fil (dernier message de qui que ce soit). Une requête serveur (`conversation_activity()`), pas un calcul d'écran | décider de l'ordre |
| **Cuisine** | `ShareDefaultsRepository` | **lit et écrit les défauts** : par ami (**serveur**, table `friend_share_defaults(owner_id, friend_id, saveable)`, RLS propriétaire seul — un défaut par ami doit suivre le compte, pas l'appareil) et généraux (prefs de l'app, comme `defaultMaxViewsProvider` aujourd'hui) | décider ce qu'affiche l'écran |
| **Cuisine** | `ShareQueue` | exécute un `SharePlan` en arrière-plan (l'actuel `SharePublisher`, devenu une file observable) ; avancement et échecs par destination ; **Réessayer** une destination | dessiner, naviguer |
| **Serveur** | `recipientsProvider` (`DerivedList`) | la **vue** en trois blocs : les 10 plus proches (palier, puis interaction) · les groupes (par ma participation) · tout le monde (par dernière activité) · croisés ; la recherche ; ne réveille l'écran que si la liste change | aller chercher |
| **Serveur** | `shareDefaultsProvider` | **résout** l'ordre des trois niveaux (§2.4) pour un ami donné : « quel réglage quand je coche Léa ? » | écrire |
| **Serveur** | `ShareContext` | ce qu'on partage et ce qui est permis : Vibe neuve / depuis un chat (pré-coché) / repartage (amis et groupes seulement) | — |
| **Client** | `RecipientPickerScreen` | **le seul écran « à qui »** ; reçoit un `ShareContext`, rend un `SharePlan` ; remplace les cinq listes | réseau, disque |
| **Client** | `PublicationSettingsSheet` | ⚙︎ Publier (+ « Défauts ») | — |
| **Client** | `RecipientSettingsSheet` | ⚙︎ Groupes et amis : limites de cette section, les sélectionnés avec « Sauvegardable », « Tout sélectionner », « Défauts » | — |
| **Client** | `DualTargetRow` | la ligne à deux cibles 💬 / 📚 (groupe, DM, événement) — §2.7 | — |
| **Client** | `ShareSettingsScreen` | l'entrée dans les Réglages de l'app : défauts généraux + la liste de mes amis avec leur défaut | — |
| **Client** | `ShareProgressBanner` | le bandeau d'envoi sur la caméra, observe `ShareQueue` | — |

**Ce qui ne bouge pas** : `SharePlan` et ses lots ; `VibeDraft` ; les dépôts
(`CardsRepository`, `StoriesRepository`, `LibraryRepository`,
`LibraryVibesRepository`) ; les règles d'accès serveur.

**Serveur** : **une** table nouvelle (`friend_share_defaults`, propriétaire
seul) et **une** fonction de lecture (`conversation_activity()` : par
conversation dont je suis membre, la date de mon dernier message et celle du
dernier message). Aucune règle d'accès touchée.

**Le compte des chemins** :

| | avant | après |
|---|---|---|
| écrans qui choisissent « à qui » | 5 | **1** |
| sources de la liste | conversations | amis + groupes + croisés |
| endroits où vit un réglage d'envoi | 4 (lignes, sections, feuille, prefs) | **2 sur-écrans + 1 entrée Réglages**, qui écrivent au **même** endroit |

---

## 4. L'ordre de construction — chantier A, chaque étape livrable seule

| Étape | Quoi | Ce que Jay verra |
|---|---|---|
| **A1. La liste juste** | `RecipientSource` + `InteractionSource` (`conversation_activity()`) + `recipientsProvider` ; les trois blocs (10 plus proches en grille, groupes, tout le monde) ; le bouton événement en haut ; les lignes perdent leurs réglages (ils passent, provisoirement, dans la feuille existante) ; titres « Publier » / « Groupes et amis », boutons Story · Bibliothèque alignés | tous ses amis, les plus proches en grille, les groupes où il parle ; des lignes propres |
| **A2. Les deux roues ⚙︎ et la ligne à deux cibles** | `PublicationSettingsSheet`, `RecipientSettingsSheet` (sélectionnés seuls, « Tout sélectionner », limites par section) ; `DualTargetRow` 💬 / 📚 (si validée, §7) ; `SharePlan` inchangé | les réglages centralisés, l'envoi sans les ouvrir |
| **A3. Les défauts** | `friend_share_defaults` (migration, RLS rejouée) ; `ShareDefaultsRepository`, `shareDefaultsProvider` ; boutons « Défauts » ; `ShareSettingsScreen` dans les Réglages | « pour Léa, toujours sauvegardable », et une page Réglages → Partage |
| **A4. Un seul écran** | `ShareContext` + `RecipientPickerScreen` ; les cinq listes rebranchées ; suppression des quatre autres (règle 8 : relever les deux sens avant de couper) | le même écran depuis un chat, une story, une publication |
| **A5. Le récap dans l'écran** | la Vibe en haut, retournable, « modifier » ; `_RecapStep` supprimé | un écran de moins |
| **A6. L'envoi en arrière-plan** | `ShareQueue` + `ShareProgressBanner` ; retour caméra ; Réessayer par destination | on envoie, on est déjà revenu à la caméra |

Chaque étape = un commit, une version, un test sur le téléphone.

---

## 5. Ce que ce plan retire (chantier A)

- Les réglages **sur les lignes** (ils vont dans les roues).
- `CircleSettingsScreen`, `LibraryShareScreen` (partie « à qui »), les deux
  `_ConversationPicker`.
- Le retour à l'accueil après envoi.
- `_RecapStep` comme écran séparé.

---

## 6. Chantier B — le point d'entrée « publication » (Instagram × Snapchat)

*Nouveau, 2026-09-14. Séparé du chantier A : ce n'est pas le partage d'une
Card, c'est une **autre façon de produire** un contenu de bibliothèque.*

**Ce que Jay décrit** : un bouton dans la **bibliothèque du profil** →

| Choix | Ce qui s'ouvre | Ce qui en sort |
|---|---|---|
| **Une Card** | la caméra Card **restreinte aux publications** : pas de story, pas d'amis — la destination est imposée (comme l'envoi depuis un chat, dans l'autre sens) | une publication de bibliothèque, l'objet existant (`library`) |
| **Une publication classique** | un **éditeur dédié aux publications** : images ou vidéo, depuis la galerie ou la caméra | un **nouvel objet** — une publication « post », **pas** une Card |

**Ce qui est déjà là** : le contexte `publication` du socle (`contents`,
bucket `library`, `library_read_via_acl`, la grille du profil, la visionneuse)
et la caméra Card avec `ShareContext` restreint (chantier A) suffisent au
premier choix — **c'est une entrée de plus, pas un objet de plus**.

**Ce qui est neuf, et lourd** : le second choix. Une publication « post »
(une ou plusieurs images, ou une vidéo, avec légende, sans recto/verso, sans
limite de vues) est un **objet distinct** de la Card (règle 2 : deux objets aux
règles différentes ne partagent pas la table) — et son **éditeur** est un
produit en soi (recadrage, ordre des images, filtres ?, texte ?, musique ?).

⚠️ **Le test de la grille de décision** (« ce contenu a-t-il obligé quelqu'un
à sortir de chez lui ? ») s'applique ici avec force : une publication depuis
la galerie n'a coûté aucune sortie. La vision l'assume (*« il nous faut du
contenu »*, §6.1) — mais c'est **le** point à garder en tête en dessinant
l'éditeur : ce qu'il met en avant, c'est ce que le feed montrera.

**Ordre proposé** : chantier A d'abord (il livre `ShareContext`, que le
premier choix de B réutilise), puis **B1** = le bouton + le choix + la caméra
Card restreinte (petit, réutilise tout), puis **B2** = l'objet « post » et son
éditeur, **après un cadrage à part** (§7).

---

## 7. Ce qui reste à trancher

**Chantier A**

1. **La ligne à deux cibles 💬 / 📚** (§2.7) pour les groupes, les DM et
   l'événement — validée ? Et pour l'événement, 📚 coché par défaut, 💬
   disponible ?
2. **Les défauts par ami** : « un réglage par ami qui suit mon compte » →
   stocké **serveur** (table `friend_share_defaults`, visible par moi seul),
   et il porte **« Sauvegardable » seulement** — c'est bien ça ?
3. **Les réglages de la story** : aujourd'hui une story n'a **ni limite de
   vues ni durée par face** (elle vit 24 h, une photo s'affiche le temps
   standard). « Des réglages différents par section » veut-il dire que la story
   doit **gagner** une durée d'affichage par face (nouvelle mécanique,
   `stories.view_duration`), ou seulement que chaque section garde **ses**
   réglages propres (palier / partageable / sauvegardable pour la story) ?

**Chantier B** (à cadrer avant B2, pas maintenant)

4. **La publication classique** : une seule image / plusieurs (carrousel) /
   une vidéo ? Légende ? Quel format d'image (carré, portrait, libre) ?
5. **L'éditeur dédié** : quoi dedans au minimum — recadrage, ordre, texte ?
   Filtres ? Musique ? *(chaque item est un chantier)*
6. **La caméra « restreinte aux publications »** : Card standard seulement, ou
   Oneshot aussi ? (le BeReal est déclenché, il n'entre pas ici)

---

## 8. Ce que ce plan prépare, sans le faire

- **« Ajouter au feed » et l'ajout anonyme** (vision §6.4–6.5) : une ligne de
  plus dans `RecipientPickerScreen` en mode repartage ; le régime anonyme /
  nommé selon le palier s'affichera sur la ligne, avant d'envoyer.
- **Le reveal comme option d'envoi** (`RAPPELS.md` #110) et **la story
  publique par story** (#108) : des cases de plus dans ⚙︎ Publications, le
  jour où la mécanique existera.
