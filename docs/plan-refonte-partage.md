# Plan — refonte du partage d'une Vibe, et le nouveau point d'entrée « publication »

> Écrit le 2026-09-13 sur demande de Jay (*« revoir le système de partage d'une
> card/vibe […] d'abord dresse un plan de la refonte. L'architecture je la
> validerai »*), **révisé le 2026-09-14** avec sa vision plus claire.
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
| Titres | « Publier sur… » → **« Publications »** ; « Conversations & groupes » → **« Amis et groupes »** |
| **Nouveau** point d'entrée pour publier | Un bouton dans la **bibliothèque du profil** : publier soit une **Card** (caméra Card **restreinte aux publications**), soit une **publication classique façon Instagram** (images ou vidéo) avec **un système d'édition dédié**. *« L'app sera comme un mixte entre Instagram et Snapchat. »* → chantier **B**, §6 |

Une rangée rapide « Ma story + 5 derniers destinataires » (question 3 du
premier plan) n'a pas été tranchée — voir §7.

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
2. *(à trancher, §7)* **La rangée rapide** : `Ma story` + les 5 derniers
   destinataires en pastilles.
3. **« Publications » ⚙︎** — deux lignes cochables, **sans réglage déplié** :
   `Ma story` · `Ma bibliothèque`. La roue ouvre le sur-écran des réglages de
   publication (§2.3).
4. **« Amis et groupes » ⚙︎** — **une** liste, cherchable (Tout / Amis /
   Groupes en segments discrets) : **Inséparables → Proches → Amis**
   (pastille de palier), puis **Groupes** (dont le chat de l'événement privé
   en cours), puis **Croisé(e)s récemment**. **Aucun réglage sur les lignes**
   — juste la coche. La roue ouvre le sur-écran des réglages d'envoi (§2.3).
5. **La barre d'envoi** : « Envoyer · N » (+ « 2 fichiers » si les réglages
   font plus d'une Card). « Enregistrer pour moi » à côté, hors du plan.

### 2.3 Les deux sur-écrans de réglage — « une branche, pas une étape »

Optionnels : on peut envoyer sans jamais les ouvrir, les défauts s'appliquent.

**⚙︎ Publications**

| Bloc | Réglages |
|---|---|
| Ma story | visible par (palier) · partageable · sauvegardable |
| Ma bibliothèque | visible par les gens croisés · partageable · sauvegardable · légende |
| bouton **« Défauts »** | enregistre ces valeurs comme mes défauts de publication |

**⚙︎ Amis et groupes**

| Bloc | Réglages |
|---|---|
| En haut, pour tout l'envoi | limites de vues · durée par face (elles sont portées par la Card, donc communes — inchangé) |
| **La liste des sélectionnés, et eux seuls** | une ligne par ami / groupe coché, avec **« Sauvegardable »** ; pour un groupe, aussi « Aussi dans la bibliothèque du groupe » |
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

---

## 3. L'architecture — chantier A

Trois étages, jamais mélangés.

