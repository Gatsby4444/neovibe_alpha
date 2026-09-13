# Plan — refonte du partage d'une Vibe

> Écrit le 2026-09-13 sur demande de Jay : *« il faut encore une fois revoir le
> système de partage d'une card/vibe car ce système n'est pas encore assez
> fluide et pratique. Tu as carte blanche mais d'abord dresse un plan de la
> refonte. L'architecture je la validerai. »*
>
> **Rien n'est codé.** Ce document décrit ce qui existe (relevé dans le code le
> 2026-09-13), ce qui freine, la cible, l'architecture, l'ordre de
> construction, et les questions à trancher. Jay valide, puis on construit.

---

## 1. Ce qui existe aujourd'hui — relevé dans le code

### 1.1 Le parcours, tel qu'il est

```
capture recto → (verso ou « Passer ») → RÉCAP (les deux faces, modifier / refaire)
   → « Continuer » → ÉCRAN DE PARTAGE → « Partager ma Vibe · N » → attente (rond)
   → retour à l'ACCUEIL + « Envoyé à N ✓ »
```

`card_capture_screen.dart` (`_RecapStep`, ~l. 2560) → `send/share_screen.dart`
→ `send/share_publisher.dart`.

### 1.2 L'écran de partage (`share_screen.dart`, 1 114 lignes)

De haut en bas : bandeau 1/1 si besoin · recherche · trois filtres (Tout /
Ami(e)s / Groupes) · **« Publier sur… »** (Ma story, Ma bibliothèque — avec
leurs réglages dépliés quand cochées) · **« Conversations & groupes »** (une
ligne par conversation existante, avec « Sauvegardable » et « Aussi dans la
bibliothèque du groupe » par ligne) · **« Croisé(e)s récemment »** · « Pour les
personnes » (limites de vues / durée) · « Enregistrer pour moi » · barre
d'envoi.

Ce qui est **bien** et qu'on garde : un seul geste pour plusieurs destinations
(2026-08-30) ; un objet par contexte (`SharePlan`, pur et éprouvé) ; l'échec par
destination, jamais « envoyé » quand une a échoué ; le coût annoncé avant
d'appuyer (`televersements`) ; la règle du 1/1 ; « Enregistrer pour moi » hors
du plan.

### 1.3 Ce qui freine — sept constats

| # | Constat | Où c'est vérifié |
|---|---|---|
| 1 | **Quatre listes « à qui » différentes** : après capture (`ShareScreen`), depuis un chat (`CircleSettingsScreen`, destination imposée), bibliothèque de groupe (`LibraryShareScreen`), et **deux** `_ConversationPicker` recopiés dans `story_viewer_screen.dart` et `publication_viewer_screen.dart` pour le repartage. Quatre logiques de liste, quatre façons de se tromper — règle « un chemin, une donnée » de `CLAUDE.md` non respectée | les cinq fichiers |
| 2 | **L'écran liste les CONVERSATIONS, pas les AMIS.** Un ami avec qui on n'a jamais discuté n'apparaît pas ; il faudrait d'abord lui ouvrir un chat ailleurs. Pourtant `CardsRepository.send` sait créer le DM à la volée (`get_or_create_direct_conversation`), et `friendshipsProvider` connaît tous mes amis avec leur palier | `_Conversations` → `conversationsProvider` |
| 3 | **Aucun tri par proximité.** L'ordre est « dernière activité de la conversation ». La vision (paliers, 2026-09-12) dit : *« ça remonte les plus proches en haut de la liste au partage »*. `RAPPELS.md` le note comme non construit | `conversationsProvider` (tri sur `lastMessage`) |
| 4 | **Deux écrans avant d'envoyer.** Le récap montre ce qu'on vient de prendre, puis « Continuer ». Sur Snap : capture → flèche → destinataires. Un écran de plus à chaque envoi | `_RecapStep` |
| 5 | **On attend l'envoi.** Un rond tourne sur l'écran de partage jusqu'à ce que tout soit parti (story + bibliothèque + une Card par lot + livraisons) ; puis retour à l'accueil, pas à la caméra. Une vidéo de 20 Mo en story + groupe, c'est deux montées à regarder | `_envoyer`, `popUntil(isFirst)` |
| 6 | **Trop d'interrupteurs, au mauvais endroit.** Par ligne cochée : « Sauvegardable », « Aussi dans la bibliothèque du groupe » ; par publication : palier, « Partageable », « Sauvegardable », « Visible par les gens que tu croises » ; en bas : limites de vues. **Et un réglage différent par personne coûte une Card de plus, donc une montée de fichier de plus** (`lotsDeCercle`). Le contraire du « défaut juste, pas l'option supplémentaire » | `_LigneConversation`, `_ReglagesStory`, `_ReglagesBibliotheque` |
| 7 | **Rien ne mémorise à qui on envoie d'habitude.** Pas de « récents », pas de raccourci « Ma story » : à chaque envoi, on cherche | absence dans `share_screen.dart` |

