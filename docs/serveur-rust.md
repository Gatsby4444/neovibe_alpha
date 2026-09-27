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
| **avant l'étape 11** | le **VPS** et le **nom de domaine** ; l'**entrepôt des fichiers** (AWS ou autre, en comparant le prix de la sortie) ; recopier les données de dev ou repartir de zéro ; la date du déménagement |
| en option, plus tôt | une **deuxième app « de test »** sur ton téléphone, à côté de la vraie, reliée au serveur Rust en ligne, pour tester avant la fin. Il faut alors payer le VPS plus tôt |

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
| 7. Pulse | à faire |
| 8. Soirées | à faire |
| 9. Carte | à faire |
| 10. Modération et administration | à faire |
| 11. L'app complète | à faire |
| 12. Mise en ligne et déménagement | à faire |

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

**Les fondations** — ce qui RESTE dans la base, parce qu'il doit voir tous
les chemins, effacements en cascade compris : les contraintes (liens,
unicité, formes), l'horodatage des profils (`set_updated_at`), les pierres
tombales des fichiers (`inscrit_*`, `oublie_l_affiche`), l'annonce des
disparitions (`annonce_une_disparition`), l'activité des conversations
(`note_conversation_activity`), et les annonces du direct (`nv.annoncer`).
Tout le reste des déclencheurs de l'ancien gardien est traduit en Rust ;
**la preuve joue le nouveau côté avec ces déclencheurs coupés** (sinon
l'ancien tiendrait à la place du Rust une règle oubliée), et le test
`sans_ancien_gardien` vérifie que le Rust n'appelle aucune fonction de
l'ancien gardien. Chaque situation peut exiger que l'ancien gardien ÉCRIVE
(`doit_changer`) : une situation qui ne produit rien est « mal posée ».

## Mode d'emploi du chantier

| Geste | Commande (depuis `server/`) |
|---|---|
| copier les données de dev sur le PC | `python outils/copier_base_dev.py` (depuis la racine du dépôt : `python server/outils/copier_base_dev.py`) |
| (re)monter la base locale | `python outils/base_locale.py` (depuis la racine du dépôt) |
| construire | `bash outils/cargo.sh build` — ⚠️ sur ce PC, la chaîne « GNU » de Rust a un éditeur de liens incomplet : le script branche celui de WinLibs |
| jouer la preuve | `bash outils/cargo.sh run -p nv-proof -- [filtre]` |
| monter l'entrepôt de fichiers local | `python server/outils/entrepot_local.py` (SeaweedFS, port 8333 ; MinIO n'est plus distribué en image — constaté le 2026-09-27) ; accès dans `docdev/serveur_local.env`, chargés par `outils/cargo.sh` |
| lancer le serveur | `bash outils/cargo.sh run -p nv-server` (écoute sur `127.0.0.1:8787`) |

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
| Accès à la base | PostgreSQL 17 via `sqlx`, **requêtes vérifiées à la construction**. Les métadonnées `.sqlx/` sont versionnées pour construire sans base | un oubli (colonne supprimée, table renommée) casse la construction au lieu de casser chez Jay |
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

