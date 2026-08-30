# NeoVibe — Contexte projet pour Claude Code

## Positionnement

NeoVibe est un réseau social qui cherche à **retrouver de l'authenticité et du réel dans les échanges en ligne**, contre le contenu vide et les échanges sans valeur parce que trop faciles (le snap envoyé à tout le monde). L'app mise sur **l'exclusivité et la valeur des relations, pas sur leur quantité** : c'est l'app sur laquelle on discute avec ses amis proches ou ses camarades de classe, ceux qu'on voit tous les jours. Positionnement visé : le juste milieu entre **fun et pratique**, avec un maximum d'authenticité. Concurrent direct de référence : **Snapchat** (caméra-first, éphémère, cercles restreints) — pas Meta.

**La présence physique est le mécanisme d'entrée** dans le réseau : on ajoute quelqu'un en ami par proximité BLE, ou par recommandation d'un ami commun quand la rencontre physique est impossible. C'est la barrière fondatrice.

**Corollaire à ne jamais perdre de vue** : une barrière sans contrepartie ne retient personne. Si l'accès au chat est plus difficile ici qu'ailleurs, les utilisateurs vont ailleurs. **Il faut donc donner une légitimité aux barrières sociales** en rendant l'app utile, fun et vivante — c'est la moitié du produit qui reste à construire (voir `docs/vision-produit.md`).

**Ajout du 2026-08-13 — « l'Apple des réseaux sociaux »** : interface **claire et épurée mais qui reste cool**, et **contrôle total de l'écosystème** — *« ce qui se passe sur NeoVibe reste sur NeoVibe »*. C'est la raison d'être du chiffrement et de la livraison sécurisée des médias : ce ne sont pas des précautions d'ingénieur, c'est cette phrase rendue vraie. Conséquence directe : **un média déchiffré écrit en clair sur le disque est un manquement à la promesse**, pas un détail d'implémentation. Corollaire de méthode : la bonne réponse est **le défaut juste, pas l'option supplémentaire** — sans quoi « contrôle total » et « épuré » se contredisent. Détail dans `docs/vision-produit.md` §1.

⚠️ **Périmètre de cette phrase — précision de Jay, 2026-08-20.** Elle désigne **la difficulté de faire fuiter du CONTENU NeoVibe vers l'extérieur** : format card, anti-capture, livraison scellée. Ce n'est **pas** un argument sur les métadonnées côté serveur (qui croise qui, qui parle à qui). Ne pas la ressortir pour peser sur un arbitrage de ce type — les arbitrages sur les métadonnées se posent pour eux-mêmes, avec leur coût réel et leur rétention.

Grille de décision, à appliquer à toute fonctionnalité : **soit elle passe par la présence physique, soit elle augmente la valeur d'une relation existante.** Si elle ne fait ni l'un ni l'autre, c'est du remplissage — exactement le mal qu'on combat. En cas de doute, trancher en faveur de l'authenticité de la relation, même si c'est moins pratique à développer.

La vision complète (mécaniques fondatrices, ce qui reste à construire, points de vigilance) est dans **`docs/vision-produit.md`** — à relire en début de session avec `RAPPELS.md` et les derniers rapports.

---

## Règle impérative : UN FAIT SE VÉRIFIE À LA SOURCE, JAMAIS DANS UN DOCUMENT

*Consigne de Jay, 2026-08-25 — impérative, sans exception.*

> « Tu ne dois pas te fier aux rapports d'anciennes sessions, ni aux vieux
> documents explicatifs, ni aux commentaires : il faut **vérifier en base ou
> dans le code** pour contrôler une information avant d'en déduire quoi que ce
> soit. »

**Ce qui compte comme source** — et rien d'autre :

