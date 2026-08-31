# Session du 2026-08-31 — correctifs de l'audit

Suite directe de `2026-08-31_audit-oeil-neuf.md`. Jay : *« corrige toutes les
erreurs repérées et les failles 1. 2. et 3. et supprime ou corrige les
commentaires faux »*.

**29 défauts traités** (28 de l'audit + 1 trouvé en corrigeant).
34 fichiers touchés, +1 095 / −149 lignes, 5 nouveaux fichiers.

---

## 1. Décisions de Jay prises en cours de session

| Question | Réponse | Ce que j'en ai fait |
|---|---|---|
| Blocage : quoi couper en plus ? | **L'accès nominatif à la bibliothèque uniquement** | `block_user` supprime `library_access` dans les deux sens. Conversations et `meeting_days` **non touchés**. |
| Groupes : qui retire un membre ? | **Soi-même, et le créateur** | Nouvelle politique `members_delete_self_or_group_creator`, branche créateur restreinte aux groupes. |
| Fichiers des stories expirées ? | **Oui, 7 jours plus tard** | Table `storage_tombstones` + déclencheurs + purge par le client. |
| Contenu à moi révoqué : illisible chez moi ? | **Non, je garde mes contenus** | **Le commentaire est corrigé, pas le code.** `OwnKeyStore.ids()` supprimée. |

---

## 2. Ce qui a été corrigé

### Critiques

**C1 — détournement d'une conversation privée par `pair_key`.**
`revoke update on public.conversations` + `grant update (title)`. La politique
ne pouvait pas fermer ça : une politique décide de la LIGNE, pas des colonnes.
`get_or_create_direct_conversation` et `..._proximity_conversation` exigent en
plus le `conversation_type` dans leur recherche et lèvent au lieu de rendre
`null`.

**C2 — la barrière fondatrice contournable en une requête.**
`revoke insert, update, delete on public.connection_requests`, et suppression
des deux politiques d'écriture devenues sans objet. `request_connection_from_
proximity` et `accept_connection_request` consultent désormais `is_blocked`.

**Vérifié en base, sous l'identité d'un utilisateur** (`set local role
authenticated` + `request.jwt.claims`) :

```
INSERT direct dans connection_requests  → permission denied  ✅
UPDATE de conversations.pair_key        → permission denied  ✅
UPDATE de conversations.created_by      → permission denied  ✅
UPDATE de conversations.title           → autorisé           ✅
request_connection_from_proximity()     → « Proximité non constatée » ✅
```

Le dernier est le plus important : la RPC atteint toujours l'insertion, et
c'est la **barrière métier** qui refuse — pas un défaut de droit. Le chemin
légitime marche, et il est désormais le seul.

### Élevés

**H1 — le plan d'émission décalé dès le 6ᵉ créneau.**
Cause supprimée, pas colmatée : **`publicHorizon` a été retiré**. Il répondait à
la même question que l'homme mort du natif (`publicAutorise`, 2026-08-29), qui y
répond mieux — 5 min au lieu de 75 — et c'est lui qui rendait le nombre de
jetons variable d'un créneau à l'autre. Règle 6 de `CLAUDE.md` : une décision du
2026-08-28 qui n'avait pas été rejouée après le correctif du 2026-08-29.

*Vérifié avant de supprimer* : `BleRadio.publicHeartbeat()` → `ProximityBridge`
→ `battementPublic()` est bien branché, appelé par `ping_beacon_service.dart:228`
à chaque republication de balise. L'homme mort n'est pas qu'écrit.

`AdvertPlan` **vérifie l'uniformité à sa construction** et lève sinon ; le
superviseur lit `plan.tokensPerSlot` au lieu de recompter le premier créneau.
Côté natif, `AdvertSchedule.friendsOnly()` refuse un plan dont l'agencement
change d'un créneau à l'autre.

**H2 — révocation de mes propres contenus.** Décision de Jay : c'est le
commentaire qui était faux. Paragraphe réécrit, `ids()` supprimée, `remove()`
branchée sur les deux vraies suppressions (story, publication).

**H3 — les octets ne partaient jamais.**
`StoriesRepository.remove()` supprime `contents` et non `stories` (le lien ne va
que dans un sens ; l'autre chemin, la purge cron, faisait déjà juste).
Nouvelle mécanique de suppression différée :

- `storage_tombstones` (RLS active, **aucune politique**) ;
- un déclencheur `before delete` sur `stories`, `library_items`, `cards`, et un
  second pour `library_vibes` (quatre chemins sous d'autres noms) ;
- RPC `mes_octets_a_supprimer()` / `octets_supprimes()` ;
- `StorageSweep` côté client, appelé au démarrage.

**⚠️ Pourquoi le client et pas une tâche serveur.** J'ai lu
`storage.protect_delete()` plutôt que de croire le commentaire qui disait
« interdit par Supabase ». Ce n'est pas interdit : c'est **gardé** par un
réglage de session. Mais le contourner ne supprimerait que la ligne, pas le
fichier — on remplacerait un orphelin visible par un orphelin invisible. La
seule voie qui supprime vraiment est l'API Storage, donc un client authentifié.

*Nettoyage ponctuel appliqué* : la ligne `contents` orpheline du 2026-08-14
supprimée ; **96 fichiers orphelins inscrits** (88 `stories` + 8 `library`),
échéance 2026-09-07.

**H4 — une Vibe sans clé consommait une vue.** `open_card_media` lit la clé
**avant** toute écriture et lève si elle manque. Même correctif dans
`open_content_media` et `get_library_vibe_key`.

### Moyens

| | Correctif |
|---|---|
| M1 | `ContentMediaCache.others()` exige un drapeau `complete`, posé au téléchargement et à `false` par `streamingPath` |
| M2 | `SealedVideoController` supprime le fichier en clair du repli hérité à `dispose()` |
| M3 | `expiresAt` ajouté au type `ContentFace` (**obligatoire**, pas de défaut) et passé aux 4 sites ; éviction LRU ajoutée sur `own/` |
| M4 | politique de retrait d'un membre |
| M5 | test de blocage **descendu** de `content_audience` vers `story_audience` / `publication_audience` (il vaut donc pour les 3 chemins) ; `can_view_library` le consulte ; `block_user` supprime `library_access` |
| M6 | **partiel, assumé** — voir §4 |
| M7 | `SightingBuffer` évince le créneau le plus vieux au lieu de jeter le nouveau |
| M8 | `ChunkedSeal` lit la taille de bloc **dans l'en-tête** ; `_sealedChunk` supprimé ; lecture bouclée sur les lectures courtes |
| M9 | tous les compteurs du moteur repartent ensemble dans `start()` |
| M10 | `AdvertOnAir.noteDemande` purge aussi `enVol` |
| M11 | `friendsOnly()` vérifie l'agencement de chaque créneau |

### Bas

`clock.dart` en `autoDispose` (vérifié : riverpod 3.3.2, non auto-libéré par
défaut hors codegen) · `ProximityService` sépare `planSlotMillis` du
`slotMillis` de la table · `pendingScansSize` en O(1) · `repartDuDisque` ne
compte plus comme un battement du Dart (`setAdvertSchedule(duDart: false)`) ·
chemins de stockage des Vibes sur `newUuid()` · garde-fou de `NeoBuildIn`
corrigé · `SealedDataSource.Factory` suit l'ouverture et non la création ·
`_done` / `_primed` bornés.

### Commentaires faux — les 5 corrigés

| Où | Traitement |
|---|---|
| `BleEngine.kt` « le jeton d'ami est symétrique » | réécrit : faux depuis le 2026-08-26, et la doc de classe du même fichier disait le contraire |
| `own_keys.dart` « effacée par le même balayage » | réécrit avec la décision de Jay |
| `content_media_cache.dart` `// usage LRU` | l'éviction a été **écrite**, le commentaire devient vrai |
| `stories_repository.dart` « le serveur ne les sert plus » | précisé : vrai côté service, faux côté octets |
| `advert_plan_test.dart` « l'invariant sur lequel repose le tampon » | test remplacé, fenêtre portée à 48 créneaux |

---

## 3. Défaut trouvé EN corrigeant (n° 29)

**Un compte B ouvert sur le même téléphone héritait des Enregistrements de A.**

`signOut()` ne nettoie que la session serveur. Les Enregistrements, les clés de
mes contenus et les caches sont des fichiers **sans propriétaire inscrit**, et
l'écran « Enregistrements » ne filtre sur personne : B voyait les photos et
vidéos de A, **en clair**.

C'est la fuite déjà fermée pour le ping le 2026-08-17 et pour l'identité le
2026-08-18 — jamais appliquée au contenu.

`LocalContentOwner` lie le stockage local à un compte et efface quand il change.
Le compte lié est **persisté** (et non gardé en mémoire comme le fait le ping) :
le cas le plus probable est un changement de compte entre deux lancements, que
la version en mémoire ne peut pas voir. `RootGate` attend sa réponse avant de
peindre quoi que ce soit.

---

## 4. Ce qui n'a PAS été fait, et pourquoi

**M6 — le plafond de 6 annonces simultanées.** Au-delà de 5 amis avec la
découverte allumée, on retombe en mode cycle, que le code décrit lui-même comme
inacceptable. **Je n'ai pas changé le nombre** : `maxParallelSets` est une
valeur « raisonnée, pas mesurée », et la monter sans relevé sur appareil ne
ferait que déplacer la supposition.

J'ai rendu la cause **lisible** : `advertMaxSets` et `advertParallelCooldownMs`
sont publiés dans `stats()` et ajoutés au rapport de diagnostic, à côté de
`advertMode`. On distingue désormais « cycle par plafond » de « cycle par
refus ». **À trancher avec une mesure sur les deux appareils.**

**M5 partiel** — conversations partagées et `meeting_days` laissés intacts,
décision de Jay.

**`mark_card_viewed`** reste un second chemin d'écriture vers `view_count`, à
côté de `open_card_media`. Il sert encore aux Vibes **non chiffrées** (format
hérité) et le client choisit correctement l'un ou l'autre. À supprimer le jour
où plus aucune Vibe non chiffrée ne circule.

**`hot` / `mono`** restent dans l'énumération et la mécanique Hot dans
`mark_card_viewed` / `request_replay` : c'est délibéré et documenté depuis le
2026-08-10 (un APK antérieur encore installé pourrait les émettre).

**Observation, non corrigée** : le rôle `authenticated` détient `TRUNCATE` sur
toutes les tables (grant par défaut de Supabase). Ce n'est pas atteignable par
PostgREST, mais la défense s'énonce par une négation — « rien ne l'expose ». À
poser comme question si on durcit un jour les droits par défaut.

---

## 5. Vérifications

| Contrôle | Résultat |
|---|---|
| `dart format lib test` | 213 fichiers, 0 modifié |
| `flutter analyze` | **No issues found** |
| `flutter test` | **379 tests, tous verts** |
| `gradlew :app:testDebugUnitTest` | **83 tests, BUILD SUCCESSFUL** (77 avant, +6) |
| Failles C1/C2 fermées | prouvé en base sous `role authenticated` |
| Chemin légitime intact | `title` modifiable, RPC atteint la barrière métier |
| Fichiers `.kt` ajoutés/supprimés | **aucun** → `docs/parties-natives-par-os.md` reste juste |

### Le contre-test, sur les trois correctifs natifs

Les trois correctifs Kotlin ont été **retirés temporairement** et la suite
relancée :

```
83 tests completed, 3 failed
  AdvertOnAirTest    > un rang qui disparait puis revient se reecrit        FAILED
  AdvertScheduleTest > friendsOnly REFUSE un plan dont l'agencement change  FAILED
  SightingBookTest   > au plein, c'est le constat le plus VIEUX qui part    FAILED
```

Exactement trois échecs, un par correctif, et les 80 autres tests intacts. Les
correctifs ont été restaurés et la suite est repassée au vert.

---

## 6. Ce qui reste à faire (hors périmètre de cette session)

1. **Trancher `maxParallelSets`** avec une mesure sur les deux appareils.
2. **`StorageSweep` dépend du propriétaire** : si quelqu'un ne rouvre jamais
   l'app, ses octets restent. Lever cette limite demande `pg_net` ou une
   fonction déportée — ni l'un ni l'autre n'existe aujourd'hui. À mettre dans
   `RAPPELS.md` si Jay le veut.
3. **Tester sur appareil** : le plan d'émission (H1) est le correctif le plus
   important et il ne se voit qu'app fermée. Le relevé qui le prouve est
   `advertSlotDriftMax` après une nuit — il doit valoir 0 ou 1.
4. **Le périmètre non audité** reste non audité : écrans de capture caméra
   (~4 800 lignes), réglages, `day_cycle`.
