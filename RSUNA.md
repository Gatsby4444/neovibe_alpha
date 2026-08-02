# RSUNA — Reprise SUr un Nouvel Appareil

Document de bascule de machine pour le projet **NeoVibe**.
Deux parties : la **partie 1 est pour Jay** (ce qu'il fait à la main), la
**partie 2 est pour Claude Code** (ce qu'il vérifie et reconstruit tout seul
à la première session sur la nouvelle machine).

Dernière mise à jour : **2026-08-02**, état du projet : **v0.9.41**
(testée et **validée** par Jay ; un chantier vient d'être ouvert et attend ses
arbitrages — voir §2.4).

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
| `memory\` (18 fichiers au 2026-08-02) | `C:\Users\<TON_PROFIL>\.claude\projects\C--Charles-neovibe-alpha\memory\` |
| *(optionnel)* `dev\` | `C:\Charles\dev\` — évite de retélécharger 6,4 Go de toolchain |

> ⚠️ **Le chemin `C:\Charles\neovibe_alpha` n'est pas cosmétique.** Claude Code
> range sa mémoire dans un dossier nommé d'après le chemin du projet
> (`C--Charles-neovibe-alpha`). Un autre chemin = mémoire repartie de zéro.

> ⚠️ Le dossier `memory\` contient les **identifiants du compte de test** de la
> base de dev. C'est le seul endroit où ils sont écrits — ils ne sont **pas**
> dans le dépôt, exprès. Passe par la clé USB, **pas** par un service de
> transfert en ligne.

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
4. Les **2 ou 3 derniers rapports** de `rapports-de-sessions/` (le plus récent à
   ce jour : `2026-08-02_14-36.md`, qui contient la **spécification du chantier
   stories en deck** et les questions non tranchées ; puis `2026-08-01_19-55.md`
   pour la nav 5 onglets, les stories et les bots de test).
5. `git log --oneline -15` pour l'état réel du code.

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

### 2.3 État du projet à la bascule (2026-08-02, v0.9.41)

- **`pubspec.yaml` en `0.9.41+131`**, dernière release **v0.9.41**, working tree
  propre, `master` aligné sur `origin/master`.
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
- **Stories livrées et validées** (v0.9.38 → v0.9.41) : une story **EST une Card
  publiée en story**, 24 h consultable sans limite, bandeau en haut du Cercle
  (amis) et du Ping (croisés de moins de 24 h si l'auteur a activé « stories
  publiques »). Côté serveur : table `stories`, `private.can_view_stories`,
  `private.is_story_card`, purge au cron, et purge 24 h de `public.encounters`.
- ⚠️ **Chantier ouvert le 2026-08-02, en attente des arbitrages de Jay : les
  stories en deck.** Il juge le format Card (recto/verso) inadapté aux stories
  et veut un dérivé sans retournement, en deck/éventail. **Trois questions sans
  réponse — ne rien coder avant** : voir §2.4 et `RAPPELS.md` (Décisions en
  attente #6).
- **Cinq bots de test** en base de dev (`Lea`, `Malik`, `Chloe` amis ; `Yanis`,
  `Sofia` croisés), un par branche de la règle d'accès aux stories. Mot de passe
  **hors dépôt**, dans la mémoire de Claude. **À supprimer avant la prod**
  (RAPPELS, avant-prod #14).
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
  - utiliser `ref` (Riverpod) dans un `dispose()` ;
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
- **Outil de diagnostic** : Réglages → Développeur → **Journal caméra**
  (persistant, survit aux crashes, bouton Copier). S'en servir avant de deviner.

### 2.4 Ce qui attend (par priorité, à confirmer avec Jay)

1. **CHANTIER EN TÊTE — les stories en deck.** Décidé par Jay le 2026-08-02 au
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
2. **Trois arbitrages plus anciens, toujours ouverts** : libellé du 4e onglet
   (« Jeux » retenu seul, le feed local voudra sans doute sa place) ; les
   curseurs visionnages/durée **conservés** dans l'envoi direct en conversation,
   à confirmer ; faut-il que les **bots répondent** (demande un déclencheur
   serveur — cron ou Edge Function, chantier à part) ?
3. **Suite de la réorganisation UI**, acceptée dans le principe et non faite :
   sortir « Enregistrements » et « Stockage des Cards » des Réglages vers le
   Profil, puis remonter le ♥ (demandes / recos / waves) en badge sur l'onglet
   Profil. Ce sont les deux accès les plus contre-intuitifs qui restent.
4. **Contrôle d'accès des stories à confirmer À L'ŒIL** : *Yanis* doit
   apparaître dans le bandeau du Ping, *Sofia* **nulle part**. Vérifié en base,
   jamais constaté à l'écran.
5. **Streaks de proximité** — chantier promis, Jay a insisté pour ne pas
   l'oublier. ⚠️ `public.encounters` étant désormais purgé à 24 h, un streak ne
   peut **pas** se calculer en relisant cette table : il faudra un compteur
   persistant séparé (RAPPELS, chantiers #1).
6. **Quiz / mini-jeux** puis **feed local**. Conseil non tranché : faire la
   **couche d'abstraction des accès aux données** avant eux.
7. Le reste de `RAPPELS.md` (dont : réactiver FLAG_SECURE, retirer la section
   Développeur et le journal caméra, **supprimer les bots de test**, masquer ou
   livrer l'onglet Jeux — le tout avant la prod ; vidéo HD quand l'hébergement
   le permettra ; vignettes des « Enregistrements » à câbler sur le cache local).

### 2.5 Premier message à Jay

Résumer en quelques phrases : ce qui a été vérifié, ce qui manque le cas échéant
(`env.dart`, mémoire, MCP, tags), l'état du projet, et **reposer les trois
questions du chantier stories en deck** — c'est ce qui bloque la reprise. **Ne
pas se lancer dans un chantier sans son feu vert.**

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

Repère de volume au 2026-07-26 : **1 828 entrées, 4,0 Mo** (dont ~1 600 entrées
et ~3 Mo pour `.git` seul). Si le compte tombe à quelques centaines d'entrées ou
si le zip fait moins d'un mégaoctet, **`.git` manque** — c'est exactement la
signature du piège n°1.
