# Bibliothèques éphémères de conversation

> Spécification arrêtée avec Jay le **2026-08-10**. Toutes les décisions
> ci-dessous ont été tranchées par lui. Rien n'est encore implémenté.

## Principe

Prendre une vibe à n'importe quel moment de la journée et, **au lieu de
l'envoyer**, l'ajouter à une **bibliothèque partagée** portée par une
conversation — groupe ou DM. Les vibes de la journée y restent **cachées pour
tout le monde**, y compris pour celui qui les a prises, jusqu'à **18h30** où
elles se révèlent d'un coup pour tous les membres.

La bibliothèque est **une bibliothèque souvenir** : par défaut ce qui est révélé
y reste.

### Pourquoi c'est légitime au regard de `CLAUDE.md`

La grille de décision demande : présence physique, ou valeur ajoutée à une
relation existante. Ici c'est franchement le second. Le rendez-vous de 18h30
crée un **moment commun** entre gens qui se connaissent déjà, et l'absence de
preview interdit la mise en scène — on partage ce qu'on a vécu, pas ce qu'on a
fabriqué. C'est l'inverse du contenu vide.

---

## Vocabulaire

**« Card » devient « Vibe »** dans toute l'interface. C'est un **renommage
public uniquement** : le code Dart (`CardType`, `CardModel`, fichiers) et la
base (table `cards`, énumération `card_type`) gardent le mot `card`. Décision de
Jay — le nom visible n'a pas besoin d'entraîner un refactor de 40 fichiers.

La section « Card » de l'app s'appelle donc **« Vibe »**.

---

## Parcours

### 1. Ajouter une vibe

