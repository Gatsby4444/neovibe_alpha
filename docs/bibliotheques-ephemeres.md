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

---

## État d'implémentation

### Fait — le socle en base (2026-08-10)

Migrations `20260810190000`, `20260810190100`, `20260810190200`, **appliquées et
vérifiées en base**.

| Objet | Rôle |
|---|---|
| `conversations.library_timezone` | Fuseau fixé par conversation — un seul instant de reveal pour tous. |
| `library_reveal_at(tz, at)` | Calcule le prochain 18h30. Vérifié : 14h → le jour même ; 20h → le lendemain ; 18h30 pile → le lendemain. |
| `library_vibes` | Les entrées : reveal, drapeaux `saveable_by_others` / `ephemeral`, chemins du placeholder et du scellé. |
| `library_vibe_keys` | Les clés, **table sans aucune politique** : illisible directement, par quiconque. |
| `add_vibe_to_library(...)` | Vérifie l'appartenance, refuse le BeReal et la One of One, calcule le reveal, range la clé, poste l'annonce nommée. |
| `get_library_vibe_key(id)` | **Le seul vrai verrou.** Refuse la clé avant `reveal_at`, y compris à l'auteur. |
| Bucket `library_vault` | 4 politiques : dépôt sous son propre identifiant, lecture du placeholder immédiate, lecture du scellé **à partir de reveal − 5 min**, suppression par l'auteur. |
| `purge_expired_library_vibes()` | Greffée sur la tâche `neovibe_purge` existante. Ne supprime que les vibes `ephemeral`, 24 h après leur reveal. |

**Le reveal n'est pas une tâche planifiée.** `reveal_at` étant stocké, la
révélation est une règle de **lecture** (`now() >= reveal_at`) : rien ne
« bascule » à 18h30, donc aucun cron à surveiller, aucun rattrapage à prévoir si
le serveur était indisponible à l'heure dite.

**Pas d'Edge Function.** Le client possède l'original, il fabrique donc
lui-même le placeholder et chiffre. Le serveur ne traite aucune image : il ne
fait que **retenir la clé**.

### Fait — la couche Dart (2026-08-10)

| Fichier | Rôle |
|---|---|
| `core/models/library_vibe.dart` | Le modèle, avec `revealed`, `prefetchable` (reveal − 5 min) et `albumDay`. |
| `features/library_vibes/library_vibes_repository.dart` | Placeholder (réduction 20 px au **décodage**), scellé AES-GCM, dépôt, appel RPC, ouverture et déchiffrement. |
| `features/library_vibes/library_target.dart` | La conversation visée ; sa présence bascule la capture en mode bibliothèque. |
| `features/library_vibes/library_share_screen.dart` | Écran de partage simplifié — **aucun aperçu**, trois réglages. |
| `features/library_vibes/conversation_library_screen.dart` | Albums datés, tuiles en placeholder, préchargement. |
| `features/library_vibes/revealed_vibe_screen.dart` | Ouverture avec **défloutage animé** sur la vraie image. |
| `cards/card_capture_screen.dart` | Mode bibliothèque : pas de récap, pas de fond coloré, pas d'import galerie. |
| `conversations/chat_screen.dart` | Bouton « plus » → ajout ; bouton en haut à droite → bibliothèque ; rendu de l'annonce `library_add`. |
| `core/models/message.dart` | `MessageKind.libraryAdd` + `fromDb` rendu **tolérant** (voir ci-dessous). |
| `core/utils/formats.dart` | `albumDayLabel` — « Aujourd'hui », « Hier », « Mardi 12 août ». |

Deux pièges évités à l'écriture, invisibles pour `flutter analyze` :

- **`MessageKind.fromDb` utilisait `byName`, qui LÈVE sur une valeur inconnue.**
  Un APK antérieur à cette migration aurait vu la conversation entière échouer
  au premier `library_add`. Remplacé par une table explicite avec repli sur
  `text`.
- **`DateFormat(…, 'fr_FR')` exige `initializeDateFormatting`**, qui n'est
  appelé nulle part dans l'app : l'écran aurait planté à l'ouverture. Les dates
  sont écrites à la main, comme ailleurs dans le projet.

### Reste à faire

1. **Notification du reveal** — à planifier en local
   (`NotificationService.schedule`, déjà présent) à partir de `reveal_at`. Rien
   à faire côté serveur, et la règle « pas de notification si personne n'a rien
   ajouté » est satisfaite d'office : le client ne planifie que s'il connaît au
   moins une vibe.
