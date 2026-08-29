# Les paliers d'amitié — les règles exactes

*Livrés le 2026-08-30 (v0.9.156). Document de référence : il dit ce que le code
fait **aujourd'hui**, avec les chiffres exacts et l'endroit où chacun se change.*

> ⚠️ **Ce fichier décrit un état daté.** Comme tout document, il peut se périmer.
> La source de vérité reste la base et le code — les chemins sont donnés à
> chaque ligne pour pouvoir vérifier en dix secondes.

---

## 1. En une phrase

**On monte de palier en se croisant pour de vrai, et on redescend en arrêtant.**
Personne ne range ses amis à la main, et personne ne peut tricher : il faut que
les deux téléphones se soient vus.

---

## 2. Les trois paliers d'aujourd'hui

| Palier | Nom affiché | Anneau autour de la photo |
|---|---|---|
| `friend` | **Ami** | aucun |
| `close` | **Proche** | accent chaud → accent d'action |
| `inner` | **Inséparable** | le dégradé complet de l'identité |

⚠️ **Le palier le plus bas n'a pas d'anneau, exprès.** Si tout le monde en porte
un, l'anneau ne distingue plus personne.

⚠️ **Les trois noms sont provisoires.** Jay ne les a pas choisis (2026-08-30) :
il envisage **un badge plutôt que des mots**, et **deux paliers intermédiaires
en plus**. Voir §7.

---

## 3. Les quatre chiffres qui décident de tout

| Ce que c'est | Valeur | Où ça se change |
|---|---|---|
| Fenêtre de comptage | **30 jours** | `private.meeting_window_days()` |
| Pour devenir **Proche** | **5 jours** de croisement dans la fenêtre | `private.tier_close_days()` |
| Pour devenir **Inséparable** | **15 jours** dans la fenêtre | `private.tier_inner_days()` |
| Tolérance de la **série** | **2 jours** manqués d'affilée | `private.streak_tolerance_days()` |

🔴 **Ces quatre nombres sont des paris, pas des mesures.** NeoVibe n'a jamais eu
deux utilisateurs qui se croisent au quotidien pendant un mois. Ils sont à
reprendre dès qu'il y aura des chiffres réels, et ne doivent jamais être cités
comme une constante du produit.

Chacun vit dans **une seule fonction SQL** : les changer, c'est toucher une
ligne, jamais deux.

---

## 4. Comment ça monte, et comment ça redescend

### Ce que l'app note

Une seule chose, une fois par jour au maximum :

> « Ces deux amis se sont croisés le **jour J**. »

C'est la table `meeting_days`. Elle est écrite à **un seul endroit** —
`public.report_sightings`, au moment exact où un croisement mutuel est constaté
— et elle ne décide de rien.

Un croisement compte **seulement s'il est mutuel** : les deux téléphones doivent
s'être vus. Un seul sens ne suffit pas, et c'est ce qui empêche quelqu'un de
faire monter un palier en te suivant.

### Ce que l'app en déduit

**Le palier** = combien de jours dans les 30 derniers.
**La série** = la longueur de la suite de jours en cours.

⚠️ **Ce sont deux nombres différents, et il ne faut pas les confondre.** Le
premier est borné à 30 par construction — c'est ce qui le rend réversible. La
seconde peut atteindre 100 : les fondre aurait plafonné la série à 30.

### La descente ne coûte rien

Il n'existe **aucun mécanisme de décroissance**. La fenêtre de 30 jours glisse
chaque nuit, les vieux jours en sortent, le compte baisse tout seul. Une
décroissance qu'il aurait fallu programmer aurait été une deuxième règle à tenir
d'accord avec la première — et le jour où l'une aurait bougé, l'autre aurait
menti.

### Quand le calcul se fait

| Moment | Ce qui se passe |
|---|---|
| Premier croisement de la journée | le palier de cette paire est recalculé |
| Chaque nuit à **3 h 11** | tous les paliers sont recalculés (la fenêtre a glissé) |

La tâche de nuit s'appelle `neovibe_tiers`. ⚠️ Elle a **son propre job** : on ne
greffe pas une nouveauté sur la purge, parce qu'un job est une transaction et
qu'une erreur emporterait tout le reste.

Pour vérifier qu'elle tourne : la colonne `connections.tier_refreshed_at`. Une
tâche planifiée qui échoue ne dit rien à personne — cette colonne est la seule
trace qu'elle est passée.

---

## 5. La série

On remonte les jours de croisement du plus récent au plus ancien. La suite
s'arrête au premier trou de **plus de 2 jours**.

Concrètement : **un week-end ne tue pas la série** d'un camarade de classe, mais
une semaine d'absence oui.

Elle est **entièrement recalculée depuis les faits** à chaque lecture. Elle ne
peut donc pas dériver si une tâche planifiée saute un tour, contrairement à un
compteur qu'on incrémenterait.

### L'échelle affichée