| Question | Où la vérifier |
|---|---|
| L'état des données (qui est ami avec qui, quelles lignes existent) | **en base**, par une requête |
| Ce que fait le code | **dans le code**, en déroulant la chaîne jusqu'au bout |
| Ce que produit un build | **sur l'artefact** (manifeste fusionné, `aapt`, `apksigner`) |
| Ce qui s'est passé sur l'appareil | **dans le rapport de diagnostic de CE test** |

**Ce qui ne compte PAS comme source** : un rapport de session antérieur, une
entrée de `RAPPELS.md`, un commentaire de code, un fichier de `docs/`, une
migration SQL, ou ma propre mémoire. Tous décrivent **ce qui était vrai le jour
où ils ont été écrits**. Ils servent à savoir **quoi aller vérifier** — jamais à
conclure.

⚠️ **Le piège est qu'un document périmé est indiscernable d'un document juste.**
Il ne se contredit pas, il ne lève aucune erreur : il induit simplement un
raisonnement entier dans la mauvaise direction, avec l'assurance d'une source.

**Exemple de référence, 2026-08-25** : un rapport du 2026-08-17 mentionnait une
remise à zéro « Charles ↔ mimi pour le test de première rencontre ». J'en ai
conclu que les deux comptes n'étaient **pas** amis pendant le test du 2026-08-25,
et j'ai bâti tout un diagnostic dessus. **Ils étaient amis.** Une requête en base
aurait coûté dix secondes et évité une analyse fausse.

**Corollaire** : quand une conclusion repose sur un fait non vérifié, le dire
explicitement — « je suppose X, à confirmer » — au lieu de l'énoncer comme
acquis. Voir aussi la règle 7 ci-dessous (« ne jamais livrer un correctif fondé
sur une déduction ») : celle-ci en est l'amont.

---

## Règle impérative : la fiabilité vient de l'architecture, pas du colmatage

*Consigne de Jay, 2026-08-11 — impérative, applicable à tout chantier.*

> « On doit construire une architecture robuste et claire, ne pas tout mélanger
> et colmater les brèches. La fiabilité vient de l'architecture et de la
> structure, pas du rebouchage des failles. Et **on sépare clairement et
> distinctement tout ce que l'on peut**. »

Ce qui en découle, à appliquer avant d'écrire la moindre ligne :

1. **Devant un risque, chercher d'abord à supprimer la cause**, et seulement
   ensuite à empêcher qu'elle nuise. Un garde-fou est un aveu : il faut le
   maintenir, le comprendre et ne jamais le contourner par mégarde. Une cause
   supprimée ne coûte plus rien.
2. **Deux objets qui n'obéissent pas aux mêmes règles ne partagent ni le même
   stockage, ni la même table, ni le même chemin d'accès.** S'ils les
   partagent, c'est la règle la plus permissive qui gagne — toujours, et en
   silence.
3. **Compter les chemins qui mènent à un contenu.** Plusieurs chemins aux
   règles différentes = défaut de conception, pas contrainte à documenter.
4. **Une règle de sécurité doit s'énoncer positivement.** « Ce fichier n'existe
   pas » vaut infiniment mieux que « ce fichier existe mais rien ne le rend
   lisible ». Toute sécurité qui s'énonce par une négation (« tant que personne
   n'ajoute… ») a une date de péremption.
5. **Ne pas mélanger le contenu et le format.** Un même média diffusé selon
   plusieurs règles doit donner plusieurs objets distincts, chacun avec son
   cycle de vie. Un objet appartient à **un seul contexte de diffusion**.
6. **Après un changement d'architecture, rejouer les décisions qui en
   dépendaient** au lieu de dérouler un plan écrit avant.
7. **Ne jamais livrer un correctif fondé sur une déduction.** Reproduire la
   panne d'abord — en base, sous l'identité de l'utilisateur, avec la sécurité
   active (`set local role authenticated` + `request.jwt.claims`). Une
   hypothèse plausible qui ne corrige rien fait perdre un aller-retour de test
   à Jay **et** ajoute des changements non justifiés au diff.