2. **Vidéo au reveal** — `RevealedVibeScreen` n'affiche aujourd'hui que les
   images. Le fichier déchiffré est déjà écrit en `.mp4` quand il le faut : il
   reste à le passer au lecteur existant (`video_player_screen.dart`).
3. **Sauvegarde au reveal** — le bouton décidé par Jay (garder une vibe révélée
   dans sa bibliothèque perso, soumis à `saveable_by_others` pour les autres,
   toujours permis à l'auteur) n'est pas encore posé dans l'écran de reveal.
4. **Rafraîchissement au passage de 18h30** — l'écran ne se met à jour qu'à sa
   réouverture. Un minuteur sur `reveal_at` ferait basculer les tuiles en direct.
5. **Fuseau de la conversation** — la colonne existe et vaut `Europe/Paris` pour
   toutes les conversations. Rien ne le règle encore à la création.

---

## Retours du test de Jay (2026-08-10, v0.9.43)

### Le flou était pixelisé — CORRIGÉ

Jay : « le flou n'est pas suffisant, il est pixelisé et non fluide ». Constat
juste, et la cause est une confusion que j'avais laissée dans l'implémentation :
je faisais porter au **redimensionnement** le rôle du **flou**.

Ce sont deux choses distinctes, et il faut les deux :

| | Rôle | Ce que ça garantit |
|---|---|---|
| Réduction à 20 px | **Sécurité** | L'information est détruite. Rien ne la reconstitue. |
| Flou gaussien | **Habillage** | Une nappe de couleurs continue, au lieu d'un damier. |

**Les appliquer tous les deux ne coûte aucune sécurité** : flouter une image
déjà détruite n'y réinjecte pas d'information. Le placeholder reste donc à
20 px, et il est rendu à travers un vrai flou (`MaskedPlaceholder`).

C'est aussi ce qui rend la **dissipation** possible : un flou est un paramètre
continu, qu'on fait tomber à zéro en fondu — une mosaïque ne se dissipe pas,
elle saute d'une résolution à l'autre.

`RevealedVibeScreen` enchaîne désormais trois couches sur une seule animation :
le placeholder flouté (déjà en mémoire, donc aucun temps de chargement), puis
l'image réelle qui apparaît **sous le même flou** — l'échange est invisible —,
puis le flou qui tombe à zéro. Le rayon de départ suit la taille d'affichage :
~7 sur une tuile, 44 en plein écran.

**Réglages à ajuster au test** : `MaskedPlaceholder.sigma` par appel, et
`_startSigma` dans `RevealedVibeScreen`. La largeur du placeholder
(`_placeholderWidth`, 20 px) peut monter à ~32 px pour des masses de couleur
plus riches, au prix d'un peu plus d'indices avant l'heure.

### Le double flux ne s'ouvre pas en mode bibliothèque — NON RÉSOLU

Jay au test : le double live du Oneshot ne s'active pas depuis la capture de
bibliothèque.

**Rien dans le mode bibliothèque ne touche ce chemin** : le sélecteur de type,
l'initialisation de `_type`, `_onTypeChanged` et `_applyTypeToCamera` sont
strictement identiques aux deux modes (vérifié en lecture).

**Hypothèse la plus probable** : `NativeCameraController.dualFailedThisSession`
est un **statique de classe**, donc valable pour tout le lancement de l'app. Un
seul échec — y compris un dépassement des 12 s — bascule définitivement en
séquentiel jusqu'au redémarrage. Le scénario qui colle : ouvrir un Oneshot en
capture normale, ressortir, puis rouvrir aussitôt depuis la bibliothèque —
`openGlDual` est alors appelé pendant que la session GL précédente se libère
encore, d'où un timeout.

Si c'est cela, le défaut **préexiste** aux bibliothèques : elles le rendent
seulement facile à déclencher, en enchaînant deux captures depuis le même chat.

**À faire avant de corriger** : lire le journal caméra (Réglages → Développeur →
Journal caméra) juste après un cas raté, et relever la ligne
`Oneshot : double live GPU refusé — <raison>`. La raison exacte (timeout,
`GL_UNSUPPORTED`, `DUAL_UNSUPPORTED`) décide du correctif. Ne pas modifier
`dualFailedThisSession` à l'aveugle : la règle « un réessai par session » est une
décision de Jay, motivée par le fait qu'un essai raté peut laisser le service
caméra d'Android hors service.

---

## Qui fait quoi : client ou serveur ? (question de Jay, 2026-08-10)

Réponse directe : **la réduction est faite par l'app de l'auteur, pas par le
serveur.** Le flou gaussien aussi. Le serveur ne traite **aucune** image.

| Étape | Où | Pourquoi |
|---|---|---|
| Réduction à 20 px | **App de l'auteur** | Il possède déjà l'original — il vient de le capturer. Le faire côté serveur imposerait une Edge Function et un traitement d'image, pour un résultat identique. |
| Chiffrement AES-GCM | **App de l'auteur** | Même raison. |
| **Rétention de la clé** | **SERVEUR** | ⚠️ **C'est ici, et uniquement ici, qu'est la sécurité.** |
| Flou gaussien | **App de chaque lecteur** | Pur habillage, au rendu. |

### Pourquoi la garantie tient quand même

Ce que les **autres membres** peuvent obtenir du serveur avant 18h30 :

- le fichier placeholder — **20 px**, l'information est détruite ;
- le fichier scellé — **illisible sans la clé** ;
- la clé — **refusée** par `get_library_vibe_key` tant que `reveal_at` n'est pas
  atteint.

Un client modifié ne change rien à cela : il demanderait les mêmes fichiers et
essuierait le même refus. **La barrière est côté serveur**, même si la
fabrication est côté client.

**Vérifié en base** : l'original non chiffré existe aussi dans le bucket
`cards`, mais `private.can_view_card_file` ne l'ouvre qu'au propriétaire, à un
destinataire de livraison, à la bibliothèque de profil, à une sauvegarde ou à
une story. Une vibe de bibliothèque n'a **aucun** de ces liens pour les autres
membres — ils ne peuvent donc pas le lire.

⚠️ **Garde-fou à ne jamais oublier** : si quelqu'un ajoute un jour à
`can_view_card_file` une branche du type « les membres d'une conversation
voient les cards de cette conversation », **tout le mécanisme de reveal tombe
en silence**. Cette fonction est un point de fragilité à relire à chaque
évolution des accès.

### La seule limite réelle

Comme le placeholder est fabriqué par le client, un auteur au client modifié
pourrait déposer un placeholder qui n'est pas une réduction de son image. Il
n'exposerait que **son propre contenu**, ce qui est de toute façon sa
prérogative. Aucun membre ne peut exposer le contenu d'un autre.

**Si tu veux malgré tout la fabrication côté serveur**, il faut une Edge
Function déclenchée à l'upload, qui produirait le placeholder et scellerait
l'original. Cela fermerait ce dernier cas, au prix d'un traitement d'image
serveur et d'un délai entre la prise et la disponibilité de la vibe. Non fait —
à décider.

## Réglages du masquage

Trois curseurs, tous indépendants :

| Réglage | Où | Effet | Valeur |
|---|---|---|---|
| **Pixelisation** | `LibraryVibesRepository._placeholderWidth` | Largeur de la source. **C'est le seul paramètre de sécurité.** Plus bas = moins d'indices. Monter à 32 px donne des masses de couleur plus riches, au prix d'un peu plus d'information avant l'heure. | `20` |
| **Flou, en grille** | `sigma` passé à `MaskedPlaceholder` dans `conversation_library_screen.dart` | Adoucit le damier sur une tuile. Aucun effet sur la sécurité. | `7` |
| **Flou, en plein écran** | `_sigma` de `VibeFacesScreen`, `_startSigma` de `RevealedVibeScreen` | Le rayon est en pixels logiques : il doit suivre la taille d'affichage, d'où l'écart avec la grille. | `40` / `44` |
| **Durée de la dissipation** | `AnimationController` de `RevealedVibeScreen` | Vitesse du dévoilement. | `1600 ms` |

**Le point à retenir** : seule la largeur du placeholder protège. Les `sigma` et
la durée sont esthétiques et se règlent librement, sans jamais affaiblir le
mécanisme.

## Points encore ouverts

- La lecture par défaut de la **Oneshot en bibliothèque** ci-dessus.
- Le **drapeau « éphémère »** (disparition 24 h après le reveal) appliqué à une
  Oneshot : redondant avec sa mécanique propre. À clarifier en même temps.