---

## 2. La cible — le partage en trois gestes

```
capture → [flèche] → UN écran « À qui ? » → [Envoyer] → retour CAMÉRA immédiat
                                              (l'envoi part en arrière-plan)
```

**L'écran « À qui ? »**, de haut en bas :

1. **La Vibe en petit, en haut** (recto, retournable) — c'est le récap intégré.
   Toucher = modifier / refaire. Le type (Standard / Oneshot / BeReal) est un
   badge dessus.
2. **La rangée rapide** : `Ma story` · puis les **5 derniers destinataires**
   (personnes ou groupes) en pastilles. Un tap = coché.
3. **La liste**, une seule, cherchable, avec trois onglets discrets (Tout /
   Amis / Groupes) :
   - **Inséparables**, puis **Proches**, puis **Amis** — le palier trie et
     s'affiche (pastille de couleur déjà existante, `TierAvatar`) ;
   - **Groupes** (et le chat d'un événement privé en cours, s'il y en a un) ;
   - **Croisé(e)s récemment** (inchangé : une demande d'ami qui porte la Vibe) ;
   - **Ma bibliothèque** (publication permanente) — une ligne parmi les autres,
     pas une section à part.
4. **Un seul bouton ⚙︎ « Options »** en haut à droite, qui ouvre une feuille :
   limites de vues et durée (pour les personnes), « les destinataires peuvent
   enregistrer » (pour tout l'envoi), « visible par » de la story (palier),
   visibilité de la publication, « aussi dans la bibliothèque du groupe ».
   **Aucun réglage sur les lignes.**
5. **La barre d'envoi** : « Envoyer · N » + le coût s'il dépasse une montée
   (« 2 fichiers »). « Enregistrer pour moi » reste à côté, hors du plan.

**Après « Envoyer »** : on revient **à la caméra tout de suite**. Un bandeau
fin en bas dit « Envoi… 1/3 » puis disparaît. Si une destination échoue, le
bandeau reste, nomme ce qui a échoué, et propose **Réessayer** (cette
destination seule) — jamais « tout renvoyer ».

**Depuis un chat** (bouton Vibe) : même écran, le chat **pré-coché en tête**,
modifiable — on peut ajouter d'autres destinataires. Fini l'écran réduit à
part.

**Depuis une story ou une publication** (repartage) : même écran, en mode
« repartage » — les lignes sont les mêmes, seule la liste des destinations
permises change (pas de story, pas de bibliothèque : un repartage est un chemin
vers la source, jamais une copie). **C'est ce qui prépare le feed** : le jour où
« partager » deviendra « ajouter au feed de l'autre » (§6.4 de la vision), c'est
ce même écran qui le fera, avec une ligne de plus.

---

## 3. L'architecture — ce qu'il faut construire

Trois étages, jamais mélangés (règle « on sépare tout ce qui peut l'être »).

| Étage | Objet | Rôle | Ne fait jamais |
|---|---|---|---|
| **Cuisine** | `RecipientSource` | publie **fidèlement** trois listes brutes : mes amis (avec palier, depuis `friendshipsProvider`), mes groupes (depuis `conversationsProvider`, collectifs seulement), mes croisés (depuis `crossedRecentlyProvider`) | trier, filtrer, décider de l'affichage |
| **Cuisine** | `RecentRecipientsStore` | mémorise sur le disque les derniers destinataires (identifiant + date), ~20 lignes ; écrit **à l'envoi réussi**, jamais par l'écran | décider combien en montrer |
| **Cuisine** | `ShareQueue` | **exécute** un `SharePlan` en arrière-plan (c'est l'actuel `SharePublisher`, qui devient une file observable) : un travail = un plan ; publie l'avancement destination par destination et les échecs ; permet **Réessayer** une destination | dessiner, décider de la navigation |
| **Serveur** | `recipientsProvider` (`DerivedList`) | assemble la **vue** : récents → inséparables → proches → amis → groupes → croisés → bibliothèque ; applique la recherche et l'onglet ; ne réveille l'écran que si la liste change (égalité de valeur) | aller chercher lui-même |
| **Serveur** | `ShareContext` | dit **ce qu'on partage et ce qui est permis** : une Vibe neuve (tout est permis), une Vibe depuis un chat (le chat pré-coché), un repartage (personnes et groupes seulement). Un seul objet décide des destinations possibles, au lieu de quatre écrans | — |
| **Client** | `RecipientPickerScreen` | **le seul écran « à qui »** de l'app. Reçoit un `ShareContext`, rend un `SharePlan`. Remplace `ShareScreen`, `CircleSettingsScreen`, `LibraryShareScreen` (partie « à qui »), et les deux `_ConversationPicker` | parler au réseau ou au disque |
| **Client** | `ShareOptionsSheet` | la feuille ⚙︎ : les réglages, tous, en un endroit | — |
| **Client** | `ShareProgressBanner` | le bandeau d'envoi en bas de la caméra, qui observe `ShareQueue` | — |

**Ce qui ne bouge pas** : `SharePlan` (pur, éprouvé) — il perd les réglages
par ligne et gagne un `saveable` global ; `VibeDraft` ; les dépôts
(`CardsRepository`, `StoriesRepository`, `LibraryRepository`,
`LibraryVibesRepository`) ; **le serveur** — aucune migration, aucune règle
d'accès touchée ; la séparation des contextes (un objet par destination).

**Le compte des chemins, avant / après** :

| | avant | après |
|---|---|---|
| écrans qui choisissent « à qui » | 5 | **1** |
| sources de la liste | conversations seulement | amis + groupes + croisés |
| endroits où vit un réglage d'envoi | 4 (lignes, sections, feuille, prefs) | **1** (la feuille ⚙︎) |
| Cards créées pour N amis | 1 à 2 (selon les `saveable`) | **1**, toujours |

---

## 4. Les défauts justes (ce que la feuille ⚙︎ contient, et ses valeurs)

| Réglage | Défaut | Pourquoi |
|---|---|---|
| Limites de vues / durée (personnes) | celles des Réglages de l'app (`defaultMaxViewsProvider`…) — inchangé | déjà un défaut juste |
| Les destinataires peuvent enregistrer | **non** | c'est la promesse DM ; s'active pour tout l'envoi |
| Story visible par | **tous mes amis** | le palier plus étroit est un choix, pas le défaut |
| Story partageable / enregistrable | **non / non** | inchangé |
| Publication : visible par les gens croisés / partageable / enregistrable | **non / non / non** | inchangé |
| Aussi dans la bibliothèque du groupe | **non**, et seulement si un groupe est coché | un objet de plus, à demander |

➡️ **Ce que ça retire** : le `saveable` par ligne, donc les lots, donc les
montées de fichier multiples pour un même envoi. À valider (question 1).

---

## 5. L'ordre de construction — chaque étape se livre et se teste seule

| Étape | Quoi | Ce que Jay verra |
|---|---|---|
| **1. La liste juste** | `RecipientSource` + `recipientsProvider` (amis avec palier ∪ groupes ∪ croisés, tri récents → paliers), `RecentRecipientsStore` ; branché dans l'écran actuel à la place de `_Conversations` | tous ses amis apparaissent, les plus proches en haut, les récents en pastilles |
| **2. Un seul écran** | `ShareContext` + `RecipientPickerScreen` ; les cinq écrans/listes rebranchés dessus ; suppression des quatre autres (règle 8 : relever les deux sens avant de couper) | le même écran partout — après capture, depuis un chat, depuis une story |
| **3. Les options en un endroit** | `ShareOptionsSheet` ; `SharePlan` simplifié (un `saveable`, plus de lots) ; tests du plan réécrits | des lignes propres, un bouton ⚙︎ |
| **4. Le récap dans l'écran** | la Vibe en haut (retournable, « modifier ») ; `_RecapStep` supprimé | un écran de moins |
| **5. L'envoi en arrière-plan** | `ShareQueue` + `ShareProgressBanner` ; retour caméra immédiat ; Réessayer par destination | on envoie, on est déjà revenu à la caméra |

Chaque étape = un commit, une version, un test sur le téléphone. Si Jay
arrête après l'étape 2 ou 3, ce qui est livré tient debout.

---

## 6. Ce que je propose de couper (à valider)

- **Le `saveable` par destinataire** → un seul pour l'envoi (§4).
- **Les filtres Tout / Amis / Groupes** comme boutons en haut → gardés mais
  discrets (segments), puisque la liste est triée par nature.
- **L'écran `CircleSettingsScreen`** (envoi depuis un chat) → remplacé par le
  même écran avec le chat pré-coché.
- **Les deux `_ConversationPicker`** des visionneuses → remplacés.
- **Le retour à l'accueil après envoi** → retour à la caméra.

---

## 7. Questions à trancher — celles qui changent le travail

1. **Un seul « Sauvegardable » pour tout l'envoi ?** (au lieu d'un par
   personne). Recommandation : **oui** — une Card, une montée, un réglage
   lisible. Le cas « celui-là peut enregistrer, pas l'autre » se fait en deux
   envois.
2. **Après l'envoi, retour à la caméra** (comme Snap) plutôt qu'à l'accueil ?
   Recommandation : **caméra**. La consigne du 2026-08 (*« le retour depuis
   l'écran d'envoi ramène dans la section Card »*) va dans ce sens.
3. **La rangée rapide** : `Ma story` + les 5 derniers destinataires — ou
   seulement les 5 derniers, la story restant une ligne ? Recommandation :
   **story + 5**, c'est le geste le plus fréquent.
4. **Le chat d'un événement privé** apparaît-il dans la liste comme un groupe
   ordinaire (quand on y est) ? Recommandation : **oui**, cohérent avec la
   décision du jour sur les vocaux.

Ce qui n'est **pas** une question ici : la séparation des contextes (un objet
par destination), la règle du 1/1, le coût annoncé, l'échec par destination —
tout ça reste.

---

## 8. Ce que ce plan prépare, sans le faire

- **« Ajouter au feed » et l'ajout anonyme** (vision §6.4–6.5) : une ligne de
  plus dans le même écran, en mode repartage, quand le feed existera. Le
  régime anonyme / nommé selon le palier s'affichera **sur la ligne**, avant
  d'envoyer — la question 2 du §6.5 trouve sa place naturellement.
- **Le reveal comme option d'envoi** (`RAPPELS.md` #110) : une case de plus
  dans la feuille ⚙︎, le jour où la mécanique existera.
- **La story publique par story** (`RAPPELS.md` #108) : idem, si la règle
  d'accès est un jour rendue propre à chaque story.
