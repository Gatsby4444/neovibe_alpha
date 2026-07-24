# NeoVibe — Contexte projet pour Claude Code

## Positionnement

NeoVibe est un réseau social dont la thèse centrale est : **la présence physique est la monnaie primaire**, pas l'attention passive. L'app récompense les rencontres réelles plutôt que la consommation de contenu à distance. Concurrent direct de référence : **Snapchat** (caméra-first, éphémère, cercles restreints) — pas Meta.

Chaque décision produit ou technique doit être évaluée à l'aune de cette question : **est-ce que ça renforce ou est-ce que ça dilue la thèse de la présence physique ?** En cas de doute, trancher en faveur de la présence physique, même si c'est moins pratique à développer.

---

## Règle impérative : rapport de session

**À chaque nouvelle session**, créer un rapport dans le dossier `rapports-de-sessions/` à la racine du repo.

- **Nom de fichier** : `AAAA-MM-JJ_HH-MM.md` (date de création du rapport, précise à la minute — heure de début de session)
- **Le rapport est un document vivant** : il doit être mis à jour à chaque modification significative du code ou du projet au cours de la session, pas seulement écrit à la fin.
- **Contenu obligatoire** :
  1. **Modifications apportées** — liste factuelle des fichiers touchés, fonctionnalités ajoutées/modifiées, décisions d'implémentation prises
  2. **Difficultés rencontrées ou erreurs commises** — ce qui a coincé, ce qui a été essayé et n'a pas marché, et **comment ne pas les reproduire** (cause identifiée + solution ou contournement adopté)
  3. **Notes et consignes de Jay** — toute instruction, préférence ou clarification donnée pendant la session, même orale/informelle dans le chat, à consigner pour référence future
- Avant de commencer une nouvelle session, **relire les 1 à 3 derniers rapports** pour ne pas répéter une erreur déjà documentée ou contredire une consigne déjà donnée.
- Un rapport reste factuel et concis. Pas d'auto-satisfaction, pas de reformulation commerciale — c'est un outil de mémoire technique, pas une présentation.

---

## Règle impérative : fichier de rappels

Le fichier **`RAPPELS.md`** à la racine du repo est la mémoire longue de Jay.

- **Tenir ce fichier à jour** : dès que Jay demande de « garder ça pour plus
  tard », de « me le rappeler », ou dès qu'une limite/dette connue est
  identifiée, l'y consigner (sujet, détail, date).
- **Le ressortir au bon moment** : avant une release de production, ou quand
  le chantier concerné revient sur la table, rappeler à Jay les entrées
  pertinentes — sans attendre qu'il le demande.
- Ne rien y supprimer sans validation explicite de Jay.
- Le relire en début de session, avec les derniers rapports.

---

## Règle impérative : catalogue des parties natives

Le fichier **`docs/parties-natives-par-os.md`** recense tout le code natif
(non-Dart) et son équivalent iOS à écrire. C'est la source de vérité du périmètre
natif, pour ne rien découvrir au dernier moment lors du portage iOS.

- **À chaque changement du code natif** (fichier `.kt`/`.swift` ajouté, supprimé
  ou renommé ; méthode de platform channel modifiée ; nouvelle capacité
  matérielle), **mettre ce fichier à jour**.
- **En fin de session**, **vérifier** que ce fichier reflète l'état réel du code
  natif ; le corriger sinon.