8. **Toute suppression est une opération sur un réseau — relever les DEUX sens
   avant de couper.** *Consigne de Jay, 2026-08-12, après la panne
   `saved_cards` — impérative.*

   > « Quand tu supprimes quelque chose il faut impérativement toujours vérifier
   > où ce que tu supprimes est appelé, et ce que ce que tu supprimes appelle.
   > C'est comme si tu supprimais un nœud d'un réseau : tu casses le réseau, car
   > les autres nœuds appelaient le nœud supprimé et le nœud supprimé appelait
   > d'autres nœuds. »

   Avant de supprimer quoi que ce soit — table, colonne, fonction, politique,
   widget, provider, écran, fichier natif :

   - **Sens entrant : qui m'appelle ?** Balayer **toutes** les familles d'objets,
     pas seulement celle qu'on supprime : politiques RLS, corps de fonctions,
     triggers, jobs cron, vues, clés étrangères, appels Dart, et le catalogue
     natif. Un appelant oublié ne se voit **ni au diff, ni à
     `flutter analyze`** — il n'apparaît qu'à l'exécution, chez Jay.
   - **Sens sortant : qu'est-ce que j'appelais ?** Ce que le nœud supprimé
     utilisait devient peut-être orphelin à son tour (fonction sans appelant,
     table sans lecteur, bucket sans écrivain). Le supprimer dans la foulée, ou
     le justifier — un reste mort d'aujourd'hui est la panne de demain.
   - **Ne jamais se fier au `cascade` de PostgreSQL.** Il ne suit que les
     dépendances **déclarées**. Le corps d'une fonction SQL (`AS $$ … $$`) est
     stocké comme du **texte**, réanalysé à l'exécution : PostgreSQL n'y voit
     aucune dépendance. Une fonction survit donc à la table qu'elle interroge,
     et la politique qui l'appelle lui survit à son tour. *(C'est exactement la
     panne du 2026-08-12 : `saved_cards` supprimée le 2026-08-11, et toute
     lecture de `cards` échouait en 42P01.)*
   - **Vérifier par inventaire, pas par le diff** — corollaire de la règle 3.
     Lister les occurrences restantes du motif supprimé et les justifier **une
     par une**.

### Deux pièges Supabase déjà payés

- **Une fonction citée dans une politique RLS doit être exécutable par
  `authenticated`.** Une politique s'évalue avec les droits de celui qui
  interroge. Révoquer l'exécution d'une fonction du schéma `private` ne protège
  de rien — ce schéma n'est pas exposé par PostgREST — et casse toutes les
  politiques qui s'en servent. La consigne « révoquer les fonctions
  `SECURITY DEFINER` » ne vaut que pour le schéma **`public`**, le seul joignable
  sur `/rest/v1/rpc/`. *(Panne du 2026-08-11.)*
- **Une clé étrangère est aussi un chemin de jointure pour le client.**
  PostgREST résout les jointures par le **nom de la contrainte** :
  `profiles!stories_owner_id_fkey(*)` casse si cette contrainte cesse de
  pointer vers `profiles`. En reconstruisant une table, relever les contraintes
  de l'ancienne au lieu de les réécrire de mémoire. La convention du projet est
  `owner_id references public.profiles(id)`. *(Même panne.)*

---

## Règle impérative : dissocier l'ACQUISITION de l'USAGE

*Consigne de Jay, 2026-08-20 — impérative, applicable à tout chantier.*

> « Lorsque tu codes, tu dois totalement dissocier le code qui se charge
> d'acquérir des données du code qui utilise ces données. Avoir une base solide,
> cela veut dire avoir un système d'acquisition et de transmission de données
> robuste, dissocié et indépendant, de sorte à pouvoir ensuite brancher
> n'importe quelle fonctionnalité utilisant ces données. Sinon, à chaque
> modification d'une fonctionnalité on doit toucher à des fonctions qui cassent
> d'autres fonctionnalités. Il faut un code compartimenté et localement
> indépendant. »

