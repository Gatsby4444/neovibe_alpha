# RSUNA — Reprise SUr un Nouvel Appareil

Document de bascule de machine pour le projet **NeoVibe**.
Deux parties : la **partie 1 est pour Jay** (ce qu'il fait à la main), la
**partie 2 est pour Claude Code** (ce qu'il vérifie et reconstruit tout seul
à la première session sur la nouvelle machine).

Dernière mise à jour : **2026-07-14**, état du projet : **v0.9.2**
(⚠️ **en attente du retour de test de Jay sur la v0.9.2** — c'est le premier
point à traiter à la reprise, voir §2.4).

---

## Réponse courte à « faut-il zipper le dossier ? »

**Non.** Tout ce qui compte est sur GitHub :
`https://github.com/Gatsby4444/neovibe_alpha` (privé).
Un `git clone` suffit. **Trois choses seulement** ne sont PAS dans le dépôt, et
c'est volontaire :

| Ce qui manque | Pourquoi | Comment le récupérer |
|---|---|---|
| `lib/core/config/env.dart` | Contient la clé Supabase → jamais committé (règle de sécurité du projet) | Le recréer à partir de `lib/core/config/env.example.dart` — voir §1.4 |
| La **toolchain** (Flutter, JDK 17, Android SDK) | Ce sont des logiciels, pas du code projet | Réinstaller — voir §1.2 |
| La **mémoire de Claude Code** (`~/.claude/…/memory/`) | Elle vit hors du dépôt et contient les identifiants du compte de test | Copier le dossier à la main (clé USB) — voir §1.5. Sinon Claude la reconstruira depuis les rapports de session, en perdant le mot de passe du compte de test. |

Un zip / SwissTransfer du dossier complet n'apporterait que `build/`,
`.dart_tool/` et `.gradle/` — des dossiers régénérables, lourds et inutiles.
**Ne les transfère pas.**

---

# PARTIE 1 — Pour Jay (à faire à la main sur la nouvelle machine)

### 1.1 Installer les outils de base

- **Git** : https://git-scm.com/download/win
- **Claude Code** : https://claude.com/claude-code (se connecter avec le compte
  habituel — `upliftwebcontact@gmail.com`)
- **GitHub CLI** (`gh`) : https://cli.github.com — sert à publier les APK en
  release. Une fois installé : `gh auth login` (compte `Gatsby4444`).

### 1.2 Réinstaller la toolchain (mêmes chemins que sur l'ancienne machine)

Tout était installé dans `C:\Charles\dev\`, **hors du PATH système** — garde
exactement cette organisation, tous les scripts et la mémoire de Claude s'y
réfèrent :

| Outil | Version | Chemin attendu |
|---|---|---|
| Flutter | 3.44.6 | `C:\Charles\dev\flutter` |
| JDK Temurin | 17 | `C:\Charles\dev\jdk17` |
| Android SDK | platforms 35 + 36, build-tools 35/36 | `C:\Charles\dev\android-sdk` |

- Flutter : https://docs.flutter.dev/get-started/install/windows (dézipper dans
  `C:\Charles\dev\flutter`)
- JDK 17 : https://adoptium.net/temurin/releases/?version=17
- Android SDK : le plus simple est d'installer **Android Studio**, puis de
  pointer le SDK sur `C:\Charles\dev\android-sdk` (ou d'utiliser les
  `cmdline-tools` seuls).

> ⚠️ **Piège connu** (déjà rencontré) : sans `JAVA_HOME` posé explicitement,
> Gradle échoue immédiatement. Claude le pose lui-même dans ses commandes, mais
> si tu compiles à la main :
> ```powershell
> $env:JAVA_HOME="C:\Charles\dev\jdk17"
> $env:ANDROID_HOME="C:\Charles\dev\android-sdk"
> $env:Path="C:\Charles\dev\flutter\bin;C:\Charles\dev\jdk17\bin;$env:Path"
> ```

### 1.3 Récupérer le projet

**Cloner au MÊME chemin qu'avant** — `C:\Charles\neovibe_alpha`. Ce n'est pas
cosmétique : Claude Code range sa mémoire dans un dossier nommé d'après le
chemin du projet (`C--Charles-neovibe-alpha`). Un autre chemin = mémoire
repartie de zéro.

```powershell
mkdir C:\Charles
cd C:\Charles
gh repo clone Gatsby4444/neovibe_alpha
```

### 1.4 Recréer `lib/core/config/env.dart` (obligatoire, sinon l'app ne compile pas)

Ce fichier est volontairement absent du dépôt. Deux façons :

- **Le plus simple** : le copier depuis l'ancienne machine (clé USB) — c'est un
  fichier de 6 lignes.
- **Sinon** : le recréer depuis le modèle `lib/core/config/env.example.dart`,
  avec l'URL du projet Supabase de dev
  (`https://dvixmhvqqjvbrpsckmyi.supabase.co`) et la **clé publishable**, à
  récupérer sur https://supabase.com/dashboard (projet `neovibe_alpha`, ref
  `dvixmhvqqjvbrpsckmyi`) → *Project Settings → API Keys*.
  Claude Code sait aussi la récupérer lui-même via le MCP Supabase
  (`get_publishable_keys`) une fois celui-ci connecté.

