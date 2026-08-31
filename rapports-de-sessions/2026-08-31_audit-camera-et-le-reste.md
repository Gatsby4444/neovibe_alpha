# Audit du reste — caméra, serveur, écrans — 2026-08-31

Suite de `2026-08-31_audit-oeil-neuf.md`, qui avait laissé un périmètre non
audité : *« écrans de capture caméra (~4 800 lignes), réglages, `day_cycle` »*.
Jay : *« audite la caméra ET TOUT LE RESTE maintenant »*.

**28 défauts trouvés, 22 corrigés**, 6 reportés avec leur raison.
Même méthode : lecture du code, aucune confiance aux commentaires, et pour le
serveur les définitions **relues en base**.

---

## 1. Caméra — le natif

Le rendu GPU **est dans le chemin de production**, pas seulement dans un écran
de test : le Oneshot ouvre le double flux (`card_capture_screen.dart:651`). Ce
qui suit n'est donc pas du code de laboratoire.

### 🔴 Le journal caméra pouvait faire tomber la caméra

`CamLog.write` formait son horodatage avec `SimpleDateFormat` **hors du
verrou**, depuis quatre threads (GL, caméra, audio, principal). Cette classe
n'est pas sûre en accès concurrent : deux formatages simultanés corrompent son
état interne — au mieux un horodatage absurde, au pire une
`ArrayIndexOutOfBoundsException` **levée depuis l'appel de journal lui-même**,
dans la pile du rendu caméra.

Un instrument qui fait tomber le thread qu'il observe ne se contente pas de mal
mesurer : il change ce qu'il mesure. Corrigé — le formatage passe sous le verrou.

**Et la borne de 256 Ko n'était appliquée qu'au démarrage.** `trimIfNeeded`
n'était appelée que par `init`. Le rendu GPU journalise à chaque image quand il
échoue : une session pouvait écrire des centaines de Mo dans l'espace privé,
sans que rien ne l'arrête. Le contrôle a lieu maintenant toutes les 200 lignes.

### 🔴 Une vidéo ratée gelait la caméra pour toute la session

`drainEncoder(endOfStream = true)` bouclait **sans limite** en attendant le
marqueur de fin du codec. Si celui-ci n'arrive jamais — pile occupée,
`signalEndOfInputStream` refusé, matériel en vrac — le thread GL restait bloqué.

Et ce n'était pas seulement une vidéo perdue : `releaseEncoder()` n'est jamais
atteint, `close()` poste son `finish()` sur **le même handler** et ne s'exécute
jamais. La caméra n'est donc jamais rendue, `releaseDualEngines` n'appelle
jamais son `onDone`, et **toute ouverture ultérieure attend indéfiniment**.
Borné à 4 s, la limite que `stopRecording` s'accordait déjà.

### Les autres

| | |
|---|---|
| `videoFirstWallNs` était **écrit** hors verrou et **lu** sous verrou. Un verrou tenu d'un seul côté ne garantit rien : le thread audio pouvait continuer de lire `0` et **jeter le début de la piste audio** — le genre de défaut qu'on met sur le compte du micro | corrigé |
| `awaitingFirstFrame` / `framesSinceBind` : écrits sur le thread principal, lus sur un thread caméra, sans `@Volatile`. Panne muette et intermittente — `previewReady` jamais envoyé, voile de bascule levé au bout des 1600 ms de garde-fou | corrigé |
| `captureGlDual` et `startGlDualVideo` **laissaient les fichiers partiels** quand une seule des deux faces réussissait | corrigé |
| `camSize = Size(1280, 720)`, commenté *« la seule configuration tolérée par ce matériel (mesurée) »* — le matériel étant le Redmi de Jay. Sur un appareil qui ne l'expose pas, la session est refusée et le Oneshot replie en photo, sans dire pourquoi | on **demande** au matériel, avec repli 16:9 |
| `stopVideo` était la **seule** méthode du canal caméra sans borne de temps, alors que sa réponse ne vient que de l'événement `Finalize`. S'il n'arrive pas, l'écran reste sur `_busy` : déclencheur gelé, aucun message | 15 s |
| Le repli Dart de la normalisation ne libérait pas l'image `ui.Image` de sortie (~14 Mo par capture HD, mémoire **native**, invisible du ramasse-miettes) et nommait son fichier sur un horodatage | corrigé |
| KDoc citant `[Camera2Dual]`, classe supprimée avec le moteur logiciel | corrigé |

### Reporté

**`normalize916` en HD monte à ~110 Mo de pointe** (décodage 12 Mpx + copie
tournée + bitmap cible), sur `ioExecutor`. Une `OutOfMemoryError` y tuerait
l'app. Je ne l'ai pas changé : réduire le pic demande de décoder par bandes,
c'est-à-dire réécrire la normalisation — un chantier, pas un correctif.