- Stratégie plateforme (Android d'abord, iOS additif, pas de fork) :
  `docs/strategie-multiplateforme.md`. **On développe Android d'abord** ; iOS ne
  démarre que sur décision explicite de Jay, une fois Android terminé.

---

## Stack

- **Frontend** : Flutter/Dart (choisi pour perf caméra, cohérence cross-platform, écosystème BLE/WiFi Direct)
- **Backend** : Supabase
- **State management** : Riverpod
- **Connectivité proximité** : BLE (détection + échange de contact) ; WiFi Direct (transfert média)
- **Repo** : GitHub privé, releases taguées → APK compilés
- **Test** : APK natif Android, testé manuellement par Jay (pas de CI de test automatisé pour l'instant)

---

## Décisions verrouillées — ne pas remettre en question sans validation explicite de Jay

- **Connexions** : formées uniquement via proximité BLE ou recommandation tierce (plafond 10/mois, chaîne A→B→C). Pas de découverte par recherche/annuaire.
- **Architecture éphémère** : upload en fichier temporaire, transmission côté serveur, vue unique, suppression après TTL 24h. Le replay nécessite un consentement explicite de l'émetteur, routé par le serveur. Le streaming zéro-écriture a été évalué et rejeté (trop coûteux en ressources pour le MVP) — ne pas le proposer à nouveau sans nouvelle contrainte business.
- **Cartes** : 5 types — standard recto/verso, Oneshot (vue unique puis destruction), One of One (exclusif, destinataire unique), Hot (fenêtre de vue courte + mise en avant automatique), BeReal (capture contrainte, sans post-production).
- **Rétention** : streaks de proximité avec paliers de couleur et dégradation progressive ; notification FOMO "le presque" pour les quasi-rencontres physiques (différée par défaut, opt-in temps réel).
- **Anti-capture** : positionnement assumé "coûteux et visible, pas impossible" (pas de promesse d'impossibilité technique). Architecture 4 couches : flags OS, watermarking stéganographique dynamique, détection d'anomalie comportementale, couche contractuelle/sociale.

## Explicitement hors scope MVP — ne pas implémenter sans demande explicite

- Feed style TikTok (contredit la thèse du produit)
- Détection d'événements publics à grande échelle par clustering géographique (reporté — nécessite d'abord l'infrastructure de confiance)
- Modération IA complexe, systèmes lourds en général : privilégier des heuristiques simples validables tôt

---

## Conventions de code

- Formatage : `dart format` systématique avant de considérer une tâche terminée
- Analyse statique : `flutter analyze` doit être propre (0 erreur) avant commit
- Structure de dossiers et conventions de nommage : suivre l'existant dans le repo, ne pas réorganiser sans consigne
- Un commit = un changement logique. Messages de commit en français, format court et descriptif (pas de conventional commits imposé sauf préférence contraire de Jay)

## Sécurité

- **Ne jamais committer de clé Supabase, token, ou credential en clair.** Si une clé apparaît dans un diff, le signaler avant commit plutôt que de le committer silencieusement.
- Le MCP Supabase utilisé en session de dev doit être scopé à un projet Supabase de développement — jamais de manipulation de données de production via Claude Code.

## Méthode de travail avec Jay

- Jay tranche les décisions produit ; Claude Code exécute et peut signaler les cas limites mais ne décide pas seul sur les points listés dans "décisions verrouillées"
- Le scoping MVP se coupe agressivement : en cas de doute sur la complexité d'une fonctionnalité, proposer la version la plus simple d'abord et signaler explicitement ce qui a été simplifié
- Livrables destinés à Claude Code (specs, prompts) sont prêts à copier-coller — garder cette logique pour toute documentation produite en retour
- Travail mené en français : commentaires de code, messages de commit et rapports de session en français ; le code lui-même (noms de variables, fonctions) reste en anglais par convention Dart/Flutter standard
- **En cas de doute sur une instruction ou une vision de développement, demander à Jay avant d'agir plutôt que de supposer.** Ne pas interpréter en silence une consigne ambiguë ou incomplète — poser la question de clarification, même si ça ralentit la tâche.

## Avant de considérer une tâche terminée

1. `dart format` + `flutter analyze` propres
2. Rapport de session à jour avec les modifications de la tâche
3. Aucun secret en clair dans le diff
4. Si la tâche touche une décision verrouillée ci-dessus sans validation de Jay : s'arrêter et demander confirmation plutôt que d'implémenter
