# Le déménagement vers un VPS — état de préparation (2026-09-26)

> Demande de Jay, 2026-09-26 : *« vérifie que tout dans l'App est prêt à
> être transféré et utilisable sur un VPS et que tout va bien migrer et
> fonctionner »*, en attendant qu'il choisisse un VPS. Ordre qu'il a fixé :
> **la vraie couche serveur et les plateformes (gestion, administration,
> modération) avant les notifications**.
>
> Tout ce qui suit a été **relevé ce jour-là, à la source** (base de dev,
> code, répétition dans Docker). À rejouer avant le jour J :
> `python tool/repetition_vps/repeter.py`.

## En une phrase

**Le serveur de NeoVibe se reconstruit à l'identique à partir du dépôt**,
depuis ce jour et pas avant : deux morceaux n'existaient qu'en base de dev,
ils ont été reconstitués.

## Ce qui a été vérifié

| Vérification | Résultat |
|---|---|
| Les 115 fichiers de `supabase/migrations/` rejoués dans une base **vide** (Postgres 17, Docker) | ✅ sans erreur, après correction (voir plus bas) |
| La base reconstruite comparée à la base de dev, objet par objet : tables, colonnes, contraintes, index, 215 fonctions, droits d'exécution, 122 politiques de sécurité, déclencheurs, vues, énumérations, droits par colonne, 11 tâches planifiées, 15 tables en direct, 7 coffres de fichiers | ✅ **3 016 objets sur 3 016 identiques** |
| Les réglages posés par les fichiers (`event_rules`, `map_rules`, `feed_rules`, `crossing_windows`, `signup_rules`) | ✅ identiques |
| L'audit de sécurité `tool/audit_securite.sql` | ✅ 22/22 |
| L'app : où est écrite l'adresse du serveur ? | ✅ **un seul endroit** : `lib/core/config/env.dart` (fichier local, non versionné) ; le natif la reçoit du Dart (`PublishBridge.configure`), il n'a rien en dur |
| L'app utilise-t-elle des services que seul l'hébergement Supabase fournit ? | ✅ non : pas de fonctions hébergées (Edge Functions), pas de retouche d'images par le serveur ; elle utilise les tables, les fonctions SQL, le stockage (dont l'envoi par morceaux reprenables), la connexion des comptes et le temps réel (changements, diffusion, présence) — tous présents dans la version libre de Supabase |

## Ce que la répétition a trouvé — et réparé

1. **Le type de conversation « événement » n'était dans aucun fichier.**
   Ajouté à la main en base de dev ; sur un serveur neuf, la reconstruction
   s'arrêtait au fichier 75 sur 113. → `20260912095900_le_type_de_conversation_evenement.sql`.
2. **La table des diagnostics (`dev_reports`) n'était dans aucun fichier.**
   Sur un serveur neuf, « Envoyer un diagnostic » aurait échoué. →
   `20260926140000_la_table_des_diagnostics.sql` (outil de développement, à
   supprimer avant la prod).
3. **4 fonctions différaient par leurs commentaires** (même code). Alignées
   sur le dépôt, pour qu'un vrai écart futur ne se cache pas dans ce bruit.
4. **Les fins de ligne Windows** de la copie de travail entraient dans le
   texte des fonctions. → `.gitattributes` : les `.sql` et `.sh` restent en
   fins de ligne Linux.
5. **Deux cas de l'audit de sécurité ne testaient rien** (17 et 19) : le
   compte d'essai était suspendu, et la garde de suspension répondait avant
   celle de l'organisateur. Rejoués par un compte non suspendu : ils
   vérifient maintenant la bonne règle.

Les deux fichiers ajoutés sont sans effet sur la base de dev, qui avait déjà
ces éléments (ils ont été rejoués dessus pour le prouver).

## La décision (RAPPELS #124 ①) — ✅ TRANCHÉE le 2026-09-26 : chemin B

> Jay : *« on va écrire notre propre programme serveur. Le but c'est le
> contrôle, la scalabilité et la polyvalence. Totale. »*