C'est le prolongement direct de la règle d'architecture (« la fiabilité vient de
l'architecture, pas du colmatage ») appliquée au **sens de circulation** des
données. Ce qui en découle, à appliquer avant d'écrire la moindre ligne :

1. **Une couche d'acquisition publie ce qu'elle constate, fidèlement, et ne
   décide de rien d'autre.** Elle ne sait pas qui la lit, ni ce qu'il en fera,
   ni s'il faut redessiner un écran. Dès qu'elle filtre « pour économiser », elle
   prend une décision d'affichage qu'elle n'a pas les moyens de prendre.
2. **Qui consomme décide de ce qui l'intéresse**, avec sa propre définition de
   « différent ». Le coût d'une publication trop fréquente se règle **du côté
   consommateur**, par une comparaison de valeurs — jamais en amont.
3. **Deux sources qui ne changent pas au même rythme ne partagent pas le même
   objet d'état.** Les mélanger impose le rythme de la plus rapide au coût de la
   plus lente : une donnée radio à 10 Hz forçait deux lectures de fichier à
   10 Hz. *(C'est exactement le défaut du 2026-08-18, point C.)*
4. **Le test de la règle** : « si j'ajoute un champ à cet écran, dois-je toucher
   au code qui parle à la radio / au réseau / au disque ? » Si oui, la
   séparation n'est pas faite.
5. **Ce type de défaut ne lève aucune erreur.** L'écran affiche la bonne chose,
   les tests passent, seul le coût explose. Il ne se voit qu'en **comptant** —
   les notifications, les lectures disque, les reconstructions. Un test qui
   compte vaut mieux qu'un commentaire qui promet. Exemple de référence :
   `test/presence_feed_test.dart`.

Mise en œuvre de référence dans le projet : `lib/features/proximity/presence_feed.dart`.

---

## Règle impérative : ON SÉPARE TOUT CE QUI PEUT L'ÊTRE

*Consigne de Jay, 2026-08-25 — impérative, applicable à tout le code, sans
exception ni cas particulier.*

> « On sépare tout ce qui peut l'être dans notre code, et on code intelligemment
> et de manière scalable. **On ne mélange plus backend et frontend. On ne mélange
> plus cuisine, serveurs et clients.** »

C'est la généralisation des deux règles précédentes — « la fiabilité vient de
l'architecture » et « dissocier l'acquisition de l'usage » — érigée en principe
par défaut. **Les deux règles ci-dessus en sont désormais des cas particuliers,
pas des exceptions.**

### L'image de référence, à garder en tête

| Rôle | Ce qu'il fait | Ce qu'il ne fait JAMAIS |
|---|---|---|
| **La cuisine** (acquisition, dépôts, natif, SQL) | prépare et publie fidèlement | décider qui est servi, ni quand redessiner |
| **Le serveur** (vues dérivées, providers) | choisit ce qui l'intéresse, à son rythme | aller cuisiner lui-même |
| **Le client** (widgets, écrans) | affiche | aller en cuisine chercher son plat |

**Le test, à s'appliquer avant d'écrire une ligne** : *pour changer la
présentation, dois-je toucher à ce qui prépare la donnée ?* Si oui, la séparation
n'est pas faite.

### Ce qui en découle

1. **Un écran ne parle jamais au réseau, au disque ou au natif.** Il demande à un
   dépôt. Une requête écrite dans un fichier d'écran n'est réutilisable par
   personne, et se retrouve dupliquée — *constaté le 2026-08-25 :
   `chat_screen.dart` avait sa propre copie de `cardByIdProvider`, mot pour mot,
   avec son propre cache.*
2. **L'invalidation de cache appartient à l'ÉCRITURE, jamais à l'appelant.** Deux
   écrans qui écrivent la même table doivent laisser le lecteur dans le même
   état ; sinon l'un affiche du périmé et l'autre non, selon lequel a servi.
3. **Le temps est une SOURCE, pas une commodité.** Tout filtre qui appelle
   `DateTime.now()` dépend d'une donnée qu'il n'observe pas. On s'y abonne
   (`core/clock.dart`) ou on assume l'instantané **en l'écrivant**.
4. **Un chemin, une donnée.** Deux chemins vers la même chose, c'est deux caches
   et un désaccord futur que rien ne signalera.
5. **Scalable veut dire : le coût d'ajouter le prochain cas.** Une solution qui
   marche pour deux écrans mais demande d'en toucher cinq au troisième n'est pas
   une solution, c'est une dette. Compter le nombre d'endroits à modifier
   *avant* de choisir.
6. **Ce défaut ne lève aucune erreur** — il ne se voit qu'en **comptant**.
   Un test qui compte vaut mieux qu'un commentaire qui promet.

### Les outils du projet, à utiliser plutôt qu'à réinventer

| Besoin | Outil |
|---|---|
| une vue dérivée **sans paramètre** qui ne réveille que si son résultat change | `DerivedList` / `DerivedSet` (`core/derived_list.dart`) |
| une vue dérivée **paramétrée** (idem) | `ValueList<T>` (`core/derived_list.dart`) |
| tout ce qui **périme** | `expiryClockProvider` (`core/clock.dart`) |

⚠️ **Ces outils sont inopérants en silence si le type de l'élément n'a pas
d'égalité de valeur.** Tout modèle placé dans une liste dérivée doit porter son
`==` — c'est ce qui manquait à **tous** les modèles avant le 2026-08-25.

Audit fondateur et état avant/après : **`docs/checkup-acquisition-usage.md`**.
Tests de référence : `test/derived_list_test.dart`,
`test/dissociation_connections_test.dart`, `test/presence_feed_test.dart`.

---

## Règle impérative : UN DÉFAUT TROUVÉ SE RÉPARE TOUT DE SUITE

*Consigne de Jay, 2026-08-30 — impérative, sans exception.*

> « On ne laisse jamais des défauts trouvés en attente. Après, c'est cela qui
> nous perd et qui crée de plus grosses erreurs. »

**Le moment où un défaut est trouvé est le seul moment où il est entièrement
compris.** Une heure plus tard il ne reste que sa description ; un jour plus
tard, une ligne dans `RAPPELS.md` que quelqu'un devra ré-instruire depuis zéro.

### Ce qu'il faut faire

1. **Réparer dans la foulée**, dans la même session, avant de passer à la suite.
   Consigner ne remplace jamais réparer : `RAPPELS.md` sert à ce qui demande une
   DÉCISION de Jay, pas à ranger ce qu'on sait déjà corriger.
2. **Le défaut qu'on vient de créer soi-même passe en premier.** Il est encore
   frais, et personne d'autre ne sait qu'il existe.
3. **Si la réparation ne peut vraiment pas se faire maintenant**, le dire à Jay
   avec la raison — et c'est *lui* qui reporte, pas moi.

### Pourquoi c'est un principe, et pas de la propreté

Un défaut en attente ne reste pas de la même taille : le code continue de
s'écrire **par-dessus** lui. Les correctifs suivants se posent sur une base dont
on sait qu'elle est fausse, et chacun devient un point à démêler le jour de la
vraie réparation. Le coût ne croît pas linéairement, il se ramifie.

⚠️ **Et le cas le plus coûteux est celui d'un INSTRUMENT défaillant** — une
mesure illisible, un libellé qui ment, un compteur jamais incrémenté. Il ne
gêne rien tout de suite : il fausse simplement toutes les décisions prises
ensuite, sans que rien ne le signale. *Le 2026-08-30, deux instruments ont été
livrés le même jour sans sortie lisible ; le second promettait de répondre à une
question qu'il ne pouvait pas atteindre.*

### ⚠️ Le test à s'appliquer

**« Est-ce que je viens d'écrire, ou de dire, que quelque chose ne va pas ? »**
Si oui, ça se répare maintenant. Une phrase qui commence par *« à corriger plus
tard »* ou *« à noter pour la prochaine session »* doit être justifiée devant
Jay, jamais décidée seul.

Voir aussi la règle 8 (« toute suppression est une opération sur un réseau ») :
un reste mort d'aujourd'hui est la panne de demain — c'est la même règle, vue
depuis la suppression.

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

- **Frontend** : Flutter/Dart (choisi pour perf caméra, cohérence cross-platform, écosystème BLE)
- **Backend** : Supabase
- **State management** : Riverpod
- **Connectivité proximité** : **BLE uniquement, et uniquement pour PROUVER la
  proximité** (décision de Jay du 2026-08-27). Il ne transporte plus rien : ni
  messages, ni demandes d'ami, ni médias. *« Notre objectif n'est plus une app
  de messagerie pair-à-pair, mais une app sociale qui mise sur la proximité. »*
  **Wi-Fi Direct est abandonné** — il n'avait jamais été écrit. Tout le
  contenu passe par le serveur, avec sa livraison scellée.
- **Repo** : GitHub privé, releases taguées → APK compilés
- **Test** : APK natif Android, testé manuellement par Jay (pas de CI de test automatisé pour l'instant)

---

## Décisions verrouillées — ne pas remettre en question sans validation explicite de Jay

- **Connexions** : formées uniquement via proximité BLE ou recommandation tierce (plafond 10/mois, chaîne A→B→C). Pas de découverte par recherche/annuaire.
- **Architecture éphémère** : upload en fichier temporaire, transmission côté serveur, vue unique, suppression après TTL 24h. Le replay nécessite un consentement explicite de l'émetteur, routé par le serveur. Le streaming zéro-écriture a été évalué et rejeté (trop coûteux en ressources pour le MVP) — ne pas le proposer à nouveau sans nouvelle contrainte business.
- **Vibes** (nom public depuis le 2026-08-10 ; le code et la base gardent `card`) : **3 types**, après la refonte du 2026-08-10. **Standard** — une ou deux faces, le verso est facultatif (bouton « Passer ») ; **Oneshot** — avant et arrière capturés d'un seul déclenché, caméra pure sans outils, et **sinon régi comme une standard** ; **BeReal** — capture contrainte, sans post-production, déclenché par notification. Le **One of One** n'est plus un type sélectionnable : il s'applique automatiquement à l'envoi (un destinataire, aucune publication), sauf en bibliothèque partagée. **Mono et Hot sont supprimées.** ⚠️ La « vue unique puis destruction » du Oneshot **n'existe plus** — elle avait en réalité disparu dès le 2026-07-11 (migration `cards_v2_mechanics`, fonction `destroy_oneshot` supprimée) ; ce fichier l'a affirmée à tort jusqu'au 2026-08-10.
- **La sauvegarde est le CINQUIÈME contexte de diffusion** (acté par Jay le 2026-08-14). Une sauvegarde n'est pas une Vibe avec ses limites éteintes : c'est un objet distinct — octets **en clair sur l'appareil**, aucune clé, aucune règle de visionnage, aucune ligne serveur, permanent. **Ne jamais la refusionner avec la Card** ; en particulier, ne pas créer la Card au clic sur « Enregistrer pour moi ». Les quatre raisons et le seul lien admis (`SavedStore.rekey`) sont dans `docs/stockage-et-acces.md`.
- **Rétention** : streaks de proximité avec paliers de couleur et dégradation progressive ; notification FOMO "le presque" pour les quasi-rencontres physiques (différée par défaut, opt-in temps réel).
- **Anti-capture** : positionnement assumé "coûteux et visible, pas impossible" (pas de promesse d'impossibilité technique). Architecture 4 couches : flags OS, watermarking stéganographique dynamique, détection d'anomalie comportementale, couche contractuelle/sociale.

## Explicitement hors scope MVP — ne pas implémenter sans demande explicite

- **Feed algorithmique global type TikTok** (contredit la thèse du produit). ⚠️ **À ne pas confondre avec le feed LOCAL, lui décidé par Jay le 2026-07-26** : contenu publié par les gens de ta ville / région / pays, plus comptes créateurs à visibilité internationale. Périmètre et points de vigilance dans `docs/vision-produit.md`.
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

---

## Règle impérative : PARLER SIMPLEMENT — Jay est débutant

*Consigne de Jay, 2026-08-28 — impérative, elle s'applique à toutes les réponses.*

> « Explique-moi les choses clairement et simplement, en gardant en tête que je
> suis débutant. »

**Ce n'est pas une préférence de style : c'est une condition pour que Jay puisse
décider.** Il tranche les décisions produit (voir plus haut). Une explication
qu'il ne peut pas suivre ne lui retire pas seulement du confort — elle lui retire
le pouvoir d'arbitrer, et il se retrouve à valider ce qu'il n'a pas compris.

### Ce qu'il faut faire

1. **Le fait d'abord, en une phrase de tous les jours.** Ce qui se passait, vu de
   son téléphone. Le nom technique vient après, s'il sert encore.
2. **Une image concrète quand le mécanisme est invisible.** Une radio, un
   veilleur de nuit, un carnet, une liste — quelque chose qui existe dans le
   monde réel. Presque tous les défauts de ce projet sont invisibles : sans
   image, il ne reste qu'un vocabulaire.
3. **Distinguer explicitement les mots qui se ressemblent.** *« App fermée »* et
   *« application tuée par Android »* ne sont pas la même chose, et c'est
   exactement ce genre de confusion qui a fait croire qu'une fonction marchait
   alors qu'elle avait un trou. **Quand deux mots proches désignent deux choses
   différentes, le dire avant de continuer.**
4. **Dire ce que ça change POUR LUI.** « Ton téléphone arrêtait de reconnaître
   tes amis pendant la nuit » vaut mieux que « le plan d'émission ne survivait
   pas à la mort du processus ».
5. **Un nom de fichier ou de fonction n'explique rien.** `refreshPlan()` ne veut
   rien dire pour lui. Le citer est utile pour retrouver l'endroit, jamais pour
   faire comprendre le problème — donc **après** l'explication, pas à la place.

### Ce qu'il ne faut pas faire

- ❌ Empiler les termes techniques en supposant qu'ils sont acquis (« provider »,
  « notifier », « RLS », « foreground service », « égalité de valeur »).
- ❌ Répondre par un tableau de symboles quand la question était « qu'est-ce que
  c'est ? ».
- ❌ Confondre **court** et **simple**. Une réponse de deux lignes pleine de
  jargon est plus dure qu'un paragraphe en français clair.
- ❌ Cacher un désaccord ou une incertitude derrière du vocabulaire.

### ⚠️ Le test à s'appliquer avant d'envoyer

**« Si Jay ne connaissait pas ce mot, sa question serait-elle répondue ? »** Si
la réponse dépend d'un terme qu'on n'a pas expliqué, elle n'est pas finie.

Et quand il dit **« je ne comprends pas »**, ce n'est pas une demande de répéter :
c'est le signe que l'explication précédente était construite pour quelqu'un
d'autre. **On recommence autrement, on ne reformule pas plus fort.**

---

## Avant de considérer une tâche terminée

1. `dart format` + `flutter analyze` propres
2. Rapport de session à jour avec les modifications de la tâche
3. Aucun secret en clair dans le diff
4. Si la tâche touche une décision verrouillée ci-dessus sans validation de Jay : s'arrêter et demander confirmation plutôt que d'implémenter
