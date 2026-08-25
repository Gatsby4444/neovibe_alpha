# Proximité v2 — le GPS oriente, le BLE prouve

*Architecture décidée par Jay le 2026-08-25, après le premier test à deux
appareils.*

---

## 1. Le renversement

> « On a voulu utiliser le BLE comme techno de base pour tout. En réalité le BLE
> n'est pas nécessaire pour une grosse partie de ce qu'on veut faire. Si on
> l'utilise non pas comme techno de base mais comme **outil de vérification**,
> alors on supprime la quasi-totalité des problèmes qu'on essaie de régler. »
> — Jay, 2026-08-25

Le premier test sur appareils réels a montré exactement ça. Le BLE est **mauvais
à tout ce qu'on lui demandait, et excellent à la seule chose qu'on ne lui
demandait pas** :

| Ce qu'on lui demandait | Résultat mesuré le 2026-08-25 |
|---|---|
| transporter des messages | `trames applicatives livrées : 0` |
| découvrir des inconnus | ne passe pas l'échelle (une connexion par personne) |
| tenir des sessions | mortes à 30 s, cycle infini |
| **prouver une co-présence** | ✅ **`encounters` : mimi ↔ Charles, `mutual_sighting`, 19:39** |

Sa force unique tient en une phrase : **une portée de 10 mètres ne se falsifie
pas.** Pas de VPN, pas de position déclarée, pas de rejeu à distance. Tout le
reste, Internet le fait mieux.

**Le principe directeur de cette architecture :**

> **Le GPS dit *où chercher*. Le BLE dit *qui est vraiment là*.
> Le serveur fait le lien, sans jamais savoir qui est à 20 m de qui.**

---

## 2. Les deux fonctionnalités, et elles seules

Tout ce document ne sert qu'à ces deux-là. Ce qui n'y contribue pas n'a pas à
exister.

**① Découvrir les profils des gens à ~20 m**, leur parler dans une messagerie de
proximité restreinte, et jouer à des mini-jeux — **uniquement** avec les gens à
portée réelle.

**② Pour les amis** : savoir si on s'est croisés aujourd'hui, distinguer un
**croisement** (on est passés à portée) d'un **moment passé ensemble** (on est
restés).

---

## 3. Pourquoi le GPS ne peut pas faire les 20 m

Constat de plateforme, à connaître avant toute discussion :

| Condition | Précision horizontale réelle |
|---|---|
| Plein ciel, téléphone récent bi-fréquence (L1+L5) | 4 à 10 m |
| Rue en ville | 10 à 30 m |
| Entre immeubles | 50 m et plus |
| **En intérieur** | GPS souvent absent → repli WiFi/cellule : **20 à 100 m** |

À 20 m de seuil, **le signal est sous le bruit** :

- deux personnes **côte à côte** peuvent être rapportées à 30 m → invisibles
  l'une pour l'autre ;
- deux personnes **à 80 m** peuvent être rapportées à 15 m → un inconnu d'un
  autre bâtiment apparaît comme présent ;
- **en intérieur**, deux téléphones sur le même point WiFi se voient à 0 m —
  même à des étages différents.

⚠️ **Le GNSS bi-fréquence ne sauve pas ce cas** : il ne traverse pas un toit, il
n'est pas sur tous les appareils, et depuis Android 12 l'utilisateur peut
n'accorder que la position **approximative** (~3 km). Même au mieux, 5 m
d'erreur de chaque côté font **10 m d'erreur relative** contre un seuil de 20 —
une marge de 50 %.

**Conséquence de conception, et c'est une force** : on ne demande au GPS qu'une
**cellule d'environ 1 km**. Même le pire repli WiFi la donne juste. Cette
architecture est donc **indifférente à la qualité du GPS**, ce qu'aucune
variante « GPS précis » ne peut être.

---

## 4. Fonctionnalité ① — le ping public

### 4.1 La chaîne, en cinq temps