| Jours | | Jours | | Jours | |
|---|---|---|---|---|---|
| 0 | 🥚 Œuf | 7 | 🐢 Tortue | 30 | 🐋 Baleine |
| 1 | 🐣 Éclosion | 10 | 🦖 Dino | 50 | 🦄 Licorne |
| 3 | 🐥 Poussin | 14 | 🐠 Poisson | 75 | 🔥 Braise |
| 5 | 🦎 Lézard | 20 | 🐬 Dauphin | 100 | 💎 Diamant |

⚠️ **Ce qui fait marcher cette mécanique, ce sont les paliers VERROUILLÉS qu'on
voit devant soi**, pas ceux qu'on a franchis.

⚠️ **Et notre série n'est pas celle des autres apps.** Ailleurs, elle se garde
en **publiant** tous les jours. Ici elle se garde en **se voyant**. Même ressort
de rétention, mais qui pousse vers le réel au lieu de pousser vers l'écran.

---

## 6. Ce que les paliers débloquent

Choisi par Jay le 2026-08-29.

| Déblocage | État |
|---|---|
| **Les stories réservées à un palier** | ✅ livré |
| **La présence en direct** (délai du « presque ») | ✅ livré — voir ci-dessous |
| **Le droit de t'envoyer un Rush** | 🟠 attend que le Rush existe |

### Les stories réservées

Une story porte un palier minimum (`stories.min_tier`). En dessous, elle est
invisible.

⚠️ **Le palier s'applique à TOUS les chemins d'accès**, y compris le repartage.
Le poser sur la seule audience ordinaire aurait laissé la porte du relais
ouverte — et une story réservée aurait fuité par cette porte-là, sans qu'aucune
erreur ne le dise.

### Le délai du « presque »

| Palier | Délai avant la notification |
|---|---|
| Inséparable | **tout de suite** |
| Proche | **15 minutes** |
| Ami | **45 minutes** |

L'interrupteur global « temps réel » des réglages **l'emporte** quand il est
allumé : il force l'instantané pour tout le monde. Un réglage explicite qu'une
règle automatique pourrait annuler ne serait plus un réglage.

⚠️ **Ce déblocage a été reformulé.** La question posée à Jay le 2026-08-29
décrivait `realtime_waves` comme « qui peut me voir en direct » — c'est faux,
c'est **sa propre préférence sur ses propres notifications**. Ce qui précède est
l'interprétation retenue, soumise à Jay le 2026-08-30. Voir `RAPPELS.md` #102.

---

## 7. Ce qui reste à décider — par Jay

*Notes du 2026-08-30, à reprendre quand il y aura réfléchi.*

1. **Les noms.** « Ami / Proche / Inséparable » sont de moi. Jay envisage
   **un badge d'amitié à la place des mots**.
2. **Deux paliers intermédiaires en plus**, soit cinq au total.
   ⚠️ **Point technique à connaître avant** : l'ordre de déclaration du type
   `friendship_tier` **est** l'ordre de comparaison en base. Insérer une valeur
   au milieu demandera `alter type … add value … before …`, jamais un simple
   `add value` en fin de liste — sinon un palier intermédiaire se retrouverait
   au-dessus d'`inner` et donnerait tous les droits.
   ✅ Côté app, le compilateur protège : les couleurs d'anneau sont un choix
   exhaustif sur l'énumération, donc ajouter un palier **casse la compilation**
   tant qu'on ne lui a pas donné sa couleur. C'est voulu.
3. **Les règles elles-mêmes** (les quatre chiffres du §3).

---

## 8. Ce qu'un palier n'est PAS

⚠️ **Il ne dit pas comment on est lié, il dit à quel point on est proche.**

| | Comment on est lié | À quel point on est proche |
|---|---|---|
| Exemples | inconnu → croisé → même soirée → recommandé → ami | ami → proche → inséparable |
| Nature | **un fait** vérifiable | **une intensité** qui se gagne |
| Durée de vie | temporaire (24 h, 7 jours…) | durable, mais réversible |
| Où ça vit | `encounters`, `recommendations`, `ping_pairs` | `connections.tier` |

🔴 **`meeting_days` n'accorde aucun droit, et ne doit jamais en accorder.**
`encounters` dit « croisés **récemment** » et vit 24 h — c'est lui qui ouvre le
profil d'un inconnu croisé. `meeting_days` dit « croisés **le jour J** » et vit
indéfiniment. Y brancher une lecture transformerait une fenêtre de 24 heures en
fenêtre éternelle, en silence.

---

## 9. Où c'est écrit

| Quoi | Où |
|---|---|
| Toute la couche serveur | `supabase/migrations/20260830010000_les_paliers_d_amitie.sql` |
| Le palier côté app (noms, anneaux, échelle de série) | `lib/features/connections/friendship.dart` |
| La lecture (une seule de toute l'app) | `lib/features/connections/friendships_repository.dart` |
| L'anneau et le filtre | `lib/features/connections/tier_avatar.dart` |
| Le délai du presque | `lib/features/proximity/net/presque_ledger.dart` |
| Les tests | `test/friendship_test.dart` |

⚠️ **Le ping ne lit aucun palier** — consigne de Jay du 2026-08-28. Il écrit un
fait dans `meeting_days` et s'arrête là. Ce que ce fait vaut socialement se
décide ailleurs, et le ping n'a aucun moyen de le savoir.