---

## 2. Serveur — les 51 fonctions non encore lues

### 🔴 La recommandation ignorait complètement les blocages

Il y a **deux façons** de devenir amis. Depuis le lot du matin, la proximité
refuse tant qu'un blocage tient. **La recommandation ne regardait `blocks` à
aucun moment** — ni pour transmettre, ni pour accepter. On pouvait donc
présenter quelqu'un à une personne qui l'avait bloqué ; et une proposition
transmise avant un blocage restait acceptable après, `block_user` n'effaçant
que les demandes d'ami.

Deux chemins ouverts, un seul contrôlé : c'est le plus permissif qui décide.
Corrigé aux deux endroits.

### 🔴 `anon` exécutait douze fonctions, dont deux de ménage

`purge_sightings` et `purge_empty_proximity_conversations` sont des tâches de
fond. Elles étaient exécutables **sans être connecté**, et ne vérifient rien.

Ce qu'elles peuvent faire est borné — elles ne suppriment que ce que le cron
supprimerait cinq minutes plus tard — et c'est exactement pour ça qu'on ne l'a
pas vu : la défense s'énonce par une négation. Effet concret tout de même,
appelée en boucle : les cinq minutes de grâce laissées à deux personnes pour
écrire leur premier message tombent à zéro.

Les dix autres se gardaient seules (`auth.uid()` nul → sortie), mais rien ne
justifiait de les proposer à un visiteur.

**Après ce lot, `anon` n'exécute plus aucune fonction de `public`.** C'est la
formulation positive : plutôt que « celles qui restent se gardent elles-mêmes »,
il n'en reste aucune.

### 🔴 Un nœud orphelin qui écrit `pair_key`

`promote_proximity_conversation` a perdu son déclencheur le 2026-07-13, par
décision. **La fonction est restée.** C'était le seul code encore capable
d'écrire `pair_key` — la colonne dont le lot du matin vient de retirer le droit
d'écriture au client parce qu'elle permettait de détourner une conversation
privée — et elle est `security definer`, donc elle contourne ce retrait par
construction. Supprimée.

### Les autres

| | |
|---|---|
| `purge_ping` gardait les balises **15 minutes** pour un TTL de **5**. Une balise porte `lat`/`lon`, la position exacte : elle restait dix minutes de plus que le dernier instant où quoi que ce soit pouvait s'en servir — et le commentaire disait « rien ne la justifie » | aligné sur `ping_beacon_ttl() * 2` |
| Le déclencheur d'inscription pour suppression pouvait **nommer le fichier d'autrui** (`publish_story` ne vérifie pas les chemins). Le balayage client aurait retenté à l'infini une suppression impossible | n'inscrit que ce que le propriétaire peut effacer |
| `confirm_ping` et `report_sightings` rendaient une variable nommée `retenus`, incrémentée **après** un `on conflict do nothing` : elles comptaient les éléments **traités**. Le client redépose les mêmes jetons à chaque tour — le nombre ne pouvait jamais descendre | `get diagnostics row_count` |

### Reporté

**25 clés étrangères sans index sur leur colonne référencée.** La plus
conséquente : `messages.content_id` en `ON DELETE SET NULL`. Chaque suppression
de contenu — donc chaque story expirée, toutes les 5 minutes — impose un
**parcours complet de `messages`**. Invisible à 6 messages, coûteux à l'échelle.
Un index se pose en une ligne, mais 25 index ont un coût d'écriture : c'est un
arbitrage à faire sur mesure, pas au jugé.

**`meeting_days` survit au blocage** (choix de Jay ce matin). Conséquence à
connaître : re-devenir amis après un blocage **restaure instantanément l'ancien
palier**, `days_met` regardant les 30 derniers jours.

---

## 3. Dart — écrans et modèles

### 🔴 Le reveal ne se produisait pas à l'écran

`LibraryVibe.revealed` valait `DateTime.now().isAfter(revealAt)`, et **trois
`build()` le lisaient**. Un `build` ne se rejoue que si l'une de ses sources
change — et l'heure n'en était pas une.

Quelqu'un qui attend 18h30 devant sa bibliothèque voyait les vibes **rester
masquées**, jusqu'à ce qu'un événement sans rapport reconstruise le widget.
C'est le défaut décrit dans `core/clock.dart`, posé sur le seul moment de l'app
que les gens attendent vraiment.

L'instant est devenu un **paramètre** (`revealedAt(now)`), et les trois écrans
surveillent `expiryClockProvider`. L'instantané reste disponible sous un nom qui
le dit (`revealedMaintenant`), pour les callbacks — où c'est le bon choix.

### 🔴 Le balayage d'égalité de valeur du 25 août avait manqué trois modèles

