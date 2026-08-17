# Moteur spatial et transports — note d'architecture

*Écrite le 2026-08-17, sur direction de Jay. Complète `architecture-proximite.md`
(les 8 couches du ping) : ce document-ci décide **quelles technologies on
intègre, à quoi chacune sert, et comment elles se superposent sans jamais
exclure personne**.*

**Rien de ce qui suit n'est implémenté.** C'est une note de décision, pas un
compte rendu.

---

## 0. La méthode, imposée par Jay

> ① on choisit les technologies qu'on intègre ; ② on détermine **à quoi chacune
> sert** ; ③ le système fonctionne **par paliers** — plus il y a de technologies
> précises disponibles entre deux appareils, plus l'expérience est précise et
> fluide, **mais sans exclure ceux qui n'auraient que le BLE de base**.

Et une consigne qui encadre tout le reste (RAPPELS #37) :

> Le coût du natif — « ça n'existe que sur Android », « il faudra le coder deux
> fois » — **n'est jamais un motif de refus**. C'est un chiffrage. La priorité
> est le confort de l'utilisateur.

J'ajoute une quatrième étape, parce que c'est celle qu'on oublie toujours :

> ④ pour chaque technologie, **définir d'abord ce qui se passe quand elle est
> absente**. Concevoir le plancher avant le plafond est la seule façon de tenir
> le « sans exclure personne » — un plancher conçu en dernier est toujours un
> reste.

---

## 1. Ce qui est MESURÉ aujourd'hui

Ce tableau est le socle de toutes les décisions ci-dessous. Il vient de sondes
`hasSystemFeature`, **pas de fiches techniques**.

| | Xiaomi M2101K6G (Android 13) | LENOVO TB-X606F (Android 10) |
|---|---|---|
| BLE | ✅ | ✅ |
| UWB | ❌ *(mesuré 2026-08-16)* | ❌ *(mesuré 2026-08-16)* |
| Wi-Fi RTT | ❌ *(mesuré 2026-08-16)* | ❌ *(mesuré 2026-08-16)* |
| Wi-Fi Direct | *sonde ajoutée le 2026-08-17* | *idem* |
| Wi-Fi Aware | *sonde ajoutée le 2026-08-17* | *idem* |
| BLE Channel Sounding | ❌ — exige du silicium Bluetooth 6.0 | ❌ |

⚠️ **À relire avant de coder quoi que ce soit.** Aujourd'hui, sur le parc de
test, **une seule technologie de ranging existe** : le RSSI. Construire
maintenant un moteur qui *négocie* produirait un sélecteur à une branche, non
testable, et qui aurait vieilli le jour où il servirait.

---

## 2. ① Les technologies retenues

Six, dont deux seulement sont disponibles aujourd'hui.

| Technologie | Retenue ? | Statut |
|---|---|---|
| **BLE (annonce + GATT)** | ✅ | en production |
| **GPS** | ✅ | à intégrer |
| **Wi-Fi Aware / Direct** *(Android)* · **MultipeerConnectivity** *(iOS)* | ✅ | à intégrer, chantier médias |
| **UWB** *(`androidx.core.uwb` / Nearby Interaction)* | ✅ | en attente de matériel |
| **Wi-Fi RTT** | ✅ | en attente de matériel |
| **BLE Channel Sounding** | ⏸️ à surveiller | matériel inexistant sur le parc |

---

## 3. ② Le rôle de chacune — un métier, et un seul

C'est l'application directe de la règle 2 du projet (*deux objets qui n'obéissent
pas aux mêmes règles ne partagent pas le même chemin*). Une technologie qui fait
deux métiers finit toujours par imposer les contraintes de l'un à l'autre.

| Métier | Technologie | Ce qu'elle produit |
|---|---|---|
| **Découverte** — « qui est là ? » | BLE annonce | un identifiant rotatif, un RSSI |
| **Contrôle** — identité, poignée de main, certificat | BLE GATT | une session chiffrée |
| **Ranging** — « à quelle distance ? » | UWB › RTT › Channel Sounding › RSSI | une distance **avec sa marge** |
| **Direction** — « par où ? » | UWB + IMU | un azimut, ou rien |
| **Contexte** — « dans quelle zone ? » | GPS | une position grossière |
| **Transport de données** — messages, médias | BLE GATT *et* Wi-Fi (voir §6) | des octets |

### Deux séparations à ne jamais casser

**Le ranging n'est pas le transport.** L'UWB est un *capteur*, pas un protocole
de messagerie. Ce qu'il mesure alimente le modèle spatial ; il ne transporte
rien.

**Le GPS est un FILTRE, jamais une preuve.** Il sert à écarter ceux qui sont
manifestement loin, donc à ne pas faire de ranging pour rien. Il ne dit jamais
que deux personnes se sont rencontrées — dans un bâtiment, son erreur dépasse
largement la distance qui nous intéresse.

---

## 4. ③ Les paliers — ce qu'ils changent vraiment

⚠️ **Le point le plus important de cette note.**

Un palier ne doit **pas** changer la précision d'une même information. S'il ne
fait que resserrer un nombre — « ~4 m » qui devient « 2,3 m ± 18 cm » — il est
cosmétique, et il ne vaut pas le coût du natif.

Un palier vaut le coup quand il **débloque une fonction que le palier du dessous
ne peut pas rendre du tout** :

| Palier | Disponible sur | Ce qu'il débloque, et que le palier du dessous ne rend PAS |
|---|---|---|
| **0 — Découverte** | tout appareil BLE | *qui est là* → présence, **certificat de croisement**, verrou du chat |
| **1 — Portée réelle** | ranging fin | *qui est **vraiment** à portée* → n'afficher en chat P2P que des gens réellement joignables |
| **2 — Direction** | UWB + IMU | ***par où*** → « aller retrouver quelqu'un ». **N'existe pas** en dessous |
| **3 — Contexte** | GPS + serveur | *avec qui je suis* → clusters, chats et événements de groupe |
| **4 — Débit** | Wi-Fi | *envoyer une vibe* → médias en pair-à-pair |

Ce ne sont pas cinq précisions d'une même chose : ce sont **cinq
fonctionnalités**.

**Conséquence directe, et c'est ce qui rend le « sans exclure personne »
honnête** : un utilisateur BLE-seul ne reçoit pas une flèche moins bonne — **il
ne reçoit pas de flèche**. Une flèche à ±90° qui pointe à côté est pire que pas
de flèche : elle fait marcher quelqu'un dans la mauvaise direction, avec
confiance. Le palier 0 reste entièrement fonctionnel : on se découvre, on se
certifie, on se parle.

Les paliers 1 à 4 sont **indépendants entre eux**. Un appareil peut avoir le
Wi-Fi sans l'UWB, ou le GPS sans le Wi-Fi. Ce n'est pas une échelle, c'est un
ensemble d'options — et le tableau ci-dessus est ordonné par valeur produit, pas
par dépendance technique.

---

## 5. Les quatre règles qui tiennent l'ensemble

### 5.1 Le palier appartient à la PAIRE, jamais à chaque appareil

⚠️ **C'est la leçon des messages fantômes, et elle s'applique mot pour mot.**

Aujourd'hui encore, `initiator` est déduit **indépendamment de chaque côté**, à
partir de l'ordre d'arrivée des événements de lien — et les deux côtés peuvent
donc choisir le même rôle, ce qui casse tout **en silence**.

Un palier a exactement la même forme : deux appareils, une croyance partagée sur
leur relation. Donc :

- le palier est **négocié une fois, dans le tunnel chiffré**, et **porté par la
  session** ;
- il n'est **jamais recalculé** de son côté à partir d'une observation locale.

### 5.2 Une descente de palier est un ÉVÉNEMENT, pas un silence

L'UWB décroche, l'app passe en arrière-plan, une permission est retirée : le
palier baisse. Ça doit **se dire**. « ± 18 cm » qui devient « ~4 m » sans un mot
est de la même famille que le bouton grisé dont le libellé change — l'utilisateur
conclut, raisonnablement, que la fonction est cassée.

### 5.3 Le certificat de croisement ne dépend JAMAIS du GPS

Le certificat est le mécanisme d'entrée de tout le produit. Le faire dépendre
d'une permission de localisation reviendrait à rendre l'app inutilisable pour
qui la refuse. Le clustering vit **au-dessus**, il n'est jamais une condition.

*(Jay, 2026-08-17 : « cela ne doit pas constituer un élément essentiel de
ping ».)*

### 5.4 Les capacités voyagent dans le TUNNEL CHIFFRÉ, jamais dans l'annonce

Deux raisons, et la seconde est la vraie :

1. l'annonce fait **31 octets** et on en occupe **28** — il n'y a pas la place ;
2. « cet appareil a l'UWB » diffusé en clair est une **empreinte d'appareil
   stable**. Tout l'identifiant rotatif existe pour qu'un observateur passif ne
   puisse pas suivre quelqu'un d'un créneau à l'autre. Un masque de capacités
   **partitionne la population et rend l'ID rotatif traçable** — il défait
   silencieusement la propriété qu'il accompagne.

---

## 6. BLE ou Wi-Fi pour les messages ?

*Question de Jay, 2026-08-17 : « le Wi-Fi Direct on peut l'utiliser pour les
messages ? Peut-être que cela sera plus fiable que le BLE ? »*

### D'abord : ce qui était en panne n'était pas le BLE

Les **trois** causes de messages fantômes trouvées les 16 et 17 août sont des
défauts de **notre** machine à états :

1. un canal établi écrasé par un second lien ;
2. une fusion d'adresses qui abandonnait un lien sans le fermer ;
3. `prune()` qui détruisait une session vivante parce qu'une annonce n'avait pas
   été entendue.

**Aucune n'aurait été corrigée par un changement de transport** — elles auraient
été reproduites à l'identique par-dessus le Wi-Fi, plus une couche neuve à
déboguer. Il faut le dire clairement pour ne pas tirer la mauvaise conclusion
d'un mauvais souvenir.

### Ensuite : « fiable » veut dire deux choses opposées

| | BLE GATT | Wi-Fi Direct |
|---|---|---|
| Débit | faible — quelques dizaines de ko/s | des Mo/s |
| **Délai d'établissement** | ~1 s | **plusieurs secondes** (formation de groupe, parfois une boîte de dialogue système) |
| **Pairs simultanés** | **plusieurs liens en parallèle** | **un groupe** — être dans plusieurs est en pratique impossible |
| **Arrière-plan** | ✅ notre service de premier plan tourne app fermée | **fragile**, et ce n'est pas ce pour quoi c'est fait |
| **Effet sur le Wi-Fi de l'utilisateur** | aucun | peut **dégrader ou couper la connexion internet** (chaîne radio unique sur beaucoup d'appareils) |
| Batterie | très faible | élevée |
| Découverte propre | ✅ | lente et peu fiable — d'où le motif standard BLE + Wi-Fi |

