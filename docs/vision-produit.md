# Vision produit — NeoVibe

> Source : formulation de Jay du **2026-07-26**. Ce document est la référence
> de la vision. `CLAUDE.md` en donne le résumé opérationnel ; ici on garde le
> raisonnement complet, ce qui reste à construire et les points de vigilance.
> À relire en début de session avec `RAPPELS.md` et les derniers rapports.

---

## 1. L'objectif principal

NeoVibe est conçu pour **retrouver de l'authenticité et du réel dans les
échanges en ligne**, à la place d'être bourré de contenu « vide » et d'échanges
sans valeur parce que trop faciles — le snap envoyé à tout le monde en est
l'archétype.

NeoVibe vise **le juste milieu entre fun et pratique, tout en gardant un
maximum d'authenticité**.

Formulation courte : **l'app mise sur l'exclusivité des relations et leur
valeur, pas sur leur quantité.** C'est l'app sur laquelle on discute avec ses
amis proches ou ses camarades de classe, ceux qu'on voit tous les jours.

### Évolution par rapport à la formulation précédente

L'ancienne thèse — « la présence physique est la monnaie primaire » — reste
vraie mais était trop étroite : elle décrivait le **mécanisme d'entrée** et le
prenait pour la finalité. Elle n'expliquait pas des mécaniques déjà construites
(le One of One n'a rien d'une mécanique de proximité : c'est une mécanique
d'exclusivité relationnelle).

La présence physique reste **la barrière fondatrice**. L'authenticité et la
valeur de la relation en sont **la finalité**.

---

## 2. Les mécaniques fondatrices — construites

### 2.1 Les deux seules portes d'entrée

1. **Connexion par BLE** — proximité physique obligatoire pour ajouter
   quelqu'un en ami.
2. **Recommandation par un tiers** — quand un utilisateur est dans
   l'impossibilité de rencontrer physiquement un autre, un ami commun peut le
   recommander ; si l'autre accepte, ils deviennent amis et peuvent discuter
   sur NeoVibe. (Plafond 10/mois, chaîne A→B→C.)

Pas de recherche, pas d'annuaire, pas de découverte à distance.

### 2.2 Les Cards — le « cool » et l'authenticité

- **Les cards** en général : mécanique cool, un objet qu'on partage avec ses
  amis, plus travaillé qu'un snap jetable.
- **Oneshot** et **BeReal** — au fond la même intention : la capture
  authentique, non préparée, non retouchée.
- **One of One** — la card **dédiée exclusivement à un ami**, là où un snap
  peut être envoyé à plusieurs personnes en un geste. C'est la traduction la
  plus directe de la thèse : la valeur vient de l'exclusivité.

---

## 3. Ce qui reste à construire — « meubler l'app »

### Le raisonnement, à ne jamais oublier

> Pourquoi les utilisateurs iraient discuter sur l'app si c'est justement plus
> difficile d'avoir accès au chat et de rencontrer des gens ? Ils iraient
> ailleurs.

**Il faut donner une légitimité aux barrières sociales qu'on pose au départ.**
Une barrière sans contrepartie ne retient personne. Rendre l'app utile et fun
n'est donc pas un supplément décoratif : c'est la condition de survie de la
thèse. C'est **la moitié du produit qui manque encore**, et la clé d'une
rétention utilisateur durable.

### 3.1 Un écosystème et une dynamique renouvelée en permanence

- **Mini-jeux**
- **Quiz**
- **Compatibilité** entre amis
- **Classements**
- Avec du **FOMO** en moteur de circulation : « ton ami a joué à… », « a
  répondu à tel quiz », « regardez son classement », « regardez votre
  compatibilité ».

Exigence : **une dynamique différente en permanence**, pas une fonctionnalité
figée qu'on épuise en une semaine.

### 3.2 Un feed — local

Un feed, **parce que c'est la norme sur tous les réseaux sociaux** ; mais un
feed qui n'affiche que le contenu réalisé et publié par **les personnes de ta
ville, de ta région, de ton pays** (échelle locale plus ou moins large).

**Comptes créateurs** : à prévoir, avec une **visibilité internationale sans
limite**.

> ⚠️ Ceci **modifie** la ligne « feed style TikTok » du hors-scope de
> `CLAUDE.md`. Ce qui reste exclu, c'est le **feed algorithmique global**
> d'attention. Le feed local est dans le périmètre depuis le 2026-07-26.

---

## 4. Points de vigilance signalés par Claude (2026-07-26)

**Arbitrés par Jay le même jour** — voir les encadrés « Réponse de Jay ». Les
réserves sont conservées telles quelles : elles restent des points d'attention
pour l'implémentation, pas des objections rouvertes.

### 4.1 Les comptes créateurs peuvent manger la règle

C'est le vecteur classique par lequel un feed local redevient un feed
d'attention : le contenu professionnel est mieux produit, plus performant, il
gagne mécaniquement le classement, et l'app finit dominée par des créateurs
qu'on ne croisera jamais. Si on les fait, prévoir une **borne dure dès le
départ** (part maximale de contenu créateur dans le feed, ou surface séparée du
feed local) plutôt qu'une modération a posteriori.

### 4.2 Contenu publié ≠ contenu éphémère

Toute l'architecture actuelle est TTL 24 h + vue unique. Un feed suppose du
contenu qui **dure** et se re-consomme : deux régimes de contenu à faire
cohabiter (stockage, quota, purge, signalement). Faisable, mais pas gratuit.

> **Réponse de Jay (2026-07-26) — le feed est confirmé, pas de retour en
> arrière.** « C'est un mal nécessaire pour que l'app fonctionne. Tout le monde
> a besoin d'un feed aujourd'hui ; on ne peut pas changer d'un seul coup le
> système dans lequel tout le monde est pris, mais progressivement. » Et oui,
> **cela impliquera du contenu durable, plus seulement de l'éphémère** — c'est
> accepté en connaissance de cause. **Les détails seront rediscutés au moment
> de l'implémenter.** Les points 4.1, 4.2 et 4.4 sont donc à ressortir à
> l'ouverture du chantier feed, comme matière de conception — pas pour
> reposer la question.

### 4.3 Les mini-jeux portent le risque exact qu'on dénonce

Un quiz mal cadré, c'est du contenu vide industrialisé — la chose même contre
laquelle l'app se construit. Condition pour qu'ils tiennent la thèse : le jeu
se joue **avec des gens qu'on connaît déjà** et produit une information **sur
la relation** (compatibilité, classement entre amis, historique commun), pas un
score isolé à diffuser. **Le FOMO doit pousser vers l'ami, pas vers le
contenu.**

> **Réponse de Jay (2026-07-26) — la réserve est levée, le cadrage était déjà
> celui-là.** Le but des quiz et mini-jeux est de **créer de l'interaction et
> de l'activité entre amis uniquement**. Ce n'est donc pas contraire à la
> vision : ce sont **des amis qui passent un moment ensemble** — en ligne
> certes, mais un moment particulier, **qui aura ensuite pour but de rediriger
> vers des sorties et des interactions réelles**.
>
> **Deux exigences de conception qui en découlent, à tenir :**
> 1. **Entre amis uniquement** — pas de jeu avec des inconnus, pas de
>    classement mondial. Le cercle reste la frontière.
> 2. **Le jeu est un tremplin vers le réel**, pas une fin en soi. Chaque
>    mécanique doit se demander comment elle ramène vers une rencontre
>    physique (proposer une sortie, un défi à faire ensemble, un croisement…).

### 4.4 Ce qui déborde dans un chantier de contenu public

Jamais le premier écran — toujours ce qu'un contenu public traîne derrière lui :
modération, signalement, blocage, gestion des abus. Appliquer la consigne
« heuristiques simples validables tôt ».

---

## 5. La grille de décision

Elle remplace l'ancienne question, devenue trop étroite :

> **Toute nouvelle fonctionnalité doit soit passer par la présence physique,
> soit augmenter la valeur d'une relation existante. Si elle ne fait ni l'un
> ni l'autre, c'est du remplissage — exactement le mal qu'on combat.**

Exemple d'application : un quiz **passe** s'il se joue entre amis et dit
quelque chose de la relation ; il **échoue** s'il devient un flux de contenus à
consommer.

---

## 6. Horizon

Estimation de Jay (2026-07-26) : **encore quelques semaines de développement**
pour atteindre le résultat souhaité.
