# Audit à l'œil neuf — 2026-08-31

Lecture du code seul, sans rapport antérieur, sans `CLAUDE.md`, sans faire
confiance aux commentaires. Aucun outil automatique lancé (`analyze`, `test`).
Seule exception assumée : les définitions serveur ont été relevées **en base**
(politiques, fonctions, contraintes, droits de colonne) plutôt que dans les
72 fichiers de migration, qui se redéfinissent entre eux.

**Page complète (détail, vérifications, questions)** :
https://claude.ai/code/artifact/7d2a87cb-11d2-4748-adbc-fde67642fd1e

**Non couvert** : écrans de capture caméra (`card_capture_screen.dart`,
`NativeCamera.kt`, `Camera2Gl.kt` ≈ 4 800 lignes), écrans de réglages,
`day_cycle`.

---

## Critique (2)

**C1 — Détournement de la conversation privée de deux inconnus.**
`conversations_update_group_member` autorise tout membre d'un groupe à modifier
**toutes** les colonnes, `pair_key` comprise (vérifié : `authenticated` a
`UPDATE` sur toutes les colonnes). `get_or_create_direct_conversation` résout
une DM par `on conflict (pair_key) do nothing` puis `select ... where pair_key =`.
Un attaquant crée un groupe seul, y pose `direct:<A>:<B>`, et la prochaine DM
entre A et B rend **son** groupe, dont il est membre.
`messages_select_member_unexpired` ne vérifie que l'appartenance.

**C2 — La barrière de la présence physique se contourne en une requête.**
`request_connection_from_proximity` vérifie le ticket de proximité ; la table
`connection_requests` est ouverte en écriture directe
(`requests_insert_sender` : expéditeur + pas déjà amis, rien d'autre — aucun
déclencheur, aucune contrainte). Conséquences : demande d'ami sans rencontre,
et `can_view_profile` s'ouvre dès qu'une demande existe. Le blocage n'empêche
pas la réinsertion : `block_user` supprime les demandes mais la règle
d'écriture ne consulte pas `blocks`.

## Élevé (4)

**H1 — Le plan d'émission est décalé dès le 6ᵉ créneau, et n'est jamais persisté.**
`proximity_supervisor.dart:539` calcule `perSlot` sur le **premier** créneau,
mais `advert_plan.dart:205` n'ajoute l'identifiant public que sur les 5 premiers
(horizon public 75 min) alors que les jetons d'amis couvrent les 48. Le tampon
à plat n'a donc pas un pas constant, ce que `AdvertSchedule.kt:146` suppose.
Avec 1 ami + découverte : 53 jetons pour 48 créneaux ; décalage croissant à
partir du 6ᵉ, puis sortie de tampon vers le 27ᵉ → « plan épuisé », silence.
`AdvertSchedule.friendsOnly()` (ligne 186) fait la même hypothèse et rend
`null` → `PlanStore` **efface** au lieu d'écrire : `resumedFromDisk` ne peut
jamais fonctionner dans cette configuration.
Invisible tant que l'app vit (redépôt horaire) ; ne mord que Dart mort.

*Preuve dans vos propres tests* : `test/advert_plan_test.dart:111`
(« porte le MÊME nombre de jetons à chaque créneau ») ouvre sa fenêtre sur
**5 créneaux**, exactement l'horizon public — il ne peut pas voir la rupture.
Le test « l'identifiant public a un horizon BORNÉ » assère l'inverse sur 48.

**H2 — La révocation de mes propres contenus est inerte sur mon téléphone.**
La doc de `own_keys.dart` annonce un balayage. `OwnKeyStore.remove()` (:78) et
`ids()` (:82) n'ont **aucun appelant** ; `purgeRevoked()` ne touche que
`SavedStore`. Clé locale + cache `own/` conservés indéfiniment.

**H3 — Les médias expirés ne sont jamais supprimés du serveur.**
`neovibe_purge` supprime les lignes, pas les fichiers ; seul `library_vault` a
une purge d'octets. Mesuré : **88 objets orphelins sur 89** dans `stories`
(36,6 Mo), 8/74 dans `library`. `StoriesRepository.remove()` (:298) supprime la
ligne `stories` et laisse `contents` + `content_media_keys` (une ligne orpheline
du 2026-08-14 est encore en base).

**H4 — Une Vibe sans clé consomme quand même les vues.**
`open_card_media` incrémente `view_count` avant de lire la clé et ne vérifie
jamais son existence → `NULL` rendu, vue brûlée, `key as String` échoue côté
Dart. Atteignable : `create` insère `encrypted: true` puis appelle
`set_card_media_key` ensuite. Même trou dans `get_library_vibe_key`.

## Moyen (11)