```
1. J'ouvre le Ping. Mon téléphone publie sa CELLULE (~1 km) et son JETON public
   du créneau courant.                                    [premier plan, GPS]
2. Le serveur me rend les JETONS des autres pings actifs de ma cellule et des
   8 cellules voisines. ⚠️ Des jetons OPAQUES — ni profils, ni identifiants.
3. Mon téléphone ÉCOUTE le BLE pour ces jetons. Aucune connexion.
4. Un jeton entendu = cette personne est à portée BLE — ~20 m, physiquement.
   Je dépose une CONFIRMATION au serveur.
5. Le serveur ne révèle les profils que si la confirmation est MUTUELLE.
```

### 4.2 Pourquoi le serveur ne rend que des jetons opaques

Si le serveur rendait les profils de ma cellule, **il suffirait d'être dans le
quartier pour voir tout le monde** — et la thèse du produit (la présence
physique est la barrière) tomberait au premier client modifié.

En ne rendant que des jetons, la liste est **inexploitable sans être là** : elle
ne dit ni qui, ni combien de personnes distinctes, ni où. C'est une liste de
choses à écouter, pas une liste de gens.

### 4.3 La réciprocité — la même règle que pour les amis

⚠️ **Un profil n'est révélé que si les DEUX se sont entendus.**