| Étage | Objet | Rôle | Ne fait jamais |
|---|---|---|---|
| **Cuisine** | `RecipientSource` | publie **fidèlement** : mes amis (avec palier, `friendshipsProvider`), mes groupes (conversations collectives, événement privé en cours compris), mes croisés (`crossedRecentlyProvider`) | trier, filtrer |
| **Cuisine** | `ShareDefaultsRepository` | **lit et écrit les défauts** : par ami (**serveur**, table `friend_share_defaults(owner_id, friend_id, saveable)`, RLS propriétaire seul — un défaut par ami doit suivre le compte, pas l'appareil) et généraux (prefs de l'app, comme `defaultMaxViewsProvider` aujourd'hui) | décider ce qu'affiche l'écran |
| **Cuisine** | `RecentRecipientsStore` *(si §7 = oui)* | derniers destinataires, sur le disque, écrit **à l'envoi réussi** | — |
| **Cuisine** | `ShareQueue` | exécute un `SharePlan` en arrière-plan (l'actuel `SharePublisher`, devenu une file observable) ; avancement et échecs par destination ; **Réessayer** une destination | dessiner, naviguer |
| **Serveur** | `recipientsProvider` (`DerivedList`) | la **vue** : (récents →) inséparables → proches → amis → groupes → croisés ; recherche et segment ; ne réveille l'écran que si la liste change | aller chercher |
| **Serveur** | `shareDefaultsProvider` | **résout** l'ordre des trois niveaux (§2.4) pour un ami donné : « quel réglage quand je coche Léa ? » | écrire |
| **Serveur** | `ShareContext` | ce qu'on partage et ce qui est permis : Vibe neuve / depuis un chat (pré-coché) / repartage (amis et groupes seulement) | — |
| **Client** | `RecipientPickerScreen` | **le seul écran « à qui »** ; reçoit un `ShareContext`, rend un `SharePlan` ; remplace les cinq listes | réseau, disque |
| **Client** | `PublicationSettingsSheet` | ⚙︎ Publications (+ « Défauts ») | — |
| **Client** | `RecipientSettingsSheet` | ⚙︎ Amis et groupes : limites, les sélectionnés avec « Sauvegardable », « Tout sélectionner », « Défauts » | — |
| **Client** | `ShareSettingsScreen` | l'entrée dans les Réglages de l'app : défauts généraux + la liste de mes amis avec leur défaut | — |
| **Client** | `ShareProgressBanner` | le bandeau d'envoi sur la caméra, observe `ShareQueue` | — |

**Ce qui ne bouge pas** : `SharePlan` et ses lots ; `VibeDraft` ; les dépôts
(`CardsRepository`, `StoriesRepository`, `LibraryRepository`,
`LibraryVibesRepository`) ; les règles d'accès serveur.

**Serveur** : **une** table nouvelle (`friend_share_defaults`), propriétaire
seul. Aucune autre migration.

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
| **A1. La liste juste** | `RecipientSource` + `recipientsProvider` ; les lignes perdent leurs réglages (ils passent, provisoirement, dans la feuille existante) ; titres renommés | tous ses amis, les plus proches en haut ; des lignes propres |
| **A2. Les deux roues ⚙︎** | `PublicationSettingsSheet`, `RecipientSettingsSheet` (sélectionnés seuls, « Tout sélectionner ») ; `SharePlan` inchangé | les réglages centralisés, l'envoi sans les ouvrir |
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

1. **La rangée rapide** (« Ma story » + 5 derniers destinataires) — oui ou non ?
   Recommandation : oui.
2. **Les défauts par ami** : j'ai compris « un réglage par ami, qui suit mon
   compte » (donc **serveur**, une table). C'est bien ça ? Et ils portent
   **« Sauvegardable » seulement** (les limites de vues restant communes à
   l'envoi) ?

**Chantier B** (à cadrer avant B2, pas maintenant)

3. **La publication classique** : une seule image / plusieurs (carrousel) /
   une vidéo ? Légende ? Quel format d'image (carré, portrait, libre) ?
4. **L'éditeur dédié** : quoi dedans au minimum — recadrage, ordre, texte ?
   Filtres ? Musique ? *(chaque item est un chantier)*
5. **La caméra « restreinte aux publications »** : Card standard seulement, ou
   Oneshot aussi ? (le BeReal est déclenché, il n'entre pas ici)

---

## 8. Ce que ce plan prépare, sans le faire

- **« Ajouter au feed » et l'ajout anonyme** (vision §6.4–6.5) : une ligne de
  plus dans `RecipientPickerScreen` en mode repartage ; le régime anonyme /
  nommé selon le palier s'affichera sur la ligne, avant d'envoyer.
- **Le reveal comme option d'envoi** (`RAPPELS.md` #110) et **la story
  publique par story** (#108) : des cases de plus dans ⚙︎ Publications, le
  jour où la mécanique existera.
