# Le serveur NeoVibe en Rust — le plan de construction

> **Décisions de Jay, 2026-09-26.**
> - Notre propre programme serveur (*« le but c'est le contrôle, la
>   scalabilité et la polyvalence. Totale. »*).
> - Écrit **en Rust**.
> - Construit **tout d'un coup**, domaine par domaine, chaque règle
>   **prouvée par comparaison** avec l'ancienne avant le déménagement.
> - **Pause des nouveautés côté serveur** pendant la construction. L'app
>   continue de tourner sur Supabase (quotas : RAPPELS #174), le travail
>   côté app et les corrections de bugs continuent.
>
> Ce document dit **quoi construire, dans quel ordre, et comment on prouve
> que c'est juste**. Au 2026-09-26, **rien n'est construit**. L'état de
> départ est dans `docs/demenagement-vps.md` (le dépôt reconstruit la base
> à l'identique).

## En une phrase

Un programme Rust, à nous, qui fait **tout ce que Supabase fait aujourd'hui
pour NeoVibe** (les comptes, le guichet des données, le direct, les
fichiers, le réveil des tâches) **et qui applique lui-même toutes les
règles du produit**. La base PostgreSQL ne fait plus que ranger, et **n'est
joignable que par lui**.

## 1. Ce que le serveur devra faire (relevé le 2026-09-26)

| Métier | Aujourd'hui | Ce que ça représente |
|---|---|---|
| **Les comptes** | logiciel de Supabase | inscription avec le plafond par téléphone, connexion, le « badge » (valable 1 h) et son renouvellement, déconnexion, suspension |
| **Le guichet des données** | logiciel de Supabase | **100 opérations** appelées par l'app, **36 tables** lues ou écrites directement, 3 appels du natif ; dont 13 opérations de la console d'administration (comprises dans les 100) |
| **Le direct** | logiciel de Supabase | **10 tables** suivies en direct, et l'indicateur « en train d'écrire » |
| **Les fichiers** | logiciel de Supabase | **7 coffres**, 24 règles d'accès aux fichiers, l'envoi en morceaux reprenables de la file de publication, la suppression |
| **Le réveil** | extension de la base | **11 tâches** automatiques (les balais) |
| **Le gardien** | NOTRE code, en SQL dans la base | **214 fonctions** (dont 16 déclencheurs), **~3 300 lignes** hors commentaires, **98 règles d'accès aux tables** (+ les 24 des fichiers) |

Tout est rangé domaine par domaine dans l'**annexe A**. C'est la liste de
contrôle du chantier.

## 2. Comment il sera rangé

Chaque domaine (les comptes, les amis, le chat, les soirées…) a **trois
rôles séparés**, dans le prolongement de la règle « on sépare tout ce qui
peut l'être » :

| Rôle | Ce qu'il fait | Ce qu'il ne fait JAMAIS |
|---|---|---|
| **le guichet** | reçoit la demande de l'app, vérifie le badge, lit la demande, renvoie la réponse | décider |
| **le gardien** | les règles : qui a le droit, ce qui se passe | parler au réseau ou à la base directement |
| **la cuisine** | lit et écrit dans la base | décider |

**Le test** : *pour changer une règle, je ne touche qu'au gardien de son
domaine.*

À côté des domaines, cinq services **communs** : le badge, le direct, les
fichiers, l'horloge et le réveil. L'horloge est une **source** : les règles
ne lisent jamais l'heure en cachette, elles la reçoivent, et les tests
peuvent la fixer.

**La sécurité s'énonce positivement** : *la base n'est joignable que par le
programme.* Aucun téléphone ne lui parle directement.

## 3. L'ordre de construction

| Étape | Ce qu'elle contient | Pourquoi à cette place |
|---|---|---|
| **0. Le socle** | le programme démarre, parle à sa base, écrit son journal ; la base d'essai sur le PC (Docker) ; **l'appareil de preuve par comparaison** (§4) | tout le reste s'appuie dessus |
| **1. Les comptes** | inscription (plafond par téléphone), connexion, badge, renouvellement, déconnexion, suspension ; profils de base | chaque demande commence par « qui es-tu ? » |
| **2. Les fichiers** | coffres, tickets signés pour lire et écrire, envoi en morceaux, suppression par le serveur | presque tous les domaines ont des photos ou des vidéos |
| **3. Le direct** | le canal en direct, les abonnements, « en train d'écrire » | le chat, les soirées et la carte en ont besoin |
| **4. Relations et proximité** | le ping, les croisements, les demandes d'ami, les recommandations, les blocages, les saluts, les paliers | la porte d'entrée du réseau ; le chat et les soirées en dépendent |
| **5. Conversations** | messages, vocaux, lus, masqués, groupes, catégories, conversation de proximité | |
| **6. Vibes et contenus** | envoi, stories, bibliothèque, Drop, clés des médias, vues, j'aime, partages, retraits, publication native | le cœur du contenu |
| **7. Pulse** | le fil | lit les Vibes et les relations |
| **8. Soirées** | événements, présence, positions, croisements en soirée, rencontres, défis, affiches, lieux, le balai | |
| **9. Carte** | positions des amis, partage, demandes, révélations, Vibes autour | lit les soirées et les Vibes |
| **10. Modération et administration** | signalements, blocages, suspension, la console d'administration | touche tous les domaines : en dernier |
| **11. L'app complète contre le serveur Rust** | le natif (file de publication, balise du ping, présence en soirée) ; une app de test entière | tout doit exister |
| **12. Mise en ligne et déménagement** | VPS, nom de domaine, https, sauvegardes, surveillance ; copie des données ; bascule ; retrait de Supabase de l'app et du gardien SQL de la base | la fin |

**Côté app** : les dépôts de l'app sont branchés sur le serveur Rust
**derrière un interrupteur de construction**, invisible dans ton app
habituelle, qui reste sur Supabase jusqu'au déménagement. C'est enfin la
couche d'accès de RAPPELS #12. ✏️ *Ajusté le 2026-09-27* : comme les
guichets reprennent **le nom et le JSON** des fonctions d'aujourd'hui, la
bascule de l'app se fait en une passe, à l'étape 11, par un seul
aiguillage (`rpc` → Supabase ou Rust) — au lieu de domaine par domaine.

## 4. Comment on prouve que c'est juste : la preuve par comparaison

**En clair.** Pour chaque règle, je prépare des situations : qui fait quoi,
et dans quel état est la base. Il y en a au moins une où la règle doit
accepter, une où elle doit refuser, plus les cas limites. Chaque situation
est jouée **deux fois, sur la même copie de la base** :

- une fois par l'**ancien gardien**, le SQL d'aujourd'hui, qui existe dans
  la copie ;
- une fois par le **programme Rust**.

Les deux doivent donner **la même réponse** (accepté ou refusé, les mêmes
données renvoyées) et **laisser la base dans le même état**. Une seule
différence donne un test rouge, et le domaine n'est pas fini.

Les 22 cas de l'audit de sécurité en font partie. **À la fin**, les réponses
de l'ancien gardien sont **figées dans les tests** : ils continuent de
protéger le serveur Rust après la disparition du SQL.

**Techniquement.**
- La base d'essai est reconstruite par `tool/repetition_vps` : la
  structure plus l'ancien gardien. On y ajoute des données : soit une copie
  de la base de dev (sur le PC, **jamais dans le dépôt**), soit des données
  fabriquées pour le test.
- Côté ancien, la situation est jouée sous l'identité de l'utilisateur
  (`set local role authenticated` + `request.jwt.claims`), comme l'audit.
- Côté nouveau, le service Rust est appelé directement. Chaque côté tourne
  dans sa propre transaction, annulée ensuite.
- On compare la réponse, puis les lignes touchées. On neutralise ce qui
  change à chaque fois : identifiants tirés au hasard et heure (l'horloge
  est injectée).
- **Couverture visée** : les 100 opérations de l'app, les 36 tables et
  leurs opérations directes, les 16 déclencheurs, les 11 tâches, les 24
  règles des fichiers, les 3 appels du natif.

## 5. Ce qui ne change pas, ce qui disparaît, ce qui se règle au passage

- **Ne change pas** : la base PostgreSQL et sa structure (tables,
  colonnes), le format scellé des médias et ses clés, les fonctionnalités
  de l'app, Mapbox, la proximité par BLE.
- **Disparaît à la fin** :
  - Supabase dans l'app (`supabase_flutter`) et dans le natif
    (`SupabaseHttp.kt`) ;
  - le gardien en SQL (214 fonctions, 122 règles d'accès), après avoir
    figé ses réponses ;
  - les rôles `anon` / `authenticated` et `auth.uid()`.

  Chaque suppression se fait en relevant les deux sens (règle 8).
- **Se règle au passage** :
  - **#111** : le serveur supprime lui-même les fichiers, sans attendre
    que l'app de leur propriétaire s'ouvre ;
  - **#12** : la couche d'accès côté app ;
  - « la règle vit au serveur » devient **structurel** ;
  - les tâches planifiées qui échouaient **en silence** : chaque passage
    sera journalisé ;
  - les 6 tables diffusées en direct que personne n'écoute.

## 6. Ce dont j'aurai besoin de Jay, et quand

| Quand | Quoi |
|---|---|
| **maintenant** | valider ce plan |
| étape 0 | rien d'obligatoire : je copie les données de dev par l'accès que j'ai déjà. Si ça coince, je demanderai le mot de passe de la base |
| **avant l'étape 12** | le **VPS** et le **nom de domaine** ; l'**entrepôt des fichiers** (AWS ou autre, en comparant le prix de la sortie) ; recopier les données de dev ou repartir de zéro ; la date du déménagement. ✏️ *2026-09-27* : l'étape 11 s'est faite sans eux, contre le serveur lancé sur le PC |
| ✅ fait le 2026-09-27, sans VPS | une **deuxième app « de test »** sur ton téléphone, à côté de la vraie : « NeoVibe (Rust) », reliée au serveur Rust **du PC, par le Wi-Fi de la maison** (voir « L'app d'essai » plus bas). Avec le VPS, la même app pourra le joindre de partout |

## 7. Hors de ce chantier

- **Juste après, dans l'ordre fixé par Jay** : les **plateformes** (gestion,
  administration, modération, commerçants), puis les **notifications même
  app fermée** (#173).
- **Plus tard** : le serveur média (`docs/serveur-media.md`), l'iPhone.

Ce chantier livre déjà la partie serveur de la **console d'administration
existante**. La plateforme complète vient ensuite.

## 8. Quand un domaine est-il « fini » ?

1. Chaque ligne de son inventaire (annexe A) a son équivalent en Rust.
2. La preuve par comparaison est verte pour chaque règle : au moins un cas
   accepté et un refusé, plus les cas limites.
3. Les cas de l'audit de sécurité qui le concernent sont verts contre le
   Rust.
4. Les dépôts de l'app correspondants sont réécrits derrière
   l'interrupteur, avec leurs tests.
5. `cargo clippy` et `cargo test` sont propres ; `dart format` et
   `flutter analyze` aussi.
6. Le rapport de séance et ce plan sont à jour (le domaine est coché
   ci-dessous).

## 9. Règles de construction, à chaque séance

1. **Avant d'écrire un domaine, relire en base** (pas dans les migrations)
   chaque fonction, règle et déclencheur du domaine, **en déroulant leurs
   appels jusqu'au bout**.
2. **Une règle vit à un seul endroit** : le gardien de son domaine. Une
   vérification commune (par exemple « ce compte est-il suspendu ? ») est
   écrite une fois et appelée partout, jamais copiée.
3. **Aucune erreur ignorée.** Chaque erreur a un code et un message en
   français pour l'app. Pas de `unwrap` hors des tests.
4. **Chaque tâche planifiée = une transaction**, et chaque passage est
   journalisé.
5. **Aucun secret dans le dépôt.** La configuration passe par des variables
   d'environnement et un fichier local ignoré par git.
6. **Toute correction faite sur le serveur Supabase pendant la
   construction** est inscrite au journal ci-dessous, puis reportée dans
   le domaine Rust.
7. **Relever le compteur de fichiers de Supabase** à chaque séance (#174).

## 10. Avancement

| Étape | État |
|---|---|
| 0. Le socle | ✅ 2026-09-27 — `server/` (espace Cargo : `nv-core`, `nv-app`, `nv-server`, `nv-proof`) ; base locale `outils/base_locale.py` (port 54329 : structure + ancien gardien + copie des données de dev + journal des changements) ; la preuve `cargo run -p nv-proof` (contre-testée : elle voit une réponse différente, une écriture manquante, un nouveau plus permissif, un cas mal posé) |
| 1. Les comptes | ✅ 2026-09-27 côté serveur — `/v1/auth/inscription · connexion · renouveler · deconnexion · moi` (badge Ed25519 1 h, jetons tournants, plafond par téléphone prouvé identique à l'ancien crochet SQL, bcrypt de Supabase accepté puis réécrit en argon2id, limite d'essais) ; `username_available`, `my_suspension`, `profile_stats`, `profiles_get · list`, `profile_create · update`, `dev_report_insert` — 25 situations identiques |
| 2. Les fichiers | ✅ 2026-09-27 — `nv-entrepot` (tout entrepôt compatible S3 : liens de lecture et de dépôt signés, taille et type signés, envoi en morceaux avec reprise, suppression), vérifié contre SeaweedFS local ; les 24 règles des coffres traduites (`fichiers/regles.rs`), les questions d'accès réécrites en expressions composables (`acces.rs`) ; guichets `files_sign_read · sign_upload · remove · upload_open · parts · part_url · finish · abort`, `mes_octets_a_supprimer`, `octets_supprimes` ; **le réveil** (`nv-server/src/taches.rs` : verrou, une transaction par passage, journal `nv.job_runs`) et le **balai des fichiers** (le serveur efface lui-même : règle RAPPELS #111) — 48 situations identiques |
| 3. Le direct | ✅ 2026-09-27 — `GET /v1/direct` (WebSocket : badge, abonnements `table:colonne=valeur`, diffusions `typing:…`, renouvellement du badge sans coupure) ; la base ANNONCE chaque changement des 10 tables suivies (`nv.annoncer`, canal `nv_direct` : tous les chemins y passent, cascades et balais compris) ; chaque ligne passe la règle de lecture de sa table (`nv-app/src/direct.rs`) ; `direct_instantane` (l'état à l'abonnement) — 15 situations identiques ; essai de bout en bout `outils/essai_direct.mjs` (deux comptes, message, « en train d'écrire », refus d'un non-membre, badge renouvelé) ✅. Écart voulu : « en train d'écrire » réservé aux membres de la conversation (avant : tout compte connaissant l'identifiant) |
| 4. Relations et proximité | ✅ 2026-09-27 — les 16 opérations (ping, croisements, demandes d'ami, blocages, recommandations, paliers) et 9 gestes directs de l'app (`device_key_upsert`, `key_book_list`, `connection_delete`, `connection_requests_history`, `recommendations_list`, `recommendation_create`, `blocks_list`, `waves_list`, `wave_insert`) ; déclencheurs traduits (`on_ping_pair_born`, `oublie_ce_qui_derivait_du_lien`) ; balais `balai_ping`, `balai_vues`, `paliers` — 58 situations identiques. **Défaut de l'ancien serveur trouvé et réparé** (voir le journal) |
| 5. Conversations | ✅ 2026-09-27 — **le passage obligé de tout message** (`conversations/messages.rs`, ex-`enforce_message_rules`) ; 6 opérations (groupe, conversation directe, canal de proximité, masquer, vocal envoyé / écouté) et 15 gestes directs (liste et détail des conversations avec leurs membres, titre, membres, envoi, dernier message, lus, participation, catégories) ; balais `balai_general` (ex-`neovibe_purge`) et `balai_canaux` — 42 situations identiques. Écart voulu : un vocal, un partage ou un ajout en bibliothèque ne s'écrivent plus directement dans le chat (chacun a sa porte et ses règles) |
| 6. Vibes et contenus | ✅ 2026-09-27 — `vibes/` : **le passage obligé des livraisons** (`livraisons.rs`, ex-`enforce_card_delivery_rules`, règles puis écriture) ; les Vibes envoyées (`cartes.rs` : clé, visionnages, replays, réglages, suppression, envoi avec une demande d'ami, et les gestes directs `card_get · create`, `card_delivery_create · mine`, `card_deliveries_pending_replay`, `card_replay_requests_mine`, `friend_share_defaults_*`) ; les contenus (`contenus.rs` : clé, vues, likes, partage, retraits, clés d'une bibliothèque, `content_flags · delete`, lieu de prise) ; le Drop (`drop.rs` : dépôt, clés, réglages, retrait, masquage, liste ; le reveal de 18 h 30 réécrit) ; publier et relire (`publication.rs` : story, bibliothèque, accès restreint, publication, bibliothèque d'un compte, stories) ; l'ancre gommée (`carte/ancre.rs`) ; **un profil se rend d'une seule façon** (`comptes::cuisine::profil_vu`, aussi pour les membres d'une conversation et l'auteur d'une story) ; balais `balai_drop` et `balai_retraits` — 135 situations identiques (298 au total). **Défaut de l'ancien serveur trouvé et réparé** (voir le journal) |
| 7. Pulse | ✅ 2026-09-27 — `pulse.rs` : `feed_items` (les trois sources — croisés, ajouts des amis, autour de moi —, fraîcheur `feed_rules`, 200 au plus ; l'ordre vit dans `rang`, seul endroit où brancher la pertinence), `feed_adders` (révélé seulement après mon like), `add_to_feed` ; **« autour de moi » écrit une fois pour le fil et la carte** (`carte/autour.rs` : `vibes_autour`, `distance_m`) ; une publication a une seule forme de lecture (`publication_complete`) — 14 situations identiques (312 au total) |
| 8. Soirées | ✅ 2026-09-27 — `soirees/` : les 20 opérations et `report_event_position` (le service natif), plus 4 gestes directs (`event_rules_map`, `event_presence_mine`, `event_challenges_list`, `meeting_delete`) ; `regles.rs` (présent, peut inviter / retirer, amis présents, lieu précis, taille, trop loin), `cuisine.rs` (**fermer une soirée** : croisements par présence → rencontres ; entrer dans un moment ; oublier une affiche), `balai.rs` (**le balai de chaque minute** : moments entre amis, partis, fermetures à l'heure et des désertées, purge ; et la mémoire des rencontres, chaque nuit) ; l'affiche vérifiée dans l'entrepôt ; **une seule formule de distance** (`carte::autour::distance_m`, l'ancien en avait deux) — 82 situations identiques (394 au total), balais compris (joués « par le système »). **Défaut de l'ancien serveur trouvé et réparé** (voir le journal) |
| 9. Carte | ✅ 2026-09-27 — `carte/guichet.rs` : les 9 opérations (amis sur la carte, partage, cacher, demander / répondre / état d'une demande, Vibes autour, Vibes à lire) et 3 gestes directs (`location_sharing_mine`, `location_hidden_list`, `map_rules_walking`) ; **qui voit ma position** écrit une fois (`peut_voir_position`) ; la demande de position passe par **la** conversation directe (`conversations::guichet::conversation_directe`) et le passage obligé des messages ; balais `balai_positions` et `balai_demandes` — 36 situations identiques (430 au total) |
| 10. Modération et administration | ✅ 2026-09-27 — `moderation/` : signaler (`report_sent_vibe · drop_vibe · event`, et les gestes directs `content_report_create`, `profile_report_create`) avec **la preuve scellée** (`preuves.rs`, ex-`scelle_la_preuve`) ; les 13 gestes d'administration (`admin.rs`), tous refusés hors de `admins` et journalisés — y compris regarder une preuve. La **libération** des preuves (`libere_la_preuve`) est reclassée FONDATION : elle doit voir la disparition d'un signalement par cascade — 45 situations identiques (475 au total) |
| 11. L'app complète | ✅ 2026-09-27 — **la couche d'accès de l'app** (`lib/core/api/` : `NvApi` les opérations, `NvDirect` le direct, `NvFichiers` les coffres, `NvAuth` la connexion ; `SupabaseBackend` pour l'app de tous les jours, `RustBackend` pour l'app d'essai — choisi à la construction, `--dart-define=SERVEUR=rust`) : les 48 fichiers de l'app qui parlaient à Supabase n'en parlent plus, les gestes directs sur les tables sont rangés sous le nom de l'opération Rust (`supabase_gestes.dart`). **Trois garde-fous** (`test/couche_d_acces_test.dart`) : seule la couche d'accès parle à Supabase ; chaque opération existe des deux côtés ; **chaque appel envoie exactement les champs que son guichet Rust accepte et exige** (181 appels, contre-testé des deux côtés). Le natif : `Serveurs.distant` → `SupabaseHttp` ou `RustHttp` (la file de publication en morceaux reprenables, la balise du ping, la présence en soirée). Essais de bout en bout contre le vrai serveur : l'app (`test/serveur_rust_bout_en_bout_test.dart` : comptes, refus, amis, conversation, direct, « en train d'écrire », fichiers) et le natif (`RustHttpEssaiTest.kt` : envoi en trois morceaux coupé puis repris, balise, présence, badge refusé — contre-testé). **L'app d'essai** « NeoVibe (Rust) » : un autre paquet, qui s'installe à côté de l'app habituelle (voir plus bas). **La base du serveur est séparée de la référence de la preuve** (`nv_serveur` ≠ `postgres`, `outils/base_locale.py`). Au passage : les recommandations et les bloqués rendent enfin leurs profils par `profil_vu` (ils recopiaient le masque). 475 situations identiques |
| 12. Mise en ligne et déménagement | 🟡 commencée le 2026-09-29 — **le VPS est prêt** (voir « Le VPS » plus bas) : PostgreSQL 17, portier https (Caddy, certificat de `api.neovibe.fun`), le serveur construit sur place contre sa base, sous son propre rôle `nv_server` (données seulement) ; base `neovibe` montée par **la même recette que la base locale** (`outils/recette_base.sh`) avec une copie fraîche des données de dev ; sauvegarde chaque nuit + restauration essayée, y compris sur un serveur de base neuf. **Même jour** : clé S3 du serveur posée (8 coffres, rien d'autre) ; **le serveur tourne** sur `https://api.neovibe.fun` ; essais de bout en bout ✅ contre lui ; les **999 fichiers** de la dev recopiés dans R2 (657 Mo, 0 échec) ; sauvegardes copiées chaque nuit hors du VPS (coffre verrouillé 30 jours). **✅ BASCULE le 2026-09-29 (v0.9.300)** : copie fraîche de la dev (base + fichiers ; les fichiers de R2 inconnus de la base effacés une fois, par un outil de bascule retiré ensuite : après la bascule, `storage.objects` ne dit plus la vérité — le serveur Rust ne la tient pas), ancien gardien éteint en service (le serveur refuse de démarrer sinon), **Supabase en pause**, l'app de tous les jours parle à `https://api.neovibe.fun`. **Reste** : le RETRAIT de l'ancien gardien et de Supabase (base : déclencheurs, fonctions, règles RLS, `storage.objects` figée ; app : `SupabaseBackend`, `supabase_flutter`, `env.dart`) — avec le `cartographe` ; la surveillance (#11) ; la purge avant l'ouverture (#176 ⑥) |

**Écarts voulus entre l'ancien et le nouveau gardien** (visibles dans la
preuve, chacun justifié) :

- 2026-09-27 : la **suspension d'un autre compte** (`suspended_at`,
  `suspended_reason`) ne se lit plus en lisant son profil. L'ancien guichet
  la donnait à quiconque voyait le profil ; l'app ne s'en sert pas.
- 2026-09-27 : **« en train d'écrire »** n'est plus audible que par les
  membres de la conversation (l'ancien canal de diffusion n'avait aucune
  règle : tout compte connaissant l'identifiant pouvait l'écouter).
- 2026-09-27 : les **protections de la base** (nom déjà pris, forme d'un
  nom…) répondent par une phrase (« Ce nom est déjà pris. ») au lieu du nom
  technique de l'index.

**Journal des corrections faites sur Supabase pendant la construction**
(à reporter dans le Rust) :

- 2026-09-26 : `library_items` ajoutée au direct (« [Ami] a publié »). Le
  direct en Rust doit la diffuser. `enforce_library_card_rules` supprimée
  (orpheline) : rien à reporter.
- 2026-09-27 : **une rencontre en soirée sans lieu faisait tout planter**
  (`private.note_meeting` lisait une variable jamais remplie quand la
  soirée n'a pas de lieu — une soirée privée) : `report_sightings` échouait
  en entier, reconnaissances entre amis comprises. Trouvé par la preuve,
  reproduit sur la base de dev sous identité, réparé
  (`20260927100000_rencontre_en_soiree_sans_lieu.sql`). Le Rust le faisait
  déjà juste.

- 2026-09-27 : **les messages de la publication avaient des accents
  abîmés** (« MÃ©dias manquants », hérité de `le_feed_pulse.sql`) :
  reproduit sous identité, réparé (`20260927110000_accents_de_la_publication.sql`).
- 2026-09-27 : **envoyer une Vibe avec une demande d'ami à quelqu'un
  croisé échouait TOUJOURS** (la règle des livraisons refusait tout
  non-ami, alors que la fonction n'existe que pour eux) : reproduit sous
  identité, réparé au plus étroit — une livraison à un non-ami n'est permise
  qu'avec SA demande en attente portant CETTE Vibe
  (`20260927110100_la_vibe_jointe_a_une_demande.sql`). Audit 22/22.
- 2026-09-27 : **une Vibe passée en « vues illimitées » après un replay
  accordé ne s'ouvrait plus** (« integer out of range » : la limite + 1
  dépassait le plus grand entier). Chemin réel : Vibe à 2 vues, replay
  demandé puis accordé, puis l'auteur la passe en illimité. Reproduit par la
  preuve sous l'identité du destinataire, réparé
  (`20260927120000_replay_sur_vibe_illimitee.sql`, calcul en grand entier).
  Le Rust le faisait déjà juste. Audit 22/22.
- 2026-09-27 : **retirer quelqu'un d'une soirée privée (ou la quitter)
  échouait TOUJOURS** (« left_reason is of type event_leave_reason but
  expression is of type text ») : le bouton « Retirer » de l'app ne pouvait
  jamais réussir. Reproduit par la preuve sous l'identité de Charles, réparé
  (`20260927130000_retirer_d_une_soiree_privee.sql`). Le Rust le faisait
  déjà juste. Audit 22/22.

**Les fondations** — ce qui RESTE dans la base, parce qu'il doit voir tous
les chemins, effacements en cascade compris : les contraintes (liens,
unicité, formes), l'horodatage des profils (`set_updated_at`), les pierres
tombales des fichiers (`inscrit_*`, `oublie_l_affiche` — déclencheur
`events_affiche_au_balai`), l'annonce des
disparitions (`annonce_une_disparition`), l'activité des conversations
(`note_conversation_activity`), les annonces du direct (`nv.annoncer`), et la
libération des preuves de modération (`libere_la_preuve` : un signalement
qui disparaît par cascade — son contenu effacé — doit libérer ses fichiers).
Tout le reste des déclencheurs de l'ancien gardien est traduit en Rust ;
**la preuve joue le nouveau côté avec ces déclencheurs coupés** (sinon
l'ancien tiendrait à la place du Rust une règle oubliée), et le test
`sans_ancien_gardien` vérifie que le Rust n'appelle aucune fonction de
l'ancien gardien. Chaque situation peut exiger que l'ancien gardien ÉCRIVE
(`doit_changer`) : une situation qui ne produit rien est « mal posée ».

⚠️ **En service, l'ancien gardien N'EXISTE PLUS** (2026-09-29). D'abord
éteint (il tournait à côté du serveur et notait la rencontre au ping en
double), il a été **retiré** le même jour des bases en service par une
migration « en service » (`server/migrations_en_service/`, jouée une fois :
VPS par `deployer.sh`, `nv_serveur` du PC par `base_locale.py --serveur`) —
avec les règles RLS, 260 fonctions, les rôles et imitations de Supabase
(inventaire du cartographe ; il reste les 11 fonctions de fondation et
leurs 23 déclencheurs). **La base de référence de la preuve le garde**,
comme étalon. La liste de ses déclencheurs vit dans
`nv_app::ancien_gardien` (la preuve et le serveur la lisent) ; **le serveur
refuse de démarrer si l'un d'eux existe**.

**Deux dossiers de migrations** : `server/migrations/` (toute base : la
référence, le PC, le VPS) et `server/migrations_en_service/` (seulement les
bases en service). Sur le VPS, `deployer.sh` applique les deux, chaque
fichier UNE fois (table `nv.migrations`, avec son empreinte : un fichier
modifié après application arrête le déploiement), AVANT la construction —
une migration doit laisser l'ancien programme tourner (ajouter, pas
casser).

## Mode d'emploi du chantier

| Geste | Commande (depuis `server/`) |
|---|---|
| copier les données de dev sur le PC | `python server/outils/copier_base_dev.py` — ⚠️ lit l'ancien serveur (Supabase), **en pause** depuis la bascule : la copie existante (`docdev/copie_base_dev/`) reste la donnée de la référence |
| (re)monter la base locale | `python outils/base_locale.py` (depuis la racine du dépôt) — ⚠️ **deux bases** : `postgres`, **la référence** de la preuve (personne ne la modifie), et `nv_serveur`, **la base de travail** du serveur et des essais, copiée de la référence |
| remettre la base du serveur à l'état de la référence | `python server/outils/base_locale.py --serveur` (copie de la référence + les migrations « en service ») |
| construire | `bash outils/cargo.sh build` — ⚠️ sur ce PC, la chaîne « GNU » de Rust a un éditeur de liens incomplet : le script branche celui de WinLibs |
| jouer la preuve | `bash outils/cargo.sh run -p nv-proof -- [filtre]` (sur la référence) |
| monter l'entrepôt de fichiers local | `python server/outils/entrepot_local.py` (SeaweedFS, port 8333 ; MinIO n'est plus distribué en image — constaté le 2026-09-27) ; accès dans `docdev/serveur_local.env`, chargés par `outils/cargo.sh` |
| lancer le serveur | `bash outils/cargo.sh run -p nv-server` (écoute sur `127.0.0.1:8787`, base `nv_serveur`) |
| lancer le serveur **pour le téléphone** | `bash server/outils/serveur_telephone.sh` (écoute sur le réseau local ; liens de fichiers à l'adresse du PC) |
| construire **l'app d'essai** | `bash server/outils/app_d_essai.sh` → `build/essai_rust/NeoVibe-Rust.apk` ; avec `--publier` : une pré-version GitHub `essai-rust-v<version>` (à télécharger sur le téléphone, jamais vue par le bouton de mise à jour de l'app habituelle) |
| essais de bout en bout (serveur lancé) | `NV_SERVEUR_ESSAI=http://127.0.0.1:8787 flutter test test/serveur_rust_bout_en_bout_test.dart` ; natif : `cd android && NV_SERVEUR_ESSAI=http://127.0.0.1:8787 ./gradlew :app:testDebugUnitTest --tests '*RustHttpEssaiTest*'` |

## Le VPS (étape 12)

**La machine** : Hostinger KVM 2 (Vilnius), Ubuntu 26.04, `2.24.162.2`,
nom public `api.neovibe.fun`. Accès : `ssh -i ~/.ssh/neovibe_vps
root@2.24.162.2`, clé seulement. Tout ce qui y est posé l'est par les
scripts de `server/outils/vps/`, versionnés — rien à la main.

| Geste (depuis le PC, racine du dépôt) | Commande |
|---|---|
| installer / remettre d'aplomb le socle (rejouable) | `bash server/outils/vps/deployer.sh --installer` |
| appliquer les migrations, construire et relancer le serveur | `bash server/outils/vps/deployer.sh` — ✏️ depuis la bascule, la base du VPS est LA base : plus de geste qui la reconstruit depuis la dev (`--base`, `--fichiers` retirés le 2026-09-29) ; en cas de malheur, on RESTAURE une sauvegarde |
| l'app d'essai vers le VPS | `bash server/outils/app_d_essai.sh [--publier] --vps` (pré-version `essai-rust-vps-v…`, distincte de celle du PC) |
| poser / relire les règles du coffre des sauvegardes (verrou 30 j, effacement 31 j) | `python server/outils/vps/regles_r2.py [--lire]` |
| essais de bout en bout contre le VPS | `NV_SERVEUR_ESSAI=https://api.neovibe.fun flutter test test/serveur_rust_bout_en_bout_test.dart` (la base préparée suit l'adresse) |
| restaurer une sauvegarde (sur le VPS) | `/opt/neovibe/bin/restaurer.sh /var/backups/neovibe/neovibe-<date>.dump [base]` — **jamais `pg_restore` seul** (voir le script : rôles et réglages) |

**Ce qui y tourne, énoncé positivement :**

- **Entrent** : SSH (clé seulement, ni mot de passe ni tunnel), 80 et 443
  (Caddy). Tout le reste est refusé (ufw).
- **La base** n'écoute que la machine. `postgres` n'a pas de mot de
  passe : on ne l'atteint que par `sudo -u postgres` (migrations,
  sauvegardes). **Le serveur se connecte en `nv_server`**
  (`server/migrations/20260929000000_le_role_du_serveur.sql`) : lire et
  écrire des données, rien d'autre — ni commande système, ni lecture de
  fichiers, ni changement de structure, ni rôle (vérifié sous identité le
  2026-09-29). Il passe outre les anciennes règles RLS, qui supposent
  `auth.uid()`.
- **Le portier** (Caddy) n'a pas d'interface d'administration ; il écrit
  l'adresse du téléphone dans `X-Forwarded-For` en remplaçant celle du
  client (aucun portier « de confiance » : ne jamais en déclarer). Le
  serveur ne lit cet en-tête que si `NV_PORTIER_LOCAL=1` et la connexion
  vient de la machine ; il compte une IPv6 par bloc /64 et les connexions
  aussi par compte visé.
- **Les secrets** sont dans `/etc/neovibe/nv-server.env` (root, 600) :
  tirés au sort sur place (mot de passe de `nv_server`, clé des badges),
  sauf la clé S3 (Jay). Jamais dans le dépôt.
- **Les sauvegardes** : chaque nuit à 03:30 UTC, `/var/backups/neovibe/`
  (postgres, 700), 14 jours — la base (`.dump`) et les rôles
  (`roles-<date>.sql`) ; puis **copiés hors du VPS** dans le coffre R2
  `neovibe-sauvegardes`, **verrouillé** : aucune clé, même celle du
  serveur, ne peut y effacer ou remplacer une sauvegarde avant 30 jours
  (vérifié le 2026-09-29 : refusé, `ObjectLockedByBucketPolicy`) ;
  effacées à 31 jours. Chaque passage, réussi ou raté, est noté dans
  `nv.job_runs` (`job = 'sauvegarde'`) — noté, pas encore signalé à
  quelqu'un (surveillance : RAPPELS #11). **Restaurer depuis R2** :
  télécharger le `.dump` et le `roles-` de la même date dans un même
  dossier du VPS, puis `restaurer.sh`.

## L'app d'essai (étape 11)

**Ce que c'est.** Une deuxième app sur ton téléphone, « NeoVibe (Rust) »,
qui fait tout ce que fait NeoVibe mais parle au **serveur Rust lancé sur le
PC** au lieu de Supabase. C'est un **autre paquet**
(`com.neovibe.neovibe.essairust`) : elle s'installe **à côté** de ton app
habituelle, sans la remplacer ni toucher à ses données. Ton app de tous les
jours, elle, reste sur Supabase jusqu'au déménagement.

**Comment elle joint le serveur.** Par le **Wi-Fi de la maison** : le
téléphone et le PC doivent être sur la même box, le PC allumé, le serveur
lancé (`serveur_telephone.sh`). Hors de la maison, elle ne trouve rien —
c'est le rôle du futur VPS. L'adresse du PC est gravée dans l'app : si la
box lui en donne une autre, il faut la reconstruire (le script le signale).

⚠️ Le Wi-Fi **principal** de la box, pas le Wi-Fi « invité » : celui-là
isole les appareils les uns des autres, et le téléphone ne verrait pas le
PC.

**Le pare-feu de Windows.** Sur le PC de Jay, il laisse déjà entrer
(relevé le 2026-09-27 : règles « nv-server » et « Docker Desktop
Backend », entrantes, autorisées, réseau public — créées au premier
lancement ; les deux ports répondent depuis un conteneur, hors de l'accès
local). **Seulement si le téléphone ne joint pas le serveur**, ouvrir les
deux ports — PowerShell **en administrateur** :

```
New-NetFirewallRule -DisplayName "NeoVibe essai (serveur Rust)" -Direction Inbound -Protocol TCP -LocalPort 8787,8333 -RemoteAddress LocalSubnet -Action Allow -Profile Any
```

`LocalSubnet` : seuls les appareils de la maison peuvent entrer. Pour
refermer : `Remove-NetFirewallRule -DisplayName "NeoVibe essai (serveur Rust)"`.

**Ce qu'il faut savoir en l'utilisant.**

- **Connecte-toi avec ton compte habituel** : la base du serveur est une
  copie de la base de dev (tes amis, tes conversations, tes soirées, au jour
  de la copie). Tout ce que tu fais dans l'app d'essai reste sur le PC.
- **Les anciennes photos et vidéos ne s'affichent pas** : leurs fichiers
  sont restés chez Supabase (le déménagement des fichiers est l'étape 12).
  Tout ce que tu crées dans l'app d'essai s'affiche.
- **Pour tester à deux** (chat, ping, soirée), l'autre téléphone doit aussi
  avoir l'app d'essai : les deux mondes ne se voient pas.
- **Le bouton « Mise à jour » de l'app d'essai installe l'app habituelle**
  (il lit la dernière version publiée) : l'app d'essai se met à jour par
  une nouvelle construction.
- **Ne lance pas le ping dans les deux apps en même temps** : le téléphone
  annoncerait deux identités.

## Annexe A — l'inventaire, domaine par domaine

Relevé le 2026-09-26 dans le code (`lib/`, `android/`) et en base de dev. **Tout y est rangé** : 100 procédures appelées par l'app sur 100, 74 tables et vues sur 74, 16 fonctions déclencheurs sur 16, 11 tâches sur 11 (vérifié par un script, pas à la main). C'est la liste de contrôle de chaque domaine : un domaine n'est fini que quand chaque ligne a son équivalent en Rust ET sa preuve par comparaison.

### A.1 Comptes et profils

- **Comptes** : inscription (avec l'empreinte du téléphone : `device_hash`), connexion par mot de passe, badge et renouvellement, déconnexion, session courante
- **Procédures appelées par l'app (3)** : `username_available`, `my_suspension`, `profile_stats`
- **Tables (5)** : `profiles`, `private.device_signups`, `private.signup_device_exempt`, `private.signup_rules`, `dev_reports`
- **Déclencheurs** : `record_device_signup`, `set_updated_at`, `refuse_si_suspendu`
- **Coffres de fichiers** : avatars

### A.2 Fichiers

- **Procédures appelées par l'app (2)** : `mes_octets_a_supprimer`, `octets_supprimes`
- **Appels du natif** : envoi par morceaux reprenables (`SupabaseHttp.tusCreate` / `tusPatch`), suppression d'un objet
- **Tables (1)** : `storage_tombstones`
- **Coffres de fichiers** : les 7 : `avatars`, `cards`, `event_posters`, `library`, `library_vault`, `media`, `stories` — et leurs 24 règles d'accès

### A.3 Relations et proximité

- **Procédures appelées par l'app (16)** : `publish_ping_beacon`, `retire_ping_beacon`, `confirm_ping`, `ping_nearby`, `ping_neighbour_count`, `report_sightings`, `crossed_recently`, `request_connection_from_proximity`, `accept_connection_request`, `decline_connection_request`, `my_friendships`, `block_user`, `unblock_user`, `accept_recommendation`, `decline_recommendation`, `forward_recommendation`
- **Appels du natif** : `publish_ping_beacon` (LocationBeat.kt)
- **Tables (12)** : `device_keys`, `key_book`, `connections`, `connection_requests`, `recommendations`, `blocks`, `waves`, `encounters`, `sightings`, `ping_beacons`, `ping_pairs`, `ping_confirmations`
- **Déclencheurs** : `oublie_ce_qui_derivait_du_lien`, `on_ping_pair_born`
- **Tâches planifiées** : `neovibe_purge_ping`, `neovibe_purge_sightings`, `neovibe_tiers`
- **Direct** : `connections`, `connection_requests`

### A.4 Conversations

- **Procédures appelées par l'app (6)** : `create_group_conversation`, `get_or_create_direct_conversation`, `get_or_create_proximity_conversation`, `hide_message`, `send_voice_message`, `open_voice_message`
- **Tables (9)** : `conversations`, `conversation_members`, `messages`, `message_reads`, `conversation_participation`, `conversation_categories`, `conversation_category_members`, `hidden_messages`, `message_media_keys`
- **Déclencheurs** : `enforce_message_rules`, `note_conversation_activity`
- **Tâches planifiées** : `neovibe_purge`, `neovibe_purge_proximity_conversations`
- **Direct** : `messages` ; l'indicateur « en train d'écrire » (diffusion sans stockage)
- **Coffres de fichiers** : media

### A.5 Vibes et contenus

- **Procédures appelées par l'app (25)** : `set_card_media_key`, `open_card_media`, `mark_card_viewed`, `grant_replay`, `request_replay`, `update_sent_vibe`, `delete_sent_vibe`, `request_connection_with_vibe`, `open_content_media`, `record_content_view`, `content_viewers`, `content_viewer_count`, `toggle_like`, `content_likers`, `content_likes_summary`, `share_content`, `revoked_contents`, `library_media_keys`, `publish_story`, `add_vibe_to_library`, `get_library_vibe_key`, `drop_keys`, `update_drop_vibe`, `delete_drop_vibe`, `hide_drop_vibe`
- **Appels du natif** : `publish_to_library` (PublishPipeline.kt)
- **Tables (18)** : `cards`, `card_deliveries`, `card_media_keys`, `contents`, `content_media_keys`, `content_grants`, `content_likes`, `content_views`, `stories`, `library_items`, `library_media`, `library_access`, `library_vibes`, `library_vibe_keys`, `library_vibe_hidden`, `friend_share_defaults`, `capture_places`, `removals`
- **Déclencheurs** : `enforce_card_delivery_rules`, `inscrit_les_octets_a_supprimer`, `inscrit_le_media_a_supprimer`, `inscrit_les_octets_de_vibe`, `annonce_une_disparition`
- **Tâches planifiées** : `neovibe_purge_library`, `neovibe_purge_removals`
- **Direct** : `card_deliveries`, `library_items`, `removals`
- **Coffres de fichiers** : cards, stories, library, library_vault

### A.6 Pulse

- **Procédures appelées par l'app (3)** : `feed_items`, `feed_adders`, `add_to_feed`
- **Tables (2)** : `feed_adds`, `feed_rules`

### A.7 Soirées

- **Procédures appelées par l'app (20)** : `close_event`, `create_open_event`, `create_private_event`, `event_hot_spots`, `event_people`, `event_recap`, `invite_to_event`, `join_event`, `leave_event`, `met_before`, `my_events`, `my_meetings`, `nearby_events`, `post_challenge`, `remove_from_event`, `set_event_details`, `set_event_member_role`, `set_event_place`, `set_event_size`, `update_event_settings`
- **Appels du natif** : `report_event_position` (EventPresenceService.kt)
- **Tables (13)** : `events`, `event_group_members`, `event_presences`, `event_positions`, `event_sightings`, `event_crossings`, `event_challenges`, `event_rules`, `venues`, `venue_managers`, `crossing_windows`, `meetings`, `meeting_days`
- **Déclencheurs** : `on_event_crossing_born`, `affiche_d_un_evenement_parti`
- **Tâches planifiées** : `neovibe_events`, `neovibe_purge_meetings`
- **Direct** : `event_group_members`, `event_presences`, `event_challenges`
- **Coffres de fichiers** : event_posters

### A.8 Carte

- **Procédures appelées par l'app (9)** : `friends_on_map`, `share_my_location`, `set_location_sharing`, `set_location_hidden`, `request_location`, `answer_location_request`, `location_request_state`, `map_vibes_around`, `map_vibe_items`
- **Tables (6)** : `location_sharing`, `location_hidden_from`, `map_rules`, `friend_locations`, `location_requests`, `location_reveals`
- **Tâches planifiées** : `neovibe_purge_friend_locations`, `neovibe_purge_location_requests`
- **Direct** : `location_requests`

### A.9 Modération et administration

- **Procédures appelées par l'app (16)** : `report_sent_vibe`, `report_drop_vibe`, `report_event`, `am_i_admin`, `admin_actions`, `admin_close_event`, `admin_delete_content`, `admin_events`, `admin_remove_event_poster`, `admin_report_evidence`, `admin_reports`, `admin_resolve_report`, `admin_stats`, `admin_suspend_user`, `admin_unsuspend_user`, `admin_users`
- **Tables (8)** : `admins`, `moderation_actions`, `moderation_holds`, `content_reports`, `profile_reports`, `card_reports`, `event_reports`, `library_vibe_reports`
- **Déclencheurs** : `scelle_la_preuve`, `libere_la_preuve`
- **Coffres de fichiers** : (preuves scellées : lecture des coffres par l'admin)

**Notes d'inventaire.**

- `refuse_si_suspendu` (déclencheur) est rangé dans « Comptes » mais garde cinq tables de domaines différents (`cards`, `connection_requests`, `content_likes`, `recommendations`, `waves`) : en Rust, c'est UNE vérification partagée (« ce compte est-il suspendu ? ») que chaque domaine appelle, pas cinq copies.
- La publication du direct contient aujourd'hui 16 tables ; l'app n'en écoute que 10. Les 6 autres (`recommendations`, `conversations`, `conversation_members`, `message_reads`, `waves`, `events`) ne sont écoutées par personne : le direct en Rust ne les reprend pas.
- `walking_route.dart` parle directement à Mapbox (itinéraires) : ce n'est pas notre serveur, rien ne change.
- Au 2026-09-26, deux défauts trouvés par cet inventaire ont été réparés sur le serveur actuel : une fonction orpheline supprimée (`enforce_library_card_rules`) et `library_items` ajoutée au direct (la notification « [Ami] a publié » ne pouvait jamais arriver).

## Annexe B — les choix techniques proposés

Ce sont des choix de ma responsabilité, signalés à Jay. Ils sont confirmés
à l'étape 0, et chacun peut être discuté.

| Sujet | Choix | Pourquoi |
|---|---|---|
| Langage | Rust stable. Sur ce PC : 1.97.1, chaîne GNU active et gcc de WinLibs. Le VPS compilera sous Linux | décision de Jay |
| Serveur HTTP | `axum` sur `tokio` | le plus répandu en Rust, maintenu par l'équipe de `tokio` |
| Accès à la base | PostgreSQL 17 via `sqlx`, **requêtes vérifiées à la construction**. ✏️ *Relevé le 2026-09-29* : il n'y a PAS de métadonnées `.sqlx/` dans le dépôt — la construction exige une base (sur le PC, la base locale ; sur le VPS, sa propre base, sous le rôle `nv_server`) | un oubli (colonne supprimée, table renommée) casse la construction au lieu de casser chez Jay |
| Schéma | départ : les migrations de `supabase/migrations/` (prouvées par `tool/repetition_vps`) ; ensuite des migrations `sqlx` dans `server/migrations/` ; à l'étape 12, une base de départ propre, sans les restes de Supabase | |
| Mots de passe | `argon2id`. Les comptes existants gardent leur empreinte `bcrypt` de Supabase : elle est vérifiée à la connexion, puis réécrite en argon2id | rien à redemander aux utilisateurs |
| Badge | jeton signé Ed25519 valable 1 h (comme aujourd'hui) ; renouvellement par un jeton opaque, stocké haché, **tournant**, dont la réutilisation est détectée | le natif s'appuie déjà sur un badge d'1 h |
| Cryptographie | **aucune maison** : uniquement des bibliothèques éprouvées | les fuites naissent là |
| Direct | WebSocket. Abonnements par sujet (une conversation, une soirée, « moi »), autorisés par le gardien au moment de l'abonnement. On diffuse **après** l'écriture en base. Entre plusieurs machines plus tard : `LISTEN/NOTIFY` de PostgreSQL | pas de logiciel de plus au départ |
| Fichiers | entrepôt **compatible S3**, le standard que parlent AWS et les autres ; tickets signés pour lire et écrire. Envoi en morceaux (multipart S3 ; les morceaux de 6 Mo d'aujourd'hui conviennent, le minimum est 5 Mo). L'imitation locale compatible S3 est choisie à l'étape 2 | les octets ne passent pas par le programme |
| Réveil | tâches dans le programme, avec des horaires façon cron ; un verrou PostgreSQL pour qu'une seule machine exécute chaque tâche ; chaque passage journalisé | |
| Journal | `tracing` | |
| Contrat app ↔ serveur | la liste des guichets décrite en OpenAPI, générée depuis le code | l'app et le serveur restent d'accord |
| Côté app | `lib/core/api/` (le client : badge, guichets, direct, fichiers) ; les dépôts réécrits derrière `--dart-define=SERVEUR=rust` ; côté natif, une nouvelle implémentation de l'interface `Remote` (`PublishPipeline`) et des appels de `LocationBeat` / `EventPresenceService` | l'interface `Remote` existe déjà : la file de publication est prête à changer de serveur |
| Rangement | `server/` à la racine du dépôt (espace de travail Cargo, un module par domaine) ; `server/target/` ignoré par git | |
| Machine de développement | Docker (PostgreSQL 17 déjà présent, plus l'imitation S3) | ⚠️ le disque C: n'a que ~13 Go libres : les gros fichiers de construction restent sur D: |

