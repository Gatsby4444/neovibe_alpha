# RSUNA — Reprise SUr un Nouvel Appareil

Document de bascule de machine pour le projet **NeoVibe**.
Deux parties : la **partie 1 est pour Jay** (ce qu'il fait à la main), la
**partie 2 est pour Claude Code** (ce qu'il vérifie et reconstruit tout seul
à la première session sur la nouvelle machine).

Dernière mise à jour : **2026-08-20**, état du projet : **v0.9.121**
(la proximité vient d'être refondue de fond en comble : secret par paire,
émission autonome du natif, réciprocité serveur — **et rien n'a encore tourné
sur un téléphone**. Voir §2.3 et §2.4).

---

## Deux façons de transférer — choisis-en une

Tout le code est sur GitHub (`https://github.com/Gatsby4444/neovibe_alpha`,
privé) et **tout est poussé** : dépôt local et distant sont au même point, tags
compris. Un clone suffit donc pour le code. Mais **trois fichiers ne sont
volontairement pas dans le dépôt**, et la mémoire de Claude Code vit en dehors.

### Option A — le ZIP (recommandé si la nouvelle machine est vierge)

Un zip du dossier projet **privé de ses dossiers régénérables**. Il embarque
`.git` (donc tout l'historique et le lien vers GitHub) **et** les fichiers
hors-dépôt : rien à reconstruire, pas besoin d'installer `git` ni de
s'authentifier sur GitHub pour démarrer.

**4 Mo compressé** (dont 3 Mo pour `.git` seul). À comparer aux 1,6 Go du
dossier brut, dont 1,47 Go de `build/` — régénérable, inutile, à ne surtout pas
transférer.

Dossiers exclus du zip (tous régénérés au premier build) :
`build/` · `.dart_tool/` · `android/.gradle/` · `android/app/.cxx/` ·
`.code-review-graph/`

### Option B — le clone

`gh repo clone Gatsby4444/neovibe_alpha`, puis recréer à la main les trois
fichiers hors-dépôt du tableau ci-dessous. Nécessite Git + GitHub CLI installés
et authentifiés avant de pouvoir commencer.

| Fichier hors-dépôt | Pourquoi | Si tu prends l'option B |
|---|---|---|
| `lib/core/config/env.dart` | Contient la clé Supabase → jamais committé (règle de sécurité du projet) | Le recréer depuis `lib/core/config/env.example.dart` — voir §1.4 |
| `.claude/settings.local.json` | Réglages locaux de Claude Code, non suivis par git | Sans lui, Claude redemande l'autorisation à chaque `flutter build` et les MCP sont à réactiver |
| `android/local.properties` | Chemin du SDK, propre à la machine | Régénéré tout seul par Flutter |

**Dans les deux cas**, la **mémoire de Claude Code** est à copier à la main :
elle vit hors du dossier projet (voir §1.5).

---

# PARTIE 1 — Pour Jay (à faire à la main sur la nouvelle machine)

### 1.0 Ce qu'il y a sur la clé USB

| Sur la clé | À remettre où, sur la nouvelle machine |
|---|---|
| `neovibe_alpha.zip` | Décompresser dans `C:\Charles\` → doit donner `C:\Charles\neovibe_alpha` |
| `memory\` (**41 fichiers** au 2026-08-20 : 40 mémoires + `MEMORY.md`) | `C:\Users\<TON_PROFIL>\.claude\projects\C--Charles-neovibe-alpha\memory\` |
| *(optionnel)* `dev\` | `C:\Charles\dev\` — évite de retélécharger 6,4 Go de toolchain |

> ⚠️ **Le chemin `C:\Charles\neovibe_alpha` n'est pas cosmétique.** Claude Code
> range sa mémoire dans un dossier nommé d'après le chemin du projet
> (`C--Charles-neovibe-alpha`). Un autre chemin = mémoire repartie de zéro.

> ⚠️ Le dossier `memory\` contient les **identifiants du compte de test** de la
> base de dev. C'est le seul endroit où ils sont écrits — ils ne sont **pas**
> dans le dépôt, exprès. Passe par la clé USB, **pas** par un service de
> transfert en ligne.

> ⚠️ **Deux fichiers de secrets vivent dans `docdev/`**, qui est **gitignoré**
> depuis le 2026-08-12 : `docdev/supabase-secrets.txt` (clé `service_role`) et
> `docdev/bot-credentials.txt` (mots de passe des bots de test). **Le zip les
> emporte** (il ne suit pas `.gitignore`), un clone **non**. C'est voulu :
> ces secrets ne doivent jamais entrer dans le dépôt. Leçon du 2026-08-12 — un
> secret qui n'existe que dans le contexte d'une session est un secret perdu.
> `docdev/seed-media/` contient aussi trois vidéos libres de droits pour le
> seed ; inutile de les transférer, elles se retéléchargent.

### 1.1 Installer les outils de base

- **Claude Code** : https://claude.com/claude-code (se connecter avec le compte
  habituel — `upliftwebcontact@gmail.com`)
- **Git** : https://git-scm.com/download/win — indispensable pour committer et
  pousser (le zip apporte l'historique, pas le logiciel).
- **GitHub CLI** (`gh`) : https://cli.github.com — sert à publier les APK en
  release. Une fois installé : `gh auth login` (compte `Gatsby4444`).

### 1.2 La toolchain (Flutter, JDK, Android SDK)

Tout est installé dans `C:\Charles\dev\`, **hors du PATH système** — garde
exactement cette organisation, tous les scripts et la mémoire de Claude s'y
réfèrent :

| Outil | Version exacte (vérifiée le 2026-07-26) | Chemin attendu | Taille |
|---|---|---|---|
| Flutter | 3.44.6 stable (Dart 3.12.2) | `C:\Charles\dev\flutter` | 3,0 Go |
| JDK Temurin | 17.0.19 | `C:\Charles\dev\jdk17` | 0,3 Go |
| Android SDK | platforms 34/35/36, build-tools 35.0.0 + 36.0.0 | `C:\Charles\dev\android-sdk` | 3,1 Go |

**Deux façons, au choix :**

- **Copier `C:\Charles\dev\` depuis l'ancienne machine** (6,4 Go) : les trois
  outils sont relocatables, ça marche tel quel et ça garantit des versions
  identiques. C'est le plus sûr si la clé est assez grande.
- **Réinstaller** : Flutter (https://docs.flutter.dev/get-started/install/windows,
  dézipper dans `C:\Charles\dev\flutter`) · JDK 17
  (https://adoptium.net/temurin/releases/?version=17) · Android SDK via Android
  Studio, en pointant le SDK sur `C:\Charles\dev\android-sdk`.

*Optionnel* : le cache des paquets Dart
(`C:\Users\<PROFIL>\AppData\Local\Pub\Cache`, 643 Mo) peut être copié lui aussi
pour éviter un long `pub get` au premier build. Sans lui, ça marche quand même,
c'est juste plus lent une fois.

> ⚠️ **Piège connu** (déjà rencontré) : sans `JAVA_HOME` posé explicitement,
> Gradle échoue immédiatement. Claude le pose lui-même dans ses commandes, mais
> si tu compiles à la main :
> ```powershell
> $env:JAVA_HOME="C:\Charles\dev\jdk17"
> $env:ANDROID_HOME="C:\Charles\dev\android-sdk"
> $env:Path="C:\Charles\dev\flutter\bin;C:\Charles\dev\jdk17\bin;$env:Path"
> ```

### 1.3 Récupérer le projet

**Option A (zip)** : décompresser dans `C:\Charles\`. Vérifier qu'on obtient
bien `C:\Charles\neovibe_alpha\pubspec.yaml` (et non un dossier imbriqué en
double). Puis, une fois `git` installé :

```powershell
cd C:\Charles\neovibe_alpha
git fetch --tags       # recupere les tags v0.9.33 / v0.9.34 crees par gh
git status             # doit etre propre, sur master
```

**Option B (clone)** :

```powershell
mkdir C:\Charles
cd C:\Charles
gh repo clone Gatsby4444/neovibe_alpha
```

### 1.4 `lib/core/config/env.dart` (obligatoire, sinon l'app ne compile pas)

Déjà présent si tu as pris le zip. Sinon, deux façons :

- Le copier depuis l'ancienne machine — c'est un fichier de 6 lignes.
- Le recréer depuis le modèle `lib/core/config/env.example.dart`, avec l'URL du
  projet Supabase de dev (`https://dvixmhvqqjvbrpsckmyi.supabase.co`) et la
  **clé publishable**, à récupérer sur https://supabase.com/dashboard (projet
  `neovibe_alpha`, ref `dvixmhvqqjvbrpsckmyi`) → *Project Settings → API Keys*.
  Claude Code sait aussi la récupérer via le MCP Supabase
  (`get_publishable_keys`) une fois celui-ci connecté.

### 1.5 Rapatrier la mémoire de Claude Code

C'est le **seul élément que ni le zip ni le clone n'apportent** : elle vit dans
ton profil utilisateur, pas dans le projet.

Sur **l'ancienne** machine, copier tout le dossier :

```
C:\Users\Utilisateur\.claude\projects\C--Charles-neovibe-alpha\memory\
```

Sur la **nouvelle**, le coller au même endroit — le nom d'utilisateur Windows
peut changer, l'important est
`<TON_PROFIL>\.claude\projects\C--Charles-neovibe-alpha\memory\`.

> Si tu ne le fais pas : rien de bloquant, Claude reconstruira le contexte
> depuis `CLAUDE.md`, `RAPPELS.md`, `docs/` et les rapports de session — mais il
> faudra recréer un compte de test, dont le mot de passe n'existe nulle part
> ailleurs.

### 1.6 Serveurs MCP

Le fichier `.mcp.json` est **dans le dépôt** (aucun secret dedans) : Claude Code
proposera d'activer les serveurs à la première session.

- **Supabase** (`https://mcp.supabase.com/mcp`) : une authentification dans le
  navigateur sera demandée. ⚠️ **Toujours scopé au projet de DEV**
  (`dvixmhvqqjvbrpsckmyi`) — jamais de manipulation de données de production.
- **code-review-graph** : optionnel. S'il n'est pas installé sur la nouvelle
  machine, l'ignorer : rien du projet n'en dépend.

### 1.7 Vérifier que tout marche

Ouvre Claude Code dans `C:\Charles\neovibe_alpha` et dis-lui simplement :

> « Reprends le contexte, on change de machine — lis RSUNA.md et fais la
> vérification de reprise. »

Il exécutera la checklist de la partie 2 et te dira ce qui manque.

---

# PARTIE 2 — Pour Claude Code (à exécuter à la première session sur la nouvelle machine)

Tu reprends un projet en cours. **Ne recommence rien, ne réorganise rien.**

### 2.1 Reconstituer le contexte (dans cet ordre)

1. `CLAUDE.md` — thèse produit, décisions verrouillées, règles de travail.
   **Les règles impératives (rapport de session, `RAPPELS.md`,
   `docs/parties-natives-par-os.md`) s'appliquent dès la première session sur la
   nouvelle machine.**
2. `docs/vision-produit.md` — mécaniques fondatrices et ce qui reste à
   construire.
3. `RAPPELS.md` — avant-prod, chantiers promis, décisions en attente, bugs
   connus, décisions à ne pas reproposer.
4. Les **2 ou 3 derniers rapports** de `rapports-de-sessions/`. Le plus récent :
   **`2026-08-19_23-56.md`** — c'est le plus important, et de loin : il décrit
   **toute la refonte de la proximité** du 2026-08-20 (secret par paire,
   émission autonome du natif, réciprocité serveur, reconnaissance native,
   `minSdk` à 31), avec pour chaque décision le **motif** et ce qui a été
   vérifié. Puis `2026-08-18_08-28.md` (l'audit qui a tout déclenché) et
   `2026-08-18_04-16.md` (la refonte du ping, une session par pair).
5. **`docs/logigrams/`** — huit schémas à ouvrir dans Logigram. Le **7** montre
   la reconnaissance telle qu'elle était et **pourquoi elle a changé**, le **8**
   celle en place. À lire dans cet ordre avant de toucher à la proximité.
6. **`docs/cours-livraison-des-medias.html`** — le cours écrit pour Jay le
   2026-08-13 : stockage objet, HTTP, URL signée, clé, format par blocs, qui
   compte quoi, et les options de préchargement. **À lire avant de toucher au
   chemin des médias.**
7. `git log --oneline -15` pour l'état réel du code.

### 2.2 Vérifications d'environnement (à faire, pas à supposer)

```bash
# Toolchain (chemins hors PATH — les prefixer systematiquement)
ls C:/Charles/dev/flutter/bin/flutter.bat
ls C:/Charles/dev/jdk17
ls C:/Charles/dev/android-sdk

# Le fichier de config local existe-t-il ? (gitignore, absent d'un clone frais)
ls lib/core/config/env.dart

# L'analyse est-elle propre ?
"C:/Charles/dev/flutter/bin/flutter.bat" analyze

# Compilation (JAVA_HOME est OBLIGATOIRE, sinon Gradle echoue immediatement)
JAVA_HOME="C:/Charles/dev/jdk17" "C:/Charles/dev/flutter/bin/flutter.bat" build apk --release
```

- **Si `lib/core/config/env.dart` manque** : ne pas inventer de clé. Le recréer
  depuis `env.example.dart` en récupérant la clé publishable via le MCP Supabase
  (`get_publishable_keys`, projet `dvixmhvqqjvbrpsckmyi`), ou demander à Jay.
  **Ne jamais committer ce fichier.**
- **Si `android/gradlew` ou le wrapper Gradle manque** après un clone frais :
  c'est normal (ignoré par le `.gitignore` de Flutter), l'outil Flutter le
  régénère tout seul au premier build.
- **Si les tags s'arrêtent à une version antérieure au `pubspec.yaml`** : normal
  aussi. `gh release create` crée le tag **directement sur GitHub** ; il n'entre
  en local qu'au `git fetch --tags`.
- **Si la mémoire (`~/.claude/…/memory/`) est vide** : la reconstruire à partir
  de `CLAUDE.md`, `docs/`, `RAPPELS.md` et des rapports de session. Le compte de
  test de la base de dev n'y sera plus : le signaler à Jay plutôt que d'en créer
  un sans lui demander.

### 2.3 État du projet à la bascule (2026-08-20, v0.9.121)

- **`pubspec.yaml` en `0.9.121+211`**, dernière release **v0.9.121**, working
  tree propre, `master` aligné sur `origin/master`.

#### ⚠️ Ce qu'il faut savoir AVANT toute chose

**La proximité a été refondue le 2026-08-20, et RIEN n'a tourné sur un
téléphone.** Tout est vérifié en test (188 Dart + 11 Kotlin), en base, ou à la
compilation — jamais sur appareil. Cinq mesures attendent, listées en §2.4.

**Le protocole d'annonce est passé en version 3.** Les deux téléphones de test
doivent être mis à jour **ensemble**, sinon ils ne se voient pas — c'est voulu,
et c'est visible au diagnostic (`otherVersionScans`).

**Trois changements structurants**, chacun détaillé dans `RAPPELS.md` :

| Quoi | Où |
|---|---|
| Le **secret par paire** (X25519) remplace la clé de diffusion partagée | #51, #53 |
| Le natif **émet et reconnaît seul** (plan de 12 h + table de reconnaissance) | #53, #56 |
| Un croisement n'existe que si **les deux** se sont vus (réciprocité serveur) | #55 |

**Deux migrations appliquées sur le projet de dev le 2026-08-20**, toutes deux
dans le dépôt — **ne pas les rejouer** : `20260820120000_pairwise_secret` et
`20260820180000_mutual_sightings`. Un job cron s'ajoute :
`neovibe_purge_sightings` (jobid 10).

**`minSdk` est passé à 31** (Android 12). Ce n'est pas une contrainte de
compilation, c'est une décision — lire `RAPPELS.md` #57 avant d'y toucher.

**Une règle impérative s'ajoute à `CLAUDE.md`** : dissocier l'ACQUISITION de
l'USAGE. Jay a demandé un **checkup complet du code** à son aune (#52).
- **⚠️ Quatorze versions publiées les 2026-08-13/14** (v0.9.58 → v0.9.71).
  Toutes ont un APK sur GitHub et des notes de test détaillées. **Lire les notes
  de release** est le moyen le plus rapide de comprendre l'enchaînement.
- **Deux migrations appliquées** :
  `20260813162722_content_view_recorded_on_display` et
  `20260813215500_story_purge_deletes_the_content_not_the_story`. Toutes deux
  **dans le dépôt** et **déjà appliquées** — ne pas les rejouer.
- **⚠️ LA BASE A ÉTÉ REMISE À ZÉRO le 2026-08-13** (consigne de Jay : « on
  repart de 0 pour tout »). Tout le contenu a été supprimé et regénéré par le
  seed ; les **coffres ont été vidés** (293 objets). **Comptes, profils,
  amitiés, conversations et bots ont été PRÉSERVÉS.** Contenu actuel : 20
  stories (anneaux de 4), 15 publications, 21 Vibes en DM, 6 avatars.
- **🎨 LA REFONTE UI EST LE CHANTIER SUIVANT**, et **Rive est adopté**
  (abonnement Cadet pris par Jay). Rien n'est commencé : ses vues sont attendues
  dans `docs/`, et le MCP Rive reste à brancher. Tout ce qu'il faut savoir avant
  d'y toucher est en `RAPPELS.md` #25, #26 et #27 — **les lire en entier**, en
  particulier « sans le `.rev`, une animation est figée pour toujours ».

#### Le socle de contenu (refonte du 2026-08-11, terminée)

« **1 contenu = 1 format** » : une story, une publication et une Vibe en DM sont
des objets **distincts**, chacun avec son contexte de diffusion. Le repartage
est un **chemin** vers la source, jamais une copie. Tables `contents`,
`content_grants`, `content_views`. Détail : `docs/controle-de-la-distribution.md`
et la mémoire `project-neovibe-content-spine`.

#### La livraison des médias (chantier du 2026-08-12 → 2026-08-13)

C'est **le** sujet en cours. Dans l'ordre où les pièces ont été posées :

| Pièce | Version | État |
|---|---|---|
| Chiffrement par blocs (format `NVC1`) | v0.9.54 | livré |
| **Lecture native directe** (ExoPlayer + `SealedDataSource`, Kotlin) | v0.9.57 | livré, validé |
| Index MP4 en tête (`Mp4FastStart`) | v0.9.57 | livré |
| Lecture par intervalles + cache partiel | v0.9.57 | livré, validé |
| Instrument de mesure (4 états, détail par étape) | v0.9.58→67 | livré |
| Réglages en dossiers + « Tout copier » | v0.9.60 | livré, validé |
| Inspecteur de règles des Vibes | v0.9.63 | livré, validé |
| **Préchargement** (URL + clé + 1er bloc) | v0.9.64→67 | livré, **mesure attendue** |

**Chiffres de référence** (Xiaomi M2101K6G, Android 13, relevés par Jay) :

- cache complet : **médiane 290 ms** pour une cible de 300 → **tenue**
- à froid : **~850 ms** pour une cible de 1 s → tenue
- décomposition restante : `· décodage entête` **~149 ms** (le poste dominant),
  `· attente avant natif` ~50 ms (interface), le reste négligeable

⚠️ **Ne jamais citer un chiffre de mesure sans dire de quel seau il vient.**
Trois fois dans la journée du 2026-08-13, un instrument conçu avant le mécanisme
qu'il jugeait a produit un chiffre juste répondant à la mauvaise question. Voir
la mémoire `feedback-read-the-measurement-not-the-instrument`.

#### Ce qui est verrouillé sur la livraison, et pourquoi

- **Les Vibes en DM ne sont PAS préchargées** (décision de Jay, 2026-08-13).
  `open_card_media` vérifie, décompte et rend la clé dans **une seule
  transaction** : précharger la clé **brûlerait une vue**. C'est ce qui fait de
  la limite de vues une garantie et non une convention (décision du 2026-08-10).
  Garanti **par construction** : `ContentPreloader` ne manipule que des
  `ContentFace`, le type du socle, par lequel une Vibe en DM ne passe pas.
- **Les vues du socle sont enregistrées à l'affichage**, après **3 s**
  (`record_content_view`), et non plus à la remise de la clé. Contrepartie
  assumée : l'enregistrement dépend du client — acceptable car un contenu du
  socle n'a **aucun budget de vues**.
- **Le chantier « préparer un lecteur d'avance » n'est PAS mort** : il a été
  déclaré mort à tort le 2026-08-13 sur la foi de `· construction lecteur`
  (2-6 ms), qui ne mesure que la construction de l'objet. Le vrai coût est
  `· décodage entête` (~149 ms) et **il se prépare d'avance**. C'est l'option 3,
  la dernière à faire.
- **Le volet caméra est CLOS** depuis le 2026-07-25 (Jay : « c'est fonctionnel
  et globalement propre »). **Ne pas le rouvrir de sa propre initiative.** Le
  chantier GPU/OpenGL est terminé et validé (v0.9.23) : double aperçu 2×30 i/s,
  photo double instantanée, vidéo double + audio partagé, repli séquentiel sur
  appareils incapables. Bilan dans
  `rapports-de-sessions/REPRISE-chantier-gpu-camera.md`.
- **Navigation à 5 onglets** depuis la v0.9.36 : **Ping | Cercle | (Card) |
  Jeux | Profil**, avec onglet de démarrage réglable. L'onglet **Jeux est un
  placeholder** assumé (« Bientôt ici »), qui réserve la place du chantier
  quiz/mini-jeux — **il ne peut pas partir en prod tel quel** (RAPPELS,
  avant-prod #15).
- **Les Réglages sont en dossiers depuis la v0.9.60** : six catégories, chacune
  sur son écran (`lib/features/settings/sections/`), plus un dossier
  **Développeur** avec trois sous-dossiers. ⚠️ **Conséquence pour la prod** : le
  retrait de la section dev est devenu **une opération unique et vérifiable** —
  supprimer le dossier et sa tuile dans `settings_screen.dart`. La liste exacte
  de ce qui part avec est dans `RAPPELS.md` (avant-prod #4).
- **Outils de diagnostic (dev)** : Développeur → **« Tout copier pour
  diagnostic »** rassemble appareil + version + mesures vidéo + règles des Vibes
  + journal caméra + journal de l'app en un seul bloc. **C'est ce qu'il faut
  demander à Jay** plutôt que des relevés écran par écran.
- **Stories livrées et validées** (v0.9.38 → v0.9.41), puis reversées dans le
  socle unifié le 2026-08-11 : une story est désormais un **contenu autonome**,
  plus « une Card publiée en story ». 24 h consultable sans limite, bandeau en
  haut du Cercle (amis) et du Ping (croisés de moins de 24 h si l'auteur a
  activé « stories publiques »).
- ⚠️ **Chantier ouvert le 2026-08-02, toujours en attente des arbitrages de
  Jay : les stories en deck.** Il juge le format Card (recto/verso) inadapté aux
  stories et veut un dérivé sans retournement, en deck/éventail. **Trois
  questions sans réponse — ne rien coder avant** : voir §2.4 et `RAPPELS.md`
  (Décisions en attente #6).
- **Blocage livré** (v0.9.53) : coupe la visibilité des contenus du socle, les
  relais dans les deux sens et les partages contournants. ⚠️ **Ne coupe PAS**
  encore la connexion, les conversations, les Vibes en DM, le profil ni les
  croisements BLE — **arbitrage de Jay attendu** (`RAPPELS.md`, décisions en
  attente #9).
- **Cinq bots de test** en base de dev (`Lea`, `Malik`, `Chloe` amis ; `Yanis`,
  `Sofia` croisés), un par branche de la règle d'accès aux stories. **À
  supprimer avant la prod** (RAPPELS, avant-prod #14). ⚠️ **Leurs mots de passe
  ne sont PAS dans la mémoire de Claude** — corrigé le 2026-08-12 : ils vivent
  dans `docdev/bot-credentials.txt`, gitignoré, emporté par le zip mais pas par
  un clone. En cas de perte, le seul chemin est la réinitialisation par SQL
  (voir RAPPELS avant-prod #14).
- **Seed de contenu** : `tool/seed_bot_media.dart` — 26 Vibes (8 avec face
  vidéo), 12 stories, 10 publications, tout scellé et téléversé **sous
  l'identité de chaque bot**, donc à travers les vraies règles d'accès.
  ⚠️ Les vidéos seedées n'ont pas leur index en tête (`fastStart` est natif,
  inaccessible depuis un outil Dart pur) : elles sont **légèrement pessimistes**
  dans les mesures face à une vidéo filmée dans l'app.
- **Deux chantiers produit toujours ouverts** : **quiz / mini-jeux entre amis**
  puis **feed local** (ville / région / pays + comptes créateurs internationaux
  — à ne pas confondre avec le feed algorithmique global, lui hors scope).
  Périmètre dans `docs/vision-produit.md`. Conseil déjà donné et non tranché :
  faire la **couche d'abstraction des accès aux données** avant eux (85 appels
  Supabase directs dans 31 fichiers ; RAPPELS, avant-prod #12).
- **À ne JAMAIS refaire** (chaque point a coûté une version — détail dans le
  rapport du 2026-07-14 pour la caméra, du 2026-07-26 pour les outils) :
  - appeler une API Flutter (TextureRegistry, MethodChannel) hors du thread
    principal ;
  - répondre deux fois à un `MethodChannel.Result` ;
  - demander 2 flux par caméra en double flux (la frontale est affamée) ;
  - reconfigurer une session caméra pendant que l'autre caméra tourne ;
  - **sonder des configurations caméra au moment de l'usage** : un essai raté
    tue le service caméra d'Android jusqu'au redémarrage de l'app ;
  - juger du matériel sur un **délai en dur** : attendre le FAIT, pas le
    chronomètre ;
  - faire du travail lourd (rendu, conversion) **sur le thread caméra** ;
  - **utiliser `ref` (Riverpod) dans un `dispose()`** — ⚠️ **commis DEUX fois**,
    la seconde le 2026-08-13 (v0.9.64), alors que l'avertissement était écrit en
    toutes lettres dans `card_viewer_screen.dart`. 19 erreurs dans le journal de
    Jay, une par fermeture d'écran. **Capturer les dépendances dans un
    `late final` posé en `initState`.** Vérifier **par inventaire** après coup :
    `for f in $(grep -rl "void dispose()" lib/); do awk '/void dispose\(\)/,/^  \}/' "$f" | grep -q "ref\." && echo "$f"; done` ;
  - **poser un état juste avant d'appeler une méthode qui le réinitialise** — le
    passer en argument (bug du verrou vidéo du retardateur) ;
  - **bumper la version après le build** : la poser avant, sinon l'APK est à
    refaire ;
  - **lire une fonction SQL ou un cron dans un FICHIER de migration** et croire
    que c'est l'état de la base : les migrations successives se redéfinissent
    entre elles. Faute commise **deux fois** (2026-08-01 et 2026-08-02, cette
    dernière ayant produit une affirmation fausse à Jay sur la confidentialité
    des comptes croisés). **Relever la définition réelle** :
    `pg_get_functiondef(...)`, `select command from cron.job`,
    `information_schema.columns`. Et `cron.schedule` **remplace** un job de même
    nom : tout ce qui n'est pas recopié est perdu silencieusement ;
  - **placer un `ref.watch` après un `await`** dans un `FutureProvider` : la
    dépendance n'est pas enregistrée de façon fiable. Avec une source dérivée
    d'un stream (valeur vide au premier passage), le résultat est
    **silencieusement faux** et ne se recalcule jamais. Lire toutes les
    dépendances **avant la première suspension** (cause du « aucune story nulle
    part », v0.9.40) ;
  - **traduire un état d'erreur par un widget vide** (`SizedBox.shrink()`) :
    une panne devient indiscernable d'une absence de données. Les trois états —
    chargement, erreur, vide — doivent se distinguer à l'œil ;
  - **poser un `Stack` en `Scaffold.body` avec un seul enfant non positionné** :
    un `Stack` se dimensionne sur ses enfants NON positionnés et le `body` d'un
    `Scaffold` donne des contraintes **lâches**. Les `Positioned.fill` sont
    alors écrasés à la hauteur du petit enfant, puis rognés (`Clip.hardEdge` par
    défaut). Soit **tous** les enfants sont `Positioned`, soit l'enfant non
    positionné est celui qui doit imposer la taille (cause du « rien n'apparaît »
    de la visionneuse de stories, v0.9.40) ;
  - **insérer à la main dans `auth.users` sans forcer les colonnes texte à `''`**
    (`confirmation_token`, `recovery_token`, `email_change`,
    `email_change_token_new`) : GoTrue les lit en `string` et renvoie un
    `Database error querying schema` (HTTP 500) à la connexion, sans rapport
    apparent avec la cause.
  - **CONCEVOIR UN INSTRUMENT AVANT LE MÉCANISME QU'IL DOIT JUGER** — la faute
    la plus coûteuse du 2026-08-13, **commise trois fois dans la même journée** :
    (a) un seau « en cache » rempli par « le fichier existe », alors que le cache
    par blocs crée le fichier à sa taille définitive dès le premier bloc ;
    (b) un chronomètre qui comptait le **temps de réflexion de l'utilisateur**
    sur les faces préchargées (11 s attribuées à l'app) ; (c) un seau « partiel »
    sans cible, où serait tombé tout le résultat du préchargement. **Après tout
    changement d'architecture, rejouer la mesure comme on rejoue les décisions**
    (règle 6 de `CLAUDE.md`) ;
  - **conclure d'un chiffre sans demander ce que sa population peut contenir** —
    « le préchargement est inutile », conclu à partir du seul seau qui, par
    construction, ne contenait que du contenu **déjà téléchargé**. Biais de
    sélection, corrigé par Jay ;
  - **lire un zéro comme une mesure alors qu'il vient de la forme de
    l'instrument** — deux jalons rendus simultanés produisent mécaniquement un
    « 0 ms » qui ne mesure rien ;
- **Outils de diagnostic** : Réglages → **Développeur** →
  **« Tout copier pour diagnostic »** (appareil, version, mesures vidéo, règles
  des Vibes, journal caméra, journal de l'app — en un bloc). Sous-dossier
  **Journaux et mesures** pour le détail. S'en servir avant de deviner, et
  **demander le bloc entier à Jay** plutôt que des relevés partiels.

### 2.4 Ce qui attend (par priorité, à confirmer avec Jay)

0. **📱 UN BUILD À TESTER, et c'est le seul point bloquant.** Toute la refonte
   de la proximité (secret par paire, émission autonome, réciprocité serveur,
   reconnaissance native) est écrite, testée et compilée — **jamais exécutée sur
   un téléphone**. On empile depuis plusieurs sessions sans retour du terrain.

   ⚠️ **Les deux téléphones ensemble** : protocole en version 3.

   **Cinq mesures à relever au premier test à deux appareils.** Elles décident
   de valeurs aujourd'hui *raisonnées*, pas mesurées :

   | Quoi | Ce que ça décide |
   |---|---|
   | `rawScans` / `neoScans`, écran allumé **puis éteint** | les trois durées de `PresenceRules` (#47) |
   | un appareil laissé une heure app fermée, écran éteint | que le point H est bien corrigé (#49) |
   | période de renouvellement de l'adresse BLE | elle plafonne toute la vie privée du créneau |
   | coût d'un redémarrage d'advertising | la valeur de `cycleMillis` (400 ms) |
   | `advertCapabilities` sur l'appareil de Jay | s'il y a lieu d'écrire le multi-annonces (#54 ①) |

0. bis **🔬 LE CHECKUP DEMANDÉ PAR JAY** (`RAPPELS.md` #52) : passer tout le code
   à l'aune de la règle de dissociation acquisition / usage. Question de
   contrôle : *« si j'ajoute un champ à cet écran, dois-je toucher au code qui
   parle à la radio / au réseau / au disque ? »*. Résultat à rendre **chiffré**
   (reconstructions, lectures disque) — ce défaut n'affiche jamais rien de faux.

0. ter **🎨 LA REFONTE UI — toujours en attente de ses vues.** Jay fournit ses
   vues dans `docs/`. **Ne rien entreprendre avant.** Lire `RAPPELS.md` #27
   (dont le cadrage de Jay : l'authoring visuel lui revient, l'intégration et le
   **système de mouvement** me reviennent), #26 (tout sur Rive) et #25 (le piège
   de build).

   **Deux choses à faire en ouverture** : brancher le **MCP Rive** (Jay a
   l'abonnement Cadet et redémarre Claude Code pour ça), et lui **reproposer le
   système de mouvement** avant les écrans — proposition faite, non tranchée.

   ⚠️ **À lui rappeler avant toute commande à un designer** : **sans le `.rev`,
   une animation Rive est figée pour toujours.**

0. bis **🔔 Le relevé de mesures vidéo, toujours pas fait** (en attente depuis la
   v0.9.67, quatre versions). Ce qu'il faut : **Développeur → « Tout copier pour
   diagnostic »**, après avoir **vidé le cache** (Réglages → Vibes → Stockage)
   puis enchaîné plusieurs stories — l'enchaînement traverse désormais les
   auteurs, ce qui donne bien plus d'occasions au préchargement.

   Attendu : la première story dans « À froid » (~800 ms), **toutes les
   suivantes dans 🚀 Amorcé** autour de **200-300 ms**, `URL signée` et `clé`
   à ~0 ms. **Ne pas engager l'option 3 (lecteur préparé d'avance) sans ce
   relevé** — c'est l'erreur commise et corrigée le 2026-08-13.

0. ter **💡 Proposer l'APK par architecture.** `--split-per-abi` puis livrer
   `app-arm64-v8a-release.apk` (le Xiaomi M2101K6G est arm64) : **~22 Mo au lieu
   de 60,9** — et 29,3 Mo une fois Rive intégré. Mesuré le 2026-08-13, non
   encore proposé à Jay.

1. **L'option 3 — préparer un lecteur d'avance.** Le dernier morceau du chantier
   livraison, et le plus utile au feed : `· décodage entête` vaut **~149 ms** et
   c'est désormais le poste dominant. ⚠️ **À faire avec soin** : un ExoPlayer
   vivant retient un **décodeur matériel**, ressource limitée sur un téléphone.
   Le code porte déjà cet avertissement (`MainActivity.onDestroy`). Il faut un
   pool **strictement borné** avec libération garantie. `RAPPELS.md` #16 et #21.

2. **Élargir la couverture du préchargement.** Aujourd'hui il n'est câblé que
   sur « la story suivante d'un anneau ». Les publications ne sont pas
   préchargées du tout. Mesuré le 2026-08-13 : le mécanisme fonctionne
   (5 ms au lieu de 120 ms) mais ne couvre qu'une ouverture sur sept.
   ⚠️ **Toute nouvelle source de préchargement doit appeler
   `VideoOpenTrace.markPrefetched`**, sinon elle réintroduit un artefact de
   mesure (`RAPPELS.md` #17).

3. **Unifier les deux chemins de cache** (`card_media_cache.dart` à côté de
   `content_media_cache.dart`). Les Vibes en DM téléchargent encore **en
   entier**. ⚠️ **Ne PAS fusionner naïvement** : le transport (intervalles,
   cache partiel, lecteur natif) se mutualise, mais **la politique de clé doit
   rester distincte** — une Vibe en DM porte un budget de vues, pas un contenu
   du socle. Fusionner les deux ferait sauter la garantie sans que rien ne le
   signale. C'est la règle 2 de `CLAUDE.md` appliquée aux secrets.

4. **CHANTIER — les stories en deck.** Décidé par Jay le 2026-08-02 au
   vu du test de la v0.9.41 : « le format card tel qu'il est actuellement n'est
   pas adapté pour les stories ». Dérivé de la Card **sans recto/verso ni
   retournement**, présenté en **deck / éventail**. Spécification complète,
   analyse rendue et contre-propositions dans le rapport
   `rapports-de-sessions/2026-08-02_14-36.md` ; résumé dans `RAPPELS.md`
   (Décisions en attente #6).
   ⚠️ **BLOQUÉ sur trois questions posées à Jay et restées sans réponse — ne pas
   commencer à coder avant de les lui reposer** :
   - le **verso** des Cards existantes : deux cartes dans le deck, recto seul,
     ou choix de l'auteur ?
   - **deck ou éventail** (pile séquentielle, ou cartes étalées où l'on pioche) ?
     Défaut proposé : la pile avec 2-3 cartes qui dépassent.
   - le **like** : gardé, remplacé par la réaction en DM, ou les deux ?
   Deux réserves ont été signalées à Jay et lui appartiennent : le **like ne
   passe pas la grille de décision de `CLAUDE.md`**, et la carte de gestes
   proposée a un **conflit gauche/gauche** (swipe = passer vs clic = précédent).
5. **Les tests annoncés par Jay et jamais faits** : les **règles des cards et
   des Vibes**, et le **système de vues**. Annoncés le 2026-08-12, repoussés
   toute la journée du 2026-08-13 par le chantier mesure. L'outil est prêt
   depuis la v0.9.63 (**Développeur → Journaux et mesures → Règles des Vibes**)
   et le seed a été fabriqué pour ça. Premiers verdicts relevés le 2026-08-13 :
   **tous verts** (1 vue par ouverture), mais sur peu de cas et sans épuisement
   de budget.

6. **Arbitrages plus anciens, toujours ouverts** : la **portée du blocage**
   (`RAPPELS` décisions #9) ; la **durée de conservation du journal de
   propagation** (`RAPPELS` #7) ; l'**asymétrie du journal** — depuis le
   2026-08-13 il n'existe plus qu'un seul point d'enregistrement, mais Jay n'a
   pas tranché sur la conservation ; le libellé du 4e onglet ; faut-il que les
   **bots répondent** (déclencheur serveur, chantier à part) ?

7. **Suite de la réorganisation UI**, acceptée dans le principe et **en partie
   faite** le 2026-08-13 (les Réglages sont passés en dossiers). Restent :
   sortir « Enregistrements » et « Stockage des Vibes » vers le Profil, et
   remonter le ♥ (demandes / recos / waves) en badge sur l'onglet Profil.

8. **Contrôle d'accès des stories à confirmer À L'ŒIL** : *Yanis* doit
   apparaître dans le bandeau du Ping, *Sofia* **nulle part**. Vérifié en base,
   jamais constaté à l'écran.

9. **Streaks de proximité** — chantier promis, Jay a insisté pour ne pas
   l'oublier. ⚠️ `public.encounters` étant désormais purgé à 24 h, un streak ne
   peut **pas** se calculer en relisant cette table : il faudra un compteur
   persistant séparé (RAPPELS, chantiers #1).

10. **Quiz / mini-jeux** puis **feed local**. ⚠️ Conseil devenu **urgent**
    depuis que Jay a tranché pour un VPS en prod (2026-08-13) : faire la
    **couche d'abstraction des accès aux données** avant eux — 85 appels
    Supabase directs dans 31 fichiers, c'est le coût de sortie réel
    (`RAPPELS.md` avant-prod #11 et #12).

11. Le reste de `RAPPELS.md` (dont : réactiver FLAG_SECURE, **retirer le
    dossier Développeur** — devenu une opération unique, voir avant-prod #4 —,
    **supprimer les bots de test**, masquer ou livrer l'onglet Jeux — le tout
    avant la prod ; vidéo HD quand l'hébergement le permettra ; vignettes des
    « Enregistrements » à câbler sur le cache local).

### 2.5 Premier message à Jay

Résumer en quelques phrases : ce qui a été vérifié, ce qui manque le cas échéant
(`env.dart`, mémoire, `docdev/`, MCP, tags), l'état du projet — puis lui proposer
**un build à tester** (§2.4 point 0), qui est le seul point bloquant.

Y joindre trois choses, sans en faire un catalogue :
- lui rappeler que **les deux téléphones doivent être mis à jour ensemble**
  (protocole en version 3) et qu'aucune ligne de la refonte proximité n'a tourné
  sur un appareil ;
- lui redemander le **checkup dissociation acquisition / usage** qu'il a
  commandé (#52) — c'est lui qui l'a réclamé, pas moi qui le propose ;
- lui rappeler que le **relevé de mesures vidéo** n'a toujours pas été fait.

**Ne pas se lancer dans un chantier sans son feu vert.** Et ne pas engager
l'option 3 (lecteur préparé d'avance) avant d'avoir ses chiffres : c'est
exactement l'erreur commise et corrigée le 2026-08-13, où un chantier a été
ouvert puis abandonné sur une mesure mal lue.

---

# ANNEXE — Regénérer le paquet de transfert

À rejouer quand Jay redemande un transfert (dans un sens ou dans l'autre).
Produit `C:\charles\neovibe-transfert\` : zip du projet + dossier de mémoire.

```powershell
$src  = "C:\charles\neovibe_alpha"
$root = "C:\charles\neovibe-transfert"
$mem  = "C:\Users\Utilisateur\.claude\projects\C--Charles-neovibe-alpha\memory"

New-Item -ItemType Directory -Force "$root\_stage\neovibe_alpha" | Out-Null
$a = @($src, "$root\_stage\neovibe_alpha", "/E",
       "/XD", "build", ".dart_tool", ".gradle", ".code-review-graph", ".cxx",
       "/NFL", "/NDL", "/NJH", "/NJS", "/R:1", "/W:1")
& robocopy.exe @a | Out-Null      # code de sortie 1 = succes avec copie

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory(
    "$root\_stage", "$root\neovibe_alpha.zip",
    [IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item -LiteralPath "$root\_stage" -Recurse -Force

Copy-Item $mem "$root\memory" -Recurse -Force
```

**⚠️ Trois pièges, tous rencontrés le 2026-07-26 :**

1. **Ne PAS utiliser `Compress-Archive`** : il **ignore silencieusement les
   dossiers cachés**, donc `.git`. Le zip paraît correct (aucune erreur) mais
   arrive sans historique, sans branche et sans lien vers GitHub.
   `CreateFromDirectory` les inclut.
2. **Ne PAS utiliser `git archive`** : il n'embarque que les fichiers *suivis*,
   donc il perd `env.dart` et `.claude/settings.local.json` — précisément ce qui
   justifie le transfert manuel.
3. **Construire le zip en DERNIER**, après toute mise à jour de `RSUNA.md`, des
   rapports ou de `RAPPELS.md`.

**Vérifier le zip livré, pas le dossier de préparation** — décompresser ailleurs
et contrôler sur place :

```powershell
git -C <extrait>\neovibe_alpha status --branch   # doit suivre origin/master
git -C <extrait>\neovibe_alpha log --oneline -3
git -C <extrait>\neovibe_alpha fsck --connectivity-only
```

Repère de volume au **2026-08-13** : **3 072 entrées, 13,8 Mo** — dont **2 721
entrées pour `.git` seul**, et ~9 Mo pour `docdev/seed-media/` (trois vidéos
libres de droits, retéléchargeables mais sans intérêt à exclure).
*(Repère précédent, 2026-07-26 : 1 828 entrées, 4,0 Mo.)*

Si le compte tombe à quelques centaines d'entrées ou si le zip fait moins d'un
mégaoctet, **`.git` manque** — c'est exactement la signature du piège n°1.

⚠️ **Les entrées du zip utilisent des ANTISLASHS** (`neovibe_alpha\.git\config`)
et non des barres obliques. Une sonde écrite en `*/.git/*` répond donc **faux**
alors que tout est présent — piège rencontré le 2026-08-13. Normaliser avant de
tester :

```powershell
$names = $zip.Entries | ForEach-Object { $_.FullName -replace '\\','/' }
```

**Contrôles à passer sur l'extrait** (tous verts le 2026-08-13) : branche
`master` suivant `origin/master`, dernier commit du jour, `fsck` sans erreur
(un `dangling tag` est bénin), tag de la version courante présent, et les
**quatre** fichiers hors-dépôt : `lib/core/config/env.dart`,
`.claude/settings.local.json`, `docdev/supabase-secrets.txt`,
`docdev/bot-credentials.txt`.
