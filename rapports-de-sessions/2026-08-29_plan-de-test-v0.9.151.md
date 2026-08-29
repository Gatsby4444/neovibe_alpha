# Protocole de test — v0.9.151

⚠️ **Installe la v0.9.151 sur les DEUX appareils avant de commencer.**

> 🔴 **Les versions 0.9.148 à 0.9.150 sont périmées.** La 148 était mal
> signée ; la 150 corrigeait la moitié Dart du défaut que tu as trouvé, mais il
> en restait une moitié **native** — c'est exactement ce que ton test E a
> montré.

## 🆕 Ce qu'il reste à faire sur cette version

Tu as déjà passé A, B et C sur la 0.9.150, et **rien dans la 0.9.151 ne les
touche**. Il ne reste donc que :

| | Test | Vous êtes | Durée |
|---|---|---|---|
| **E** | 🔴 L'interrupteur coupe des deux côtés — **à refaire** | 🟢 amis | 6 min |
| **D** | La nuit | 🟢 amis | — |

⚠️ **Refais quand même l'étape 0**, pour repartir d'un journal propre.

## Ce qui est déjà validé, et qu'on ne refait pas

- ✅ le **doublon** de mimi a disparu *(confirmé par toi, hier soir)* ;
- ✅ `incidents consignés` retombé à **0** et **1**, contre 318 et 485 avant ;
- ✅ la localisation : **même carreau**, ± 33 m et ± 36 m, en `best` ;
- ✅ le croisement d'amis aboutit, un ami accepté est reconnu en 2 secondes ;
- ✅ les deux interrupteurs sont séparés **à l'écran**.

⚠️ **Ce qui N'EST PLUS validé** : « les deux interrupteurs sont bien séparés »
figurait ici hier. C'était faux pour l'ÉMISSION — c'est le défaut que tu as
trouvé, et c'est le test E.

## L'état de départ, relevé en base

| | |
|---|---|
| Charles et mimi | **amis** (depuis hier 17:34) |
| Blocages | aucun |
| Demandes en attente | aucune |
| Croisements enregistrés | 0 — *effacés par le retrait d'ami d'hier, c'est normal* |

⚠️ **Fais les tests DANS L'ORDRE.** Chacun laisse l'état dont le suivant a
besoin, et **c'est le test lui-même qui fait passer d'un état à l'autre** — tu
n'as jamais à préparer l'état à la main.

## Amis ou inconnus : le récapitulatif

| | Test | Vous êtes | Ce qui change l'état |
|---|---|---|---|
| **0** | Préparer | 🟢 **amis** | — |
| **A** | Le ping sans ouvrir l'onglet | 🟢 **amis** | — |
| **B1** | Redevenir inconnus | 🟢 amis → 🔵 **inconnus** | Charles retire l'ami |
| **B2** | Ouvrir un fil avant de bloquer | 🔵 **inconnus** | — |
| **B3** | mimi bloque, on attend | 🔵 **inconnus** + bloqués | mimi bloque |
| **B4** | Débloquer | 🔵 **inconnus** | mimi débloque |
| **C** | Redevenir amis | 🔵 inconnus → 🟢 **amis** | vous vous ajoutez |
| **E** | 🔴 L'interrupteur coupe des deux côtés | 🟢 **amis** | — |
| **D** | La nuit | 🟢 **amis** | — |
| — | *Éloignement (reporté)* | 🔵 **inconnus** | — |

⚠️ **Pourquoi B a besoin d'inconnus.** Le bouton « Écrire » et le ticket de
proximité n'existent **qu'entre inconnus** : entre amis, on passe par la
messagerie normale, qui ne demande aucune proximité. Faire B en amis ne
testerait rien du tout.

⚠️ **Pourquoi A et D ont besoin d'amis.** Les deux vérifient le **croisement
d'amis** — la partie qui doit marcher app fermée, sans réseau. C'est une autre
moitié du produit que le ping des inconnus, et elle a son propre interrupteur.

---

# Étape 0 — Préparer *(2 minutes)*

Sur **les deux** appareils :

1. Installer la **v0.9.151**.
2. Réglages → Sécurité et confidentialité → **« Croiser mes amis » ALLUMÉ**.
3. Écran Ping → **« Visible à proximité » ALLUMÉ**.
4. Réglages → Développeur → **effacer le journal** (« nouveau test »).
5. Côte à côte, laissez tourner **une minute** sans rien toucher.

---

# Test A — Le ping marche sans ouvrir l'onglet Ping *(4 minutes)*

> 🟢 **Vous êtes AMIS pour ce test.**