### 1.5 Rapatrier la mémoire de Claude Code (recommandé)

Sur **l'ancienne** machine, copie tout le dossier :

```
C:\Users\Utilisateur\.claude\projects\C--Charles-neovibe-alpha\memory\
```

Sur la **nouvelle**, colle-le au même endroit (le nom d'utilisateur Windows
peut changer — l'important c'est
`<TON_PROFIL>\.claude\projects\C--Charles-neovibe-alpha\memory\`).

> ⚠️ Ce dossier contient les identifiants du **compte de test** de la base de
> dev. C'est le seul endroit où ils sont écrits — ils ne sont **pas** dans le
> dépôt, exprès. Passe par une clé USB, **pas** par un service de transfert.
> Si tu ne le fais pas : rien de bloquant, Claude reconstruira le contexte
> depuis `CLAUDE.md`, `RAPPELS.md` et les rapports de session, mais il faudra
> recréer un compte de test.

### 1.6 Serveurs MCP

Le fichier `.mcp.json` est **dans le dépôt** (aucun secret dedans) : Claude
Code proposera d'activer les serveurs à la première session.

- **Supabase** (`https://mcp.supabase.com/mcp`) : une authentification dans le
  navigateur sera demandée. ⚠️ **Toujours scopé au projet de DEV**
  (`dvixmhvqqjvbrpsckmyi`) — jamais de manipulation de données de production.
- **code-review-graph** : optionnel, lancé par la commande `code-review-graph`.
  Si elle n'est pas installée sur la nouvelle machine, ignore-le : rien du
  projet n'en dépend.

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
   **Les règles impératives (rapport de session, `RAPPELS.md`) s'appliquent dès
   la première session sur la nouvelle machine.**
2. `RAPPELS.md` — dettes, bugs connus, chantiers promis, décisions à ne pas
   reproposer.
3. Les **2 ou 3 derniers rapports** de `rapports-de-sessions/` (le plus récent
   à ce jour : `2026-07-14_13-24.md` — toute la saga du double flux caméra, avec
   les erreurs à ne pas refaire).
4. `git log --oneline -15` pour l'état réel du code.

### 2.2 Vérifications d'environnement (à faire, pas à supposer)

```bash
# Toolchain (chemins hors PATH — les préfixer systématiquement)
ls C:/Charles/dev/flutter/bin/flutter.bat
ls C:/Charles/dev/jdk17
ls C:/Charles/dev/android-sdk

# Le fichier de config local existe-t-il ? (gitignoré, absent d'un clone frais)
ls lib/core/config/env.dart

# L'analyse est-elle propre ?
"C:/Charles/dev/flutter/bin/flutter.bat" analyze

# Compilation (JAVA_HOME est OBLIGATOIRE, sinon Gradle échoue immédiatement)
JAVA_HOME="C:/Charles/dev/jdk17" "C:/Charles/dev/flutter/bin/flutter.bat" build apk --release
```

- **Si `lib/core/config/env.dart` manque** : ne pas inventer de clé. Le recréer
  depuis `env.example.dart` en récupérant la clé publishable via le MCP Supabase
  (`get_publishable_keys`, projet `dvixmhvqqjvbrpsckmyi`), ou demander à Jay.
  **Ne jamais committer ce fichier.**
- **Si `android/gradlew` ou le wrapper Gradle manque** après un clone frais :
  c'est normal (ignoré par le `.gitignore` de Flutter), l'outil Flutter le
  régénère tout seul au premier build.
- **Si la mémoire (`~/.claude/…/memory/`) est vide** : la reconstruire à partir
  de `CLAUDE.md`, `RAPPELS.md` et des rapports de session. Le compte de test de
  la base de dev n'y sera plus : le signaler à Jay plutôt que d'en créer un
  sans lui demander.

### 2.3 État du projet à la bascule (2026-07-14, v0.9.2)

- **Dernière release** : v0.9.2. Le **double live Oneshot fonctionne** sur le
  Redmi Note 10 Pro de Jay (Camera2 brut, **1 flux par caméra**, rendu logiciel
  de l'aperçu, capture simultanée des deux faces). Encore **opt-in développeur**
  (Réglages → Développeur → « Double flux Oneshot » → bouton « Double live »
  dans le Oneshot).
- **Capture rapide** : ~87 ms pour les deux faces + ~200 ms par normalisation
  (mesuré dans le journal). Le recadrage/format des cards se fait en natif
  (`NativeCamera.normalize`).
- **Type de card figé au déclenchement** (`_lockedType`) : correction du bug
  critique qui permettait de fabriquer une Mono à deux faces.
- **À ne JAMAIS refaire** (chaque point a coûté une version, tout est détaillé
  dans le rapport du 2026-07-14) :
  - appeler une API Flutter (TextureRegistry, MethodChannel) hors du thread
    principal ;
  - répondre deux fois à un `MethodChannel.Result` ;
  - demander 2 flux par caméra en double flux (la frontale est affamée) ;
  - reconfigurer une session caméra pendant que l'autre caméra tourne ;
  - **sonder des configurations caméra au moment de l'usage** : un essai raté
    tue le service caméra d'Android jusqu'au redémarrage de l'app ;
  - juger du matériel sur un **délai en dur** (« 0 image après 600 ms ») : une
    caméra ne démarre pas en un temps fixe → attendre le FAIT, pas le
    chronomètre ;
  - faire du travail lourd (rendu, conversion) **sur le thread caméra** ;
  - utiliser `ref` (Riverpod) dans un `dispose()`.
- **Outil de diagnostic** : Réglages → Développeur → **Journal caméra**
  (persistant, survit aux crashes, bouton Copier). C'est lui qui a débloqué tout
  le chantier — s'en servir avant de deviner.

### 2.4 Ce qui attend (par priorité, à confirmer avec Jay)

1. **Retour de test de la v0.9.2** (Jay teste juste après la bascule de
   machine) — attendu : le double live s'ouvre **du premier coup** (plus de faux
   « appareil non compatible »), aperçu fluide, journal propre. Lui demander le
   journal.
2. **Vidéo double simultanée** en Oneshot (deux encodeurs) — pas encore faite.
3. **Streaks de proximité** — chantier promis, Jay a insisté pour ne pas
   l'oublier.
4. Le reste de `RAPPELS.md` (dont : réactiver FLAG_SECURE, retirer la section
   Développeur et le journal caméra avant la prod ; vignettes des grilles à
   câbler sur le cache local).

### 2.5 Premier message à Jay

Résumer en quelques phrases : ce qui a été vérifié, ce qui manque le cas
échéant (`env.dart`, mémoire, MCP), l'état du projet, et proposer de reprendre
par le bug du sélecteur de type. **Ne pas se lancer dans un chantier sans son
feu vert.**