**Le point décisif pour NeoVibe est la ligne « pairs simultanés ».** Un bus avec
huit utilisateurs, une cour de récréation, une salle de classe : c'est
exactement notre cas d'usage, et c'est celui où le Wi-Fi Direct est le plus
mauvais. Le BLE tient plusieurs liens GATT en parallèle sans rien demander.

Le second point décisif est l'arrière-plan : **toute l'architecture du ping
repose sur un service qui survit à la fermeture de l'app**. Ça marche en BLE.
Ça ne marche pas en Wi-Fi Direct.

### Décision

**Les messages texte restent en BLE.** Le Wi-Fi serait une régression de
fiabilité sur ce chemin, pas un progrès.

**Les médias passeront en Wi-Fi**, et c'est le seul chemin possible : une vibe
ne passe pas par le BLE dans un temps acceptable. C'était déjà la décision du
projet (RAPPELS chantier #3) — elle est maintenant motivée, et pas seulement
héritée.

**Et le Wi-Fi s'ouvre à la demande, pour un transfert, puis se referme.** Il
n'est jamais le lien permanent. Le lien permanent est BLE, et c'est lui qui
porte le contrôle.

⚠️ **Wi-Fi Aware plutôt que Wi-Fi Direct, quand il est là.** Pas de formation de
groupe, plusieurs pairs, conçu pour le voisinage. Mais son support matériel est
bien plus rare — d'où les sondes ajoutées le 2026-08-17. **On saura au prochain
relevé de Jay**, au lieu de supposer.

⚠️ **Sur iOS, `MultipeerConnectivity`** joue ce rôle, et choisit lui-même entre
Bluetooth et Wi-Fi. Il ne parle pas à Android : le lien **Android ↔ iPhone
restera en BLE**. Ce n'est pas un repli marginal — pour une app dont le
mécanisme d'entrée est la rencontre physique, c'est un cas courant. Il doit être
**conçu**, pas découvert : concrètement, l'envoi d'une vibe en pair-à-pair doit
avoir un comportement défini quand seul le BLE est disponible (refus explicite
et proposition de passer par le serveur, plutôt qu'un transfert de dix minutes).

---

## 7. Le clustering côté serveur

*Décision de Jay, 2026-08-17 : GPS, côté serveur.*

La promesse « ce qui se passe sur NeoVibe reste sur NeoVibe » porte sur ce qui
se **partage** — anti-capture, pas d'enregistrement en galerie, écosystème
fermé, suppression 24 h. **Ce n'est pas une promesse sur la télémétrie de
position**, et le clustering serveur ne la contredit pas.

### Ce qui se décide maintenant, et coûte cher plus tard

Deux versions, identiques au démarrage, très différentes dans un an :

| | Ce que le serveur garde |
|---|---|
| ❌ | les **traces** — donc un historique de déplacements par utilisateur |
| ✅ | les points bruts quelques heures, puis **l'appartenance au cluster seulement** |

La seconde répond exactement aux mêmes questions — qui est dans le bus, qui est
à l'école — pour infiniment moins cher. **Un cluster est éphémère par nature**
(un trajet, une journée de cours) : ça tombe dans la culture TTL 24 h du projet
sans rien inventer.

### Un point à cadrer une fois, à la conception

**Les groupes scolaires sont une cible explicite du produit.** Position + mineurs
est la combinaison la plus encadrée qui existe (consentement explicite, durée de
conservation bornée, minimisation). Ce n'est pas un frein — c'est simplement
beaucoup moins cher décidé maintenant que rétro-adapté.

### Ce qui rend le cluster crédible

La distance seule ne suffit pas : quelqu'un sur le trottoir peut être à 1,5 m
d'un passager du bus. Ce qui distingue les deux est la **corrélation dans le
temps** — vitesses voisines, accélérations communes, distances relatives
stables, sur plusieurs minutes. C'est la bonne idée du modèle, et c'est aussi ce
qui le rend coûteux en batterie.

⚠️ **La consommation du seul scan BLE n'est toujours pas mesurée** (RAPPELS #3).
GPS + IMU en continu s'ajouteraient par-dessus. À mesurer **avant** de
généraliser, pas après.

---

## 8. Ce qu'on fait maintenant

### Immédiatement — sans regret, et sans rien préjuger

**`method` et `confidence` sur `DistanceEstimate`.** Le modèle par paliers
*exige* que la distance porte sa provenance ; sans ce champ, aucun palier n'est
représentable. On a déjà `min/max`, `band`, `trend`, `calibrated` — il manque la
**méthode** et une **confiance normalisée**.

Aujourd'hui `method` n'a qu'une valeur possible (`bleRssi`). C'est précisément
ce qui rend l'arrivée de l'UWB **additive au lieu de cassante** : dix lignes
maintenant, un chantier évité plus tard.

### Les déclencheurs — ce qui ouvre chaque chantier

| Chantier | On l'ouvre quand… |
|---|---|
| Interface `SpatialRanging` + implémentations | un appareil de test porte l'UWB **ou** le Wi-Fi RTT |
| Négociation de palier | il existe **au moins deux** technologies de ranging sur le parc |
| Transport Wi-Fi | le chantier « médias en conversation ping » démarre (RAPPELS #3) — **après** avoir lu les sondes `wifiAware` / `wifiDirect` |
| Clustering serveur | décision produit de Jay sur la rétention (§7) |
| Channel Sounding | un appareil Bluetooth 6.0 entre dans le parc de test |

### Ce qu'on ne fait PAS

- pas de moteur de négociation à une seule branche ;
- pas de capacités dans l'annonce BLE ;
- pas de bascule des messages texte vers le Wi-Fi ;
- pas de direction affichée tant qu'on ne peut pas la mesurer.

---

## 9. Ce que cette note ne tranche pas

1. **La rétention GPS** (§7) — décision de Jay.
2. **Le seuil de « portée réelle »** pour le chat P2P : à partir de quelle
   distance, et de quelle confiance, quelqu'un cesse d'être affiché ? Ça se
   règle avec des relevés, pas à la table.
3. **Le comportement Android ↔ iPhone pour l'envoi d'une vibe** (§6) — il faut
   choisir entre refus explicite et bascule serveur.
4. **Wi-Fi Aware ou Wi-Fi Direct** — attend les sondes du prochain rapport.