Point d'entrée : le **bouton « plus »** de la barre de saisie du chat
(`chat_screen.dart:406`, aujourd'hui placeholder « Action à définir »).

Il ouvre **la caméra commune de l'app** — pas de second système de prise. Deux
différences de configuration dans ce mode :

- **Tableau noir désactivé** (`face_background.dart`) ;
- **Import galerie désactivé** — même motif, étendu par Jay : le but est une
  prise réelle du moment, une photo de la pellicule le contredirait davantage
  encore que le tableau.

### 2. Écran de partage — simplifié, sans preview

**Aucune preview de la prise.** L'auteur ne voit pas ce qu'il vient de
capturer. C'est le cœur du format.

L'écran contient :

| Élément | Comportement |
|---|---|
| **Bouton « Ajouter à la bibliothèque »** | Porte le **nom du groupe** si c'en est un. |
| **Mention des destinataires** | En DM seulement : sous le bouton, **discrètement et en petit**, le nom de l'utilisateur qui verra la vibe. |
| **Sauvegardable par les autres** | Drapeau posé par l'auteur. Gouverne **les autres membres** : l'auteur peut toujours sauvegarder sa propre vibe. |
| **Éphémère ou souvenir** | Éphémère = disparaît de la bibliothèque **24 h après le reveal**. Souvenir = y reste. **Souvenir est le défaut.** |

**Pas de bouton « sauvegarder dans ma bibliothèque perso » ici** — décision de
Jay : il entrait en conflit avec « même l'envoyeur ne voit pas ses ajouts »
(il aurait suffi de le cocher pour contourner la règle). La sauvegarde se fait
**dans la bibliothèque, au moment du reveal**, et vaut pour tous les membres —
auteur compris.

### 3. Consulter la bibliothèque

Point d'entrée : le **bouton en haut à droite** du chat
(`chat_screen.dart:223`, aujourd'hui placeholder « Action à définir »).

Avant 18h30, les vibes du jour y apparaissent **masquées**. Après, révélées et
consultables.

### 4. Le reveal

À **18h30**, toutes les vibes ajoutées deviennent visibles pour tous les membres
en même temps.

---

## Le masquage — architecture arrêtée

C'est le point technique central. Trois exigences qui se contredisent
naïvement : rien ne doit fuir avant l'heure, le reveal doit être **instantané**
à 18h30, et il doit être **animé** (défloutage progressif), pas une coupe sèche.

### Ce qui a été écarté, et pourquoi

- **Flouter côté client uniquement** : l'appareil détiendrait l'image nette
  toute la journée. Un client modifié verrait tout. Écarté.
- **Basculer du fichier masqué au fichier net à 18h30** : donne une coupe sèche
  et un temps de chargement au pire moment. Écarté — c'est l'objection de Jay,
  et elle est juste.
- **Précharger l'image nette en clair à 18h25** (schéma initial de Jay) :
  bon compromis, mais laisse une fenêtre de 5 minutes où un client modifié voit
  la journée en avance. Amélioré ci-dessous.

### Le mécanisme retenu

| Moment | Ce que le serveur envoie | Ce que l'app peut faire |
|---|---|---|
| À l'ajout | **Placeholder** : l'image **réduite à ~16-24 px de large**, que l'app ré-agrandit. | Afficher le placeholder. Elle n'a **que** ça. |
| **18h25** | Le média original, **chiffré**. | Télécharger les octets. **Incapable de les lire.** |
| **18h30** | La **clé** (quelques centaines d'octets). | Déchiffrer en mémoire, puis animer le défloutage **sur la vraie image**. |

**Pourquoi la réduction extrême plutôt qu'un flou** : un flou gaussien est une
convolution, donc partiellement réversible quand on connaît le noyau ; et même
intact il laisse fuir le nombre de personnes, l'intérieur/extérieur, les
couleurs dominantes. Une réduction à 16-24 px **détruit** l'information au lieu
de la brouiller. Rendu visuel équivalent, fichier négligeable à transférer.

**Pourquoi le chiffrement** : il conserve les deux bénéfices du préchargement
(pas d'attente réseau à 18h30, animation sur la vraie image) tout en fermant la
fenêtre de 18h25-18h30. Avant l'heure, l'appareil ne détient qu'un bloc
illisible, quel que soit le client. Une clé symétrique par vibe, gardée côté
serveur, distribuée à l'heure dite.

**L'animation** : une fois l'image déchiffrée, le défloutage est un **filtre
animé appliqué à la vraie image** (tween sur le sigma), pas un remplacement de
fichier. C'est ce qui permet une transition libre et fluide — l'idée de Jay,
conservée intacte.

**Cas de la vidéo** : ne jamais flouter une vidéo côté serveur (ré-encodage
coûteux). Le placeholder est une **image de couverture réduite** ; le fichier
vidéo n'est livré qu'à 18h25, chiffré comme le reste. Le déchiffrement d'un gros
fichier prend un instant : lancer l'animation sur l'image de couverture pendant
ce temps.

---

## Règles de gestion

### Fuseau horaire

**Un seul instant réel pour toute la conversation.** Le fuseau est fixé à la
création de la conversation. Tout le monde découvre au même moment, où qu'il
soit — c'est ce qui fait l'événement partagé. Un membre à l'étranger le vit à
son heure locale décalée. Écarté : « 18h30 à l'heure locale de chacun », qui
détruit le moment commun.

### Frontière de journée

La journée de collecte va de **18h30 à 18h30**. Une vibe prise après le reveal
part dans le **lot du lendemain**. Ce qui est révélé reste figé et le suspense se
reconstruit immédiatement. Une seule règle, valable toute l'année.

### Signal dans le chat

Quand quelqu'un ajoute une vibe, le fil l'annonce **nommément** (« Marie a
ajouté une vibe »). Décision de Jay, contre l'option du compteur anonyme.

⚠️ **Point de vigilance à surveiller au test** : ça expose tous les jours qui
participe et qui ne participe pas, et en groupe ça peut révéler que deux
personnes étaient ensemble. À réévaluer si l'usage montre une pression sociale.

### One of One

Une vibe ajoutée à une bibliothèque partagée **n'est jamais une One of One**,
même en DM.

Motif : la règle livrée en v0.9.42 (`card_send_screen.dart:115`) transforme en
One of One toute Card partant à un seul destinataire sans publication. Un DM
remplit exactement cette condition — la vibe serait devenue exclusive, or et
**non sauvegardable**, ce qui annulerait les drapeaux « sauvegardable » et
« souvenir ». La bibliothèque est donc un **troisième chemin**, distinct de
l'envoi direct et de la publication.

---

## Règles complémentaires — tranchées par Jay le 2026-08-10

### Notification

**Oui, notification au reveal de 18h30.** Sauf si personne n'a rien ajouté :
dans ce cas **pas de notification**, et le reveal est un non-événement (il n'y a
rien à révéler). Aucun écran d'attente à prévoir, aucun message « bibliothèque
vide aujourd'hui » à pousser.

### Structure de la bibliothèque

**Albums datés.** Un album par journée de collecte, empilés. Pas de flux
continu.

### Départ d'un membre

**Tout reste.** Le départ d'un membre du groupe n'annule rien : ni ses vibes
déjà révélées, ni celles en attente de reveal, qui se révèlent normalement à
18h30.

### Types de vibes acceptés

**Pas de BeReal** dans la bibliothèque. Les autres types sont acceptés — donc
la vibe classique et la Oneshot (le One of One, lui, est exclu par l'exemption
décrite plus haut, et n'est de toute façon plus un type sélectionnable).

⚠️ **Tension à trancher avec Jay avant de coder ce cas précis** : la Oneshot est
définie par « vue unique puis destruction », ce qui contredit frontalement la
*bibliothèque souvenir*. Lecture par défaut retenue faute d'arbitrage, alignée
sur le comportement déjà en place dans les chats : **chaque membre peut l'ouvrir
une fois, puis elle passe en « épuisée » ; l'entrée reste dans l'album.**
« Souvenir » signifie alors que la trace demeure, pas que l'image reste
revoyable. À confirmer.

## Points encore ouverts

- La lecture par défaut de la **Oneshot en bibliothèque** ci-dessus.
- Le **drapeau « éphémère »** (disparition 24 h après le reveal) appliqué à une
  Oneshot : redondant avec sa mécanique propre. À clarifier en même temps.