`LibraryItem`, `LibraryVibe` et `Recommendation` n'avaient pas de `==`, quand
sept autres l'avaient reçu ce jour-là. Les trois alimentent des listes rendues
par des providers et observées par des écrans : sans égalité de valeur, la
comparaison retombe sur l'identité **en silence**, et chaque rechargement
reconstruit tout.

⚠️ La règle du chantier d'alors disait : *« vérifier par inventaire, pas par le
diff »*. L'inventaire n'avait pas été fait sur le dossier des modèles.

### Les autres

| | |
|---|---|
| La file d'envoi de la proximité n'avait **aucune borne**, et `pushOutbox` échoue en silence hors ligne — le compteur de tentatives ne monte qu'à un envoi *tenté*. Chaque dépôt relit et réécrit le fichier entier : coût **quadratique** | plafond de 500, les plus vieux partent |
| `coarse_location.dart` citait `private.ping_reach` comme le mécanisme qui élargit la recherche quand la position est mauvaise. **Cette fonction n'existe pas** — ni aujourd'hui, ni dans aucune migration. Ce qui filtre est `ping_plausible`, sur le carreau seul | commentaire réécrit |

### Deux défauts que j'avais créés le matin même

Ils passent en premier, règle du projet.

**L'interface des groupes.** Mon correctif M4 a fait passer la règle serveur à
« soi-même, ou le créateur ». L'écran des réglages offrait « Retirer » à **tout
le monde** — et l'échec aurait été **muet** : un `delete` refusé par la sécurité
au niveau des lignes ne lève pas, il supprime zéro ligne et répond « ok ».
L'écran se serait rechargé avec le membre toujours là, sans un mot. Le bouton
n'apparaît plus que pour le créateur (`Conversation.createdBy`, colonne qui
existait et n'était pas lue).

**`StorageSweep`.** Il supprimait le lot d'un coup et ne rayait la liste que si
l'appel n'avait pas levé. Bonne règle pour une panne réseau — mais un seul
chemin définitivement indélébile bloquait **tout le coffre**, à chaque
démarrage. Le lot d'abord, le détail en cas d'échec ; et la cause est supprimée
côté serveur.

---

## 4. Ce que je n'ai pas corrigé, et pourquoi

**Les octets de photos restent en mémoire pour la vie de l'app.**
`contentFaceProvider` et `savedPhotoBytesProvider` sont des providers de famille
**non auto-libérés** : chaque face ouverte garde ses octets déchiffrés
indéfiniment. Pire, `contentFaceProvider` enregistre `ref.onDispose(media.dispose)`
— un nettoyage que rien ne peut atteindre.

Le rendre auto-libéré est probablement juste (le cache qui compte est le fichier
scellé, sur le disque), **mais ça change le défilement** : une vignette qui sort
puis revient serait re-déchiffrée, avec un état de chargement visible. C'est un
arbitrage mémoire / fluidité que je ne prends pas seul.

**« 18h30 » est écrit en dur** dans six chaînes, alors que le reveal suit le
fuseau de la **conversation** (`library_reveal_at`). Pour un groupe dont un
membre voyage, le libellé ment. Corriger, c'est réécrire de la copie — elle est
à toi.

**Le pic mémoire de la normalisation HD** — voir §1.

**Les 25 clés étrangères sans index** — voir §2.

---

## 5. Vérifications

| Contrôle | Résultat |
|---|---|
| `flutter analyze` | **0 problème** |
| `flutter test` | **379 verts** |
| `gradlew :app:testDebugUnitTest` | **83 verts, BUILD SUCCESSFUL** |
| `anon` sur les fonctions `public` | **0** (12 avant) |
| Inscriptions de suppression mal placées | **0** sur 96 |

## 6. Périmètre

Lu cette fois : `NativeCamera.kt`, `Camera2Gl.kt`, `CamLog.kt`,
`DualAudioEncoder.kt`, `card_capture_screen.dart`, `native_camera.dart`,
`day_cycle.dart`, `coarse_location.dart`, `distance_estimate.dart`,
`presence_book.dart`, `proximity_sync.dart`, `ping_store.dart`,
`developer_flags_screen.dart`, `group_settings_screen.dart`, les écrans de
bibliothèque éphémère, les trois modèles, **et les 51 fonctions serveur
restantes** (92 au total, toutes lues désormais).

Balayages automatiques passés sur l'ensemble : commentaires citant du code
inexistant (fonctions serveur, fichiers, symboles), `context` utilisé après un
`await` sans `mounted` (**aucun**), minuteurs sans `cancel`, modèles sans
égalité de valeur, providers non auto-libérés, `DateTime.now()` utilisé comme
filtre.

Reste non lu ligne à ligne, et assumé : `chat_screen.dart`, la constellation,
les écrans de connexions et de bibliothèque publique, la majorité des écrans de
réglages, `ping_screen.dart`. Les balayages ci-dessus les couvraient ; une
lecture intégrale reste à faire.