M1 repli hérité cassé (`others()` prend « fichier existe » pour « complet »,
alors que `streamingPath` crée l'entrée d'index et le natif un fichier vide) ·
M2 le repli hérité laisse une vidéo **en clair** dans le temporaire, sans
`onDispose` · M3 `expiresAt` jamais passé au cache (péremption morte) et aucune
éviction sur `own/` malgré le `// usage LRU` · M4 tout membre d'un groupe peut
expulser tout autre membre · M5 le blocage laisse `library_access`, les
conversations et `meeting_days` ; et le chemin **octets** ne teste pas le
blocage alors que le chemin **clé** le teste · M6 `maxParallelSets = 6` →
au-delà de 5 amis, retour au mode cycle que le code décrit comme inacceptable ·
M7 `SightingBuffer` jette les constats les plus **récents** au-delà de 500
(atteint dès 11 amis sur une nuit) · M8 le Dart ignore la taille de bloc écrite
dans l'en-tête `NVC1` que le Kotlin lit · M9 les compteurs de diagnostic n'ont
pas la même durée de vie (`start()` en remet deux à zéro, pas les six autres) ·
M10 `AdvertOnAir.noteDemande` ne purge pas `enVol` → repère bloqué à `-1` après
un aller-retour d'interrupteur · M11 `friendsOnly()` déduit les rangs d'amis du
seul premier créneau — hypothèse jamais écrite, et c'est elle qui garantit
qu'on n'écrit pas l'identifiant public sur le disque.

## Commentaires périmés (5)

| Où | Affirme | Réalité |
|---|---|---|
| `BleEngine.kt:918` | « Le jeton d'ami est symétrique » | Plus depuis le 2026-08-26 — **la doc de classe du même fichier dit le contraire** |
| `own_keys.dart` | « effacée par le même balayage » | Aucun balayage (H2) |
| `content_media_cache.dart:98` | `// usage LRU` | Aucune éviction sur `own/` (M3) |
| `stories_repository.dart:300` | « le serveur ne les sert plus » | Exact, mais octets + clé + ligne `contents` restent (H3) |
| `test/advert_plan_test.dart:111` | « l'invariant sur lequel repose le tampon » | L'invariant est tombé ; la fenêtre du test l'empêche de le voir (H1) |

Motif commun : aucun n'était faux le jour où il a été écrit. Chacun a été périmé
par un changement **ailleurs**.

## Bas (11)

`mark_card_viewed` second chemin d'écriture vers `view_count` · `hot`/`mono`
encore dans l'énumération et la mécanique Hot encore implémentée ·
`tickProvider`/`expiryClockProvider` non auto-libérés (vérifié : riverpod 3.3.2,
`isAutoDispose = false` hors codegen) → `Timer.periodic(5 s)` à vie ·
`ProximityService` calcule la dérive avec le `slotMillis` de la **table** et
réveille sur celui du **plan** · `pendingScans.size` en O(n) à chaque annonce ·
`repartDuDisque()` compte comme battement du Dart · chemins de stockage des
Vibes bâtis sur l'horodatage, pas sur l'id · `motion.dart:270` garde-fou
`end == begin ? 1.0 : end` inopérant dans le cas visé (opacité `NaN`) ·
`ChunkedSeal.sealFile` suppose que `read(take)` rend exactement `take` ·
`SealedDataSource.Factory.created` non borné · `_done`/`_primed` non bornés.

## Vérifié et sain

- **Pas de course sur les fils du natif** : les rappels d'advertising *et* de
  scan sont livrés sur le fil principal par Android, `emitNext` y tourne aussi.
  Les `@Volatile` sont superflus, pas dangereux.
- 34/34 tables avec RLS active ; les 6 tables sensibles (clés, relais, vues,
  balises) ont **zéro** politique — donc aucun accès direct.
- 6 coffres privés. La lecture anticipée de 5 min sur `library_vault` ne donne
  que des octets scellés ; la clé reste refusée jusqu'à `reveal_at`.
- Sens des jetons de paire correct (émission sous mon nom, écoute sous le sien).
- Arithmétique du format `NVC1` juste des deux côtés, dernier bloc et fichier
  vide compris ; le natif refuse un fichier tronqué.
- `cardByIdProvider` n'est plus dupliqué dans l'écran de chat.
- Les 6 tâches cron tournent (288 succès/24 h, 0 échec).

## Questions pour Jay (arbitrages produit, pas techniques)

1. Le blocage doit-il aussi couper `library_access`, les conversations
   partagées, `meeting_days` ?
2. Dans un groupe, qui a le droit de retirer un membre ?
3. Faut-il supprimer les octets des stories expirées (et perdre toute
   récupération pour un signalement après coup) ?
4. Un contenu de moi, révoqué, doit-il devenir illisible pour moi ?
5. Plafond de 6 annonces simultanées : on le monte, ou le jeton public cède sa
   place aux amis quand il y a trop de monde ?

**À corriger en premier sans attendre** : C1 (une ligne de politique), C2
(retirer l'écriture directe sur `connection_requests`), H1 (une ligne au
superviseur + un test dont la fenêtre dépasse l'horizon public).

## Ce qui n'est pas prouvé

C1 et C2 sont établis par lecture des politiques et des droits de colonne, pas
par une exploitation réelle en base. H1 est établi par le calcul et par la
contradiction entre deux tests, pas par un relevé sur appareil.