Toute la logique du serveur est **écrite en SQL dans Postgres** : 215
fonctions, 122 politiques de sécurité, 11 tâches planifiées. L'app parle
directement aux services de Supabase (**257 appels dans 46 fichiers Dart**,
motif compté : `.from('` · `.rpc(` · `.storage.` · `.auth.` · `.channel(`).
Deux chemins :

| | **A. Installer Supabase (version libre) sur notre VPS** | **B. Écrire notre propre programme serveur** |
|---|---|---|
| ce que c'est | les mêmes logiciels, sur NOTRE machine, sous notre contrôle | un programme maison entre l'app et la base |
| la logique existante | reprise telle quelle (prouvé ci-dessus) | à réécrire : 215 fonctions + 122 règles |
| l'app | on change l'adresse, c'est tout | les 257 appels sont à réécrire |
| durée | quelques jours d'installation et de réglage | plusieurs semaines, avec le risque de rouvrir des failles déjà fermées |
| contrôle | total : la machine, les données, les sauvegardes sont à nous | total aussi |

Les deux donnent un « contrôle total ». Ce qui manque pour la « vraie couche
serveur » (notifications, suppression des fichiers par le serveur, serveur
média, plateformes) **s'ajoute à côté** dans les deux cas : ce sont des
services en plus, pas un remplacement de ce qui existe.

## Ce qu'il faudra régler sur le VPS (chemin A)

Ces réglages ne sont **pas dans la base** : ils vivent dans la configuration
de l'hébergement Supabase, relevée le 2026-09-26.

- **Connexion des comptes** : confirmation du mail coupée
  (`mailer_autoconfirm`) ; **crochet avant création de compte** branché sur
  `public.hook_before_user_created` (le plafond de comptes par téléphone —
  ⚠️ vérifier que la version installée du service le prend en charge) ;
  jeton valable 1 h, renouvellement tournant ; mot de passe de 6 caractères
  minimum ; limites de fréquence.
- **Stockage** : 50 Mo par fichier (limite actuelle, que l'app respecte déjà),
  envoi par morceaux reprenables (utilisé par la file de publication native).
- **Base** : Postgres 17 ; extensions `pg_cron`, `pgcrypto`, `uuid-ossp` ;
  `pgsodium` n'est exigée que par un vieux fichier (`20260713190000`), plus
  aucune fonction ne s'en sert — à neutraliser si l'extension manque.
- **Le temps réel** : les 15 tables sont déclarées par les fichiers.

## L'app

- Changer de serveur = changer l'adresse et la clé publique dans
  `env.dart`, **puis publier une nouvelle version de l'app** : une app déjà
  installée garde l'ancienne adresse.
- ✅ **Recommandation** : un **nom de domaine à nous** dès le premier jour
  (par ex. `api.<domaine>`), pour qu'un changement de machine plus tard ne
  demande plus de nouvelle version de l'app.
- Au changement, chaque utilisateur devra **se reconnecter une fois** (les
  jetons de connexion sont signés par l'ancien serveur).

## Les données de dev : les reprendre ou repartir de zéro ?

À trancher par Jay le moment venu. Volume relevé : 49 comptes, base de
54 Mo, **environ 655 Mo de fichiers** dans 7 coffres. Les reprendre se fait
(copie de la base + copie des fichiers, dans cet ordre, avec les clés des
médias qui voyagent avec la base) ; pour une ouverture publique, **repartir
de zéro** est le plus propre.

## Ce qui change dans ma façon de travailler

Aujourd'hui, j'accède à la base par l'API de gestion de Supabase (le PAT).
**Elle n'existera pas sur le VPS** : il faudra un accès direct à la base
(par une connexion sécurisée). `tool/repetition_vps/repeter.py` et l'audit
de sécurité devront pointer vers le nouveau serveur.

## Ce que le VPS doit prévoir (RAPPELS #11)

Sauvegardes **et tests de restauration**, certificat (https), mises à jour
de sécurité, surveillance. Ordre de grandeur pour le chemin A — ⚠️ à
confirmer au moment du choix : Supabase complet en auto-hébergement tourne
confortablement à partir de **4 Go de mémoire et 2 processeurs** ; 8 Go
laissent la place au serveur média et aux notifications. Le disque se
dimensionne sur les fichiers (655 Mo aujourd'hui, en croissance).