**Ce qu'on vérifie :** avant la v0.9.146, rien ne démarrait tant que tu n'avais
pas ouvert cet onglet **une fois**. Comme tu l'ouvrais toujours en premier, le
trou ne pouvait pas se voir.

1. Sur les deux : **balaie l'app** de la liste des applis récentes.
2. Rouvre-la. 🔴 **NE VA PAS sur l'onglet Ping.** Reste sur l'accueil.
3. Posez les deux téléphones côte à côte, **deux minutes**, sans y toucher.
4. **Ensuite seulement**, ouvre l'onglet Ping.

| ✅ | ❌ |
|---|---|
| l'autre est **déjà là, avec une distance**, dès l'ouverture | il faut attendre que ça « démarre » |
| aucun bandeau « Démarrage… » | |

---

# Test B 🔴 — Le blocage, proprement *(10 minutes)*

> 🔵 **Ce test commence en amis et vous fait passer INCONNUS** à l'étape
> B1. Tout le reste de B se joue en inconnus.

**Le test le plus important de la série**, et celui qui a été bâclé hier : il
avait duré 22 secondes.

## ⚠️ D'abord, pourquoi ça prend du temps

Le blocage doit couper **les deux sens**, et les deux ne vont pas à la même
vitesse :

| | Chez qui | Par quel chemin | Délai attendu |
|---|---|---|---|
| **Le sens facile** | mimi (celle qui bloque) | son propre téléphone | immédiat |
| **Le sens difficile** | Charles (le bloqué) | le **serveur** doit cesser de le lui montrer | jusqu'à **une minute** |

Vingt secondes ne prouvent donc rien : **ni que ça marche, ni que ça ne marche
pas.** C'est le seul but des deux minutes d'attente.

## B1 — Redevenir inconnus *(2 min)*

1. Sur le téléphone de **Charles** : profil de mimi → **retirer l'ami**.
2. Attendez de vous voir apparaître dans **« Autour de toi »** (10 à 20 s).

| ✅ | ❌ |
|---|---|
| chacun voit l'autre dans « Autour de toi », avec une distance | personne n'apparaît |

🔴 **Si personne n'apparaît, arrête-toi ici et dis-le-moi** : les tests suivants
n'auraient aucun sens.

## B2 — Ouvrir un fil de discussion AVANT de bloquer *(1 min)*

**C'est l'étape neuve, et c'est elle qui teste le correctif du jour.**

3. Sur le téléphone de **Charles** : sur la tuile de mimi, appuie sur
   **« Écrire »**. Envoie **un** message.
4. **Reste dans ce fil de discussion**, ne quitte pas l'écran.

## B3 — mimi bloque, et on ATTEND *(3 min)*

5. Sur le téléphone de **mimi** : profil de Charles → **Bloquer**.
6. 🔴 **Attendez DEUX MINUTES**, côte à côte, sans toucher aux écrans.

| ✅ | ❌ |
|---|---|
| Charles a disparu de l'écran de mimi | |
| 🔴 **mimi a disparu AUSSI de l'écran de Charles** | mimi reste visible chez Charles |
| le compteur « N personnes ont le ping actif » est à **0** des deux côtés | il reste à 1 |

7. **Sur le téléphone de Charles, toujours dans le fil** : essaie d'envoyer un
   second message.

| ✅ | ❌ |
|---|---|
| l'envoi **échoue**, ou le champ devient inerte | le message part comme si de rien n'était |

> **Pourquoi cette étape existe.** Jusqu'à ce matin, le blocage supprimait
> l'amitié et les demandes en attente, mais laissait en place le **ticket**
> *« ces deux-là étaient côte à côte »* — celui qui autorise le bouton
> « Écrire ». Une personne qu'on venait de bloquer gardait donc **trois
> minutes** de fil ouvert, et **dix minutes** pour envoyer une demande d'ami.
> Le ticket est maintenant déchiré en même temps que le reste.

## B4 — Débloquer *(2 min)*

8. mimi débloque Charles.
9. Attendez **une minute**, côte à côte.

| ✅ | ❌ |
|---|---|
| vous vous revoyez dans « Autour de toi » | il faut redémarrer l'app |

⚠️ **Il est normal d'attendre 1 à 2 minutes de plus** avant que « Écrire »
redevienne possible : le ticket a été déchiré, il faut vous revoir pour en
refabriquer un. Ce n'est pas un défaut, c'est le correctif.

> ⚠️ **Chiffre corrigé après vérification dans le code** : j'avais d'abord écrit
> « 10 à 20 secondes ». Le téléphone n'envoie ce qu'il a entendu que **toutes
> les 60 secondes** (`PingBeaconService.flushEvery`), et il faut que **les DEUX**
> l'aient fait pour que le ticket renaisse. Compter deux minutes.

