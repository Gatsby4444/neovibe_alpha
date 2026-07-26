# RSUNA — Reprise SUr un Nouvel Appareil

Document de bascule de machine pour le projet **NeoVibe**.
Deux parties : la **partie 1 est pour Jay** (ce qu'il fait à la main), la
**partie 2 est pour Claude Code** (ce qu'il vérifie et reconstruit tout seul
à la première session sur la nouvelle machine).

Dernière mise à jour : **2026-07-26**, état du projet : **v0.9.34**
(⚠️ **v0.9.31, v0.9.32, v0.9.33 et v0.9.34 sont en attente du retour de test de
Jay** — voir §2.4).

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
| `memory\` (15 fichiers) | `C:\Users\<TON_PROFIL>\.claude\projects\C--Charles-neovibe-alpha\memory\` |
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
   ce jour : `2026-07-26_16-48.md` ; celui du `2026-07-26_15-19.md` couvre toute
   la session outils de capture v0.9.33/v0.9.34).
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

### 2.3 État du projet à la bascule (2026-07-26, v0.9.34)

- **`pubspec.yaml` en `0.9.34+124`**, dernière release **v0.9.34**, working tree
  propre, `master` aligné sur `origin/master`.
- **Chantier en cours : l'UX caméra / cards**, que Jay veut **close avant**
  d'ouvrir tout nouveau chantier. Les cinq outils de capture livrés en
  v0.9.33/v0.9.34 : barre du bas réordonnée (Card | Cercle | Profil), **flash
  frontal** (lueur d'écran, Dart pur, zéro natif), **grille** de cadrage,
  **retardateur** 3/5/10 s, **HD** photo. Colonne d'outils, de haut en bas :
  flash · retardateur · grille · HD · bascule caméra · couleur.
- **Le Oneshot n'hérite de rien** (règle permanente) et **le BeReal est exclu de
  ces outils** par arbitrage de Jay du 2026-07-26 — il a « d'autres projets »
  pour ce format et les détaillera.
- **Double live Oneshot** fonctionnel depuis la v0.9.2 (Camera2 brut, 1 flux par
  caméra), toujours en **opt-in développeur** (Réglages → Développeur → « Double
  flux Oneshot »).
- **Deux chantiers décidés le 2026-07-26**, à ouvrir quand l'UX caméra sera
  close : **quiz / mini-jeux entre amis** et **feed local** (ville / région /
  pays + comptes créateurs internationaux — à ne pas confondre avec le feed
  algorithmique global, lui hors scope). Périmètre dans `docs/vision-produit.md`.
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
    refaire.
- **Outil de diagnostic** : Réglages → Développeur → **Journal caméra**
  (persistant, survit aux crashes, bouton Copier). S'en servir avant de deviner.

### 2.4 Ce qui attend (par priorité, à confirmer avec Jay)

1. **Retours de test en attente : v0.9.31, v0.9.32, v0.9.33 et v0.9.34.** Le
   point sensible est le **flash frontal repris en v0.9.34** (pleine luminosité,
   écran entier, fondu à coins arrondis) — c'est sa deuxième version, la
   première ayant été rejetée par Jay.
2. **Retirer le bouton couleur du BeReal** — tranché par Jay le 2026-07-26
   (« il n'y aura pas de bouton couleur, cela va de soi »), le code l'affiche
   encore. **Première tâche de code de la reprise.**
3. **Flash en Oneshot** — en attente des règles de Jay.
4. **Persistance de l'allumage du flash frontal** — seul le calibrage est
   mémorisé aujourd'hui ; à valider avec Jay.
5. **Streaks de proximité** — chantier promis, Jay a insisté pour ne pas
   l'oublier.
6. **Quiz / mini-jeux** puis **feed local**, une fois l'UX caméra close.
7. Le reste de `RAPPELS.md` (dont : réactiver FLAG_SECURE, retirer la section
   Développeur et le journal caméra avant la prod ; vidéo HD quand
   l'hébergement le permettra ; vignettes des grilles à câbler sur le cache
   local).

### 2.5 Premier message à Jay

Résumer en quelques phrases : ce qui a été vérifié, ce qui manque le cas échéant
(`env.dart`, mémoire, MCP, tags), l'état du projet, et proposer de reprendre par
le bouton couleur du BeReal. **Ne pas se lancer dans un chantier sans son feu
vert.**

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