C'est exactement la propriété du croisement d'amis (`RAPPELS.md` #55), appliquée
aux inconnus : **on ne peut pas observer sans être observable.** Écouter sans
émettre ne donne rien — pas un profil, pas une conversation.

Ce n'est pas une règle appliquée quelque part : c'est la seule façon dont une
ligne peut naître par ce chemin.

### 4.4 Pourquoi il n'y a plus de mur d'échelle

Le mur de la v1 venait d'une seule chose : le jeton public étant opaque,
**savoir qui c'est exigeait d'ouvrir une connexion**. Une connexion par
personne, contre un plafond d'environ 7 simultanées sur Android.

Ici, la résolution d'identité est faite par le serveur. Le BLE ne fait plus que
**confirmer une distance**, et pour ça il lui suffit d'**écouter** — opération
passive, un-vers-tous, qui monte à des centaines d'émetteurs sans coût
supplémentaire.

**Zéro connexion GATT dans tout le ping public.**

### 4.5 La messagerie de proximité

Elle passe par le serveur, et c'est une messagerie **distincte** de celle des
amis — objets distincts, table distincte, règles distinctes (règle 2 de
`CLAUDE.md` : deux objets qui n'obéissent pas aux mêmes règles ne partagent ni
stockage ni chemin).

Elle n'existe qu'entre deux personnes dont le serveur a constaté la proximité
**mutuelle**, et elle s'éteint avec elle.

---

## 5. Fonctionnalité ② — les amis : croisement et moment partagé

### 5.1 Ce qui ne change pas — et c'est le plus important

**Cette moitié fonctionne déjà, et c'est prouvé en base.** Le secret par paire
Diffie-Hellman, le jeton par créneau, la reconnaissance native app fermée, les
constats mutuels, la réciprocité serveur : **on n'y touche pas.**

⚠️ **Et elle ne demande AUCUNE permission de localisation sur Android 12+.**

### 5.2 Le GPS n'y entre pas, et voici pourquoi

Le déclencheur GPS à 500 m proposé initialement n'apporterait **qu'une économie
de batterie** — savoir quand allumer la radio. Il se paierait :

- **« Autoriser la localisation tout le temps »** — l'invite la plus dissuasive
  d'Android, sur une app dont la thèse est la confiance ;
- une **déclaration Google Play** avec démonstration vidéo, plusieurs semaines,
  approbation non garantie pour une fonction sociale ;
- une **trace de positions continues** côté serveur, la donnée la plus sensible
  qu'une app sociale puisse détenir ;
- une fragilité réelle sur MIUI, qui tue agressivement les services de fond.

**Décision : non.** Si la consommation devient un problème **mesuré**, on
rouvrira — avec le chiffre en main, pas avant.

### 5.3 Croisement contre moment partagé

Un **croisement** existe déjà : deux constats mutuels au même créneau.

Un **moment partagé** est une notion de durée, et elle se mesure sur des
**plages continues**, jamais sur un total journalier — *quarante rencontres
d'une minute ne sont pas quarante minutes ensemble.*

Règles proposées (à trancher par Jay) :

| Question | Proposition | Pourquoi |
|---|---|---|
| Qu'est-ce qu'une plage ? | des constats mutuels successifs, trous de moins de **5 min** fusionnés | un passage derrière un mur ne doit pas couper la plage en deux |
| Quelle distance compte ? | la **bande proche** (`ProximityBand`), pas la simple portée | « à portée » et « ensemble » ne sont pas le même fait |
| Quel seuil pour un moment ? | **40 min** cumulées sur des plages d'au moins **10 min** | proposition de Jay pour le seuil ; le plancher par plage évite qu'un total s'accumule en miettes |
| Un constat unilatéral prolonge-t-il une plage ? | **oui, si la plage est déjà établie mutuellement** | sinon une batterie vide côté ami tronque la mesure, et injustement |

⚠️ **Ce dernier point est un arbitrage, pas une évidence.** Il assouplit la
réciprocité *à l'intérieur* d'une plage déjà prouvée — jamais pour l'ouvrir.

---

## 6. Ce que ça supprime

| Supprimé | Lignes | Ce que ça emporte |
|---|---|---|
| Connexions GATT et gestion de liens | `peer_link.dart`, une partie de `peer_network.dart` | le mur d'échelle, le plafond de 7 |
| Canal chiffré BLE | `secure_channel.dart` (309) | les messages fantômes, les sessions reconstruites |
| Messagerie BLE | `proximity_protocol.dart`, une partie de `ping_chat_screen.dart` | `trames livrées : 0` |
| Sessions par adresse | une partie de `peer_session.dart` | **#62** (mort de faim à 30 s), les « 13 détections » |
| Identifiant public **émis** en rotation | une partie du plan d'annonces | **#64** (redémarrage à 400 ms, bandeau clignotant) |

⚠️ **Rien n'est supprimé avant que le nouveau chemin soit éprouvé sur appareil.**
Règle 8 : les deux sens se relèvent avant de couper. Tout est dans git de toute
façon.

## 7. Ce que ça garde

- **Le secret par paire Diffie-Hellman** et le jeton par créneau — le cœur.
- **La reconnaissance native app fermée** (`SightingBook`) — indispensable au
  croisement, et déjà testée.
- **Les constats mutuels et la réciprocité serveur** — la propriété anti-traque.
- **La purge** des constats à 48 h et des croisements à 24 h.
- **Le format d'annonce v4** avec son octet de type : il devient encore plus
  pertinent, public et privé n'ayant plus du tout le même rôle.

---

## 8. Séparation des modules — règle de Jay du 2026-08-25

| Module | Rôle | Ne fait JAMAIS |
|---|---|---|
| **Acquisition GPS** | publie une cellule grossière, fidèlement | décider qui est proche, ni afficher |
| **Acquisition BLE** | publie ce qu'elle entend, avec son type | résoudre une identité |
| **Serveur** | apparie les jetons, garde la réciprocité | connaître une position fine |
| **Vues** | décident quoi montrer, à leur rythme | parler au réseau ou à la radio |

**Le test** : pour ajouter un champ à l'écran Ping, dois-je toucher au code qui
parle au GPS, à la radio ou au serveur ? Si oui, la séparation n'est pas faite.

---

## 9. Ce qui reste à trancher

1. **Le rayon de la cellule** — 1 km proposé. Plus fin fuite davantage ; plus
   large allonge la liste de jetons.
2. **La cadence de publication** de la cellule — 60 s proposées tant que le Ping
   est ouvert.
3. **Le plafond de la liste** de jetons rendue par le serveur.
4. **Les règles du moment partagé** (§5.3).
5. **La rétention** des confirmations de proximité côté serveur.