## ⚠️ Ce que le déblocage rend — et ce qu'il ne rend PAS

Relevé en base, pas déduit : `unblock_user` ne fait **qu'une** chose, effacer la
ligne de blocage. Rien d'autre n'est restauré.

| | Après le déblocage | Délai |
|---|---|---|
| se revoir dans « Autour de toi » | ✅ **revient tout seul** | ~1 min |
| le **ticket** de proximité (bouton « Écrire ») | ✅ **se refabrique tout seul**, en vous revoyant | 1 à 2 min |
| l'**amitié** | ❌ **ne revient pas** — le blocage l'avait supprimée | il faut se redemander |
| le **croisement** et les constats de la paire | ❌ partis avec l'amitié | — |
| les **demandes en attente** | ❌ supprimées par le blocage | — |
| les **anciens messages** du fil | ✅ toujours lisibles | jusqu'à leur expiration (24 h) |

⚠️ **Limite connue, et assumée** : pendant le blocage, la personne bloquée ne
peut plus **écrire** dans le fil, mais elle peut encore **relire** ce qui y avait
déjà été envoyé. Bloquer quelqu'un ne reprend pas les messages qu'on lui a
déjà envoyés — c'est le comportement de toutes les messageries, mais autant que
ce soit dit.

⚠️ **C'est pour ça que le test C existe.** À la fin de B vous êtes **inconnus**,
pas amis : le blocage a emporté l'amitié, et le déblocage ne la rend pas.

---

# Test C — Redevenir amis, et le compteur *(3 minutes)*

> 🔵 → 🟢 **Vous commencez inconnus, vous finissez amis.**

1. Côte à côte : demandez-vous en ami, et acceptez.
2. Regarde ton **compteur d'amis** sur ton profil.

| ✅ | ❌ |
|---|---|
| l'autre apparaît **avec une distance en moins d'une minute** | il faut redémarrer l'app |
| le compteur monte **tout de suite**, des deux côtés | il faut redémarrer l'app |
| l'autre **quitte** « Autour de toi », **sans doublon** | il reste dans les deux listes |

---

# Test E 🔴 — L'interrupteur coupe des DEUX côtés *(6 minutes)*

> 🟢 **Vous êtes AMIS pour ce test**, les deux « Visible à proximité » allumés.

**C'est le test que tu as fait échouer hier, et il a trouvé un vrai défaut.**

Ce que tu avais observé : tu éteins « Croiser mes amis », ton écran cesse
d'afficher mimi — et la tablette continue de te voir, distance à jour. Couper
puis rallumer le ping te faisait disparaître.

**La cause était native** : ton téléphone a **deux façons d'être en l'air**, et
en changeant de plan il en démarrait une nouvelle **sans raccrocher
l'ancienne**. L'ancien plan, jeton d'ami compris, restait en l'air. Couper le
ping arrêtait tout, d'où la différence.

## E1 — Charles coupe *(3 min)*

1. Sur **les deux**, vérifiez que vous vous voyez avec une distance.
2. Sur le **téléphone** (Charles) : Réglages → Sécurité et confidentialité →
   **éteindre « Croiser mes amis »**. 🔴 **Laisser « Visible à proximité »
   ALLUMÉ, et NE PAS y toucher** — c'est tout l'intérêt du test.
3. Attendre **deux minutes**, côte à côte, sans toucher aux écrans.

| ✅ | ❌ |
|---|---|
| chez **Charles** : « le croisement de tes amis est coupé » | |
| 🔴 chez **mimi** : **Charles a DISPARU** de ses amis à portée | Charles reste affiché avec une distance |

> 🔴 **C'est la deuxième ligne qui compte, et elle seule.** La première était
> déjà vraie hier.

## E2 — La ligne à lire dans le diagnostic *(1 min)*

4. Sur le **téléphone** : Réglages → Développeur → diagnostic de proximité.
   Cherche les deux lignes :

| Ce que tu lis | Ce que ça veut dire |
|---|---|
| `advertMode : cycle` **et** `advertSetsOnAir : 0` | ✅ **parfait** — une seule chose en l'air |
| `advertMode : cycle` **et** `advertSetsOnAir : 1` ou plus | 🔴 **le défaut est toujours là** — l'ancien plan n'a pas été raccroché |
| `advertMode : parallele` | normal si tu n'as pas encore coupé |

⚠️ **Cette ligne est neuve, et elle existe à cause de ce test.** Hier, le
diagnostic disait « cycle » — ce qui était **vrai** — sans dire que l'ancien
mode était resté en l'air à côté. Rien ne pouvait le montrer.

## E3 — Rallumer *(1 min)*

5. **Rallumer** « Croiser mes amis » sur le téléphone. Attendre **une minute**.

| ✅ | ❌ |
|---|---|
| vous vous revoyez **des deux côtés** | il faut redémarrer l'app ou le ping |

## E4 — L'autre sens *(1 min, important)*

6. Refaire E1 **à l'envers** : c'est **mimi** qui éteint « Croiser mes amis »,
   et c'est **Charles** qui ne doit plus la voir.

⚠️ **Ne saute pas cette étape.** Les deux appareils n'ont ni le même Android ni
la même puce radio (`advertMode` vaut `parallele` sur la tablette et `cycle` sur
le téléphone), et c'est précisément ce chemin-là qui était cassé.

7. Rallume, et vérifie que vous vous revoyez.

---

# Test D — La nuit *(à lancer en dernier, avant de dormir)*

> 🟢 **Vous êtes AMIS pour ce test**, et c'est indispensable : la nuit
> teste le croisement d'amis.

1. Vous êtes **amis**, les deux interrupteurs allumés des deux côtés.
2. Les deux téléphones **côte à côte**, **apps fermées avec le bouton
   accueil** — 🔴 **PAS balayées de la liste des récentes**.
3. **Toute la nuit.**
4. Au réveil, **avant de rouvrir l'app** : la notification NeoVibe est-elle
   toujours dans la barre ?
5. Rouvre l'app, et envoie-moi le diagnostic des deux appareils.

## ⚠️ Ce qu'il ne faut surtout pas faire

> **N'utilise pas « Forcer l'arrêt » dans les réglages Android.**

Quand Android range l'app **de lui-même**, il la relance ensuite — c'est
exactement ce qu'on teste. Quand **toi** tu forces l'arrêt, Android ne la relance
**jamais** : tu conclurais à un échec alors que le test n'aurait pas eu lieu.

## 🆕 Ce que la nuit teste EN PLUS, cette fois

Le correctif du cri public. Au réveil, dans le diagnostic, deux nouvelles
lignes :

| Ligne | Ce qu'elle doit dire |
|---|---|
| `publicMuted` | **`true`** si l'app est restée rangée plus de 5 minutes — le téléphone a cessé tout seul de crier son identifiant public |
| `publicHeartbeatAgeMillis` | depuis combien de temps l'app n'a plus donné signe de vie |

⚠️ **`publicMuted: true` au réveil est le résultat ATTENDU, pas une panne.** Ça
prouve que le téléphone a arrêté de crier un identifiant que plus personne ne
pouvait traduire. Le croisement d'**amis**, lui, doit avoir continué — c'est ce
que le reste de la nuit vérifie.

---

# Reporté : le test d'éloignement

> 🔵 **À faire en INCONNUS** : le fil de proximité n'existe qu'entre
> inconnus.

Il demande de **sortir de portée d'une trentaine de mètres** — une autre pièce ne
suffit pas — et d'attendre **deux minutes** sans toucher l'écran, pour voir le
fil de proximité se fermer tout seul. À faire quand tu pourras sortir.

---

# Ce qu'il me faut à la fin

1. **le diagnostic des DEUX appareils** ;
2. **à quel test ça a cassé**, si ça casse, et **ce que tu as vu à l'écran** ;
3. **l'heure de début et de fin.**

# Trois lignes à regarder toi-même dans le diagnostic

| Ligne | Ce qu'elle doit dire |
|---|---|
| `incidents consignés` | **0 ou 1**. À 300, le journal se sature et chasse tout le reste. |
| `carreau` | doit finir par **`· best`**, précision sous 60 m. |
| `publicMuted` | **`true` au réveil** après une nuit rangée — c'est le nouveau correctif qui travaille. |
| 🆕 `advertSetsOnAir` | **0** quand `advertMode` vaut `cycle`. Sinon, l'ancien plan est resté en l'air. |

---

# Connu et non corrigé — ne le prends pas pour un bug

| | |
|---|---|
| après un déblocage, il faut se revoir 1 à 2 min avant que « Écrire » revienne | c'est le correctif, pas un défaut |
| débloquer ne rend PAS l'amitié : elle a été supprimée par le blocage | voulu |
| les anciens messages du fil restent lisibles (24 h de TTL) ; on ne peut plus y écrire | limite connue |
| retirer un ami efface le croisement et les constats de la paire | voulu depuis le 2026-08-28 |
