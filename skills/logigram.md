---
name: logigram
description: Écrire un schéma d'architecture au format JSON Logigram, que l'utilisateur importera dans son outil visuel (blocs imbriqués, variables, liens). À utiliser dès qu'on demande de représenter, schématiser, cartographier ou documenter visuellement une architecture, un flux de données, une chaîne logique ou un pipeline.
---

# Écrire un schéma pour Logigram

Logigram est un éditeur visuel d'architectures (fichier local `index.html`, aucun serveur).
Tu ne pilotes pas l'outil : **tu produis un JSON** que l'utilisateur colle dans
*Importer → Remplacer le schéma* (ou *Ajouter au schéma* pour compléter l'existant).

Rends toujours **un seul bloc de code JSON**, complet et valide, sans commentaire à
l'intérieur (le JSON n'en accepte pas). Les explications vont autour, pas dedans.

## 1. Le squelette

```json
{
  "name": "Nom du schéma",
  "nodes": [
    { "id": "api", "type": "server", "label": "API Node.js" },
    { "id": "token", "type": "variable", "label": "token", "dtype": "string", "in": "api" }
  ],
  "edges": [
    { "from": "api", "to": "db", "kind": "data", "label": "SELECT" }
  ]
}
```

**N'écris pas de coordonnées.** Sans `x`/`y`, Logigram calcule le placement : les blocs
reliés sont disposés en colonnes de gauche à droite selon le sens des liens, les variables
sont empilées en haut de leur bloc, et chaque conteneur est dimensionné pour son contenu.
Un schéma avec coordonnées écrites à la main est presque toujours moins lisible.

## 2. Les blocs (`nodes`)

| Champ | Obligatoire | Rôle |
|---|---|---|
| `id` | recommandé | Identifiant court et stable, sert de cible aux `in`, `from`, `to` |
| `type` | oui | Voir le catalogue ci-dessous |
| `label` | oui | Le texte affiché dans l'en-tête |
| `in` | non | `id` du bloc **parent** : c'est ainsi qu'on imbrique |
| `desc` | non | Ligne de description sous le titre (technos, rôle, note) |
| `dtype` | variables | Type de donnée : `string` `number` `boolean` `object` `array` `json` `uuid` `date` `enum` `secret` `fichier` `stream` `any` |
| `value` | non | Valeur ou exemple, affiché en monospace sous le nom |
| `color` | non | Forcer une couleur `#rrggbb` (par défaut : celle du type) |
| `children` | non | Alternative à `in` : tableau de blocs imbriqués directement |

### Catalogue des types

Utilise ces clés exactes. Un synonyme courant est toléré (`serveur`, `postgres`, `docker`,
`webhook`, `champ`…) mais un type inconnu retombe silencieusement sur `service`.

**Structure** — `group` (zone/frontière logique, ex. « Production », « Domaine facturation »),
`cluster` (cloud, VPC, région, k8s)

**Infrastructure** — `server`, `container`, `storage` (S3, volume), `external` (SaaS, API tierce)

**Logique** — `service`, `module`, `api` (endpoint, route), `fn` (fonction, handler), `queue` (file, broker)

**Actions** — `trigger` (déclencheur, webhook, cron), `action` (étape), `condition` (test, branche),
`loop` (boucle, itération), `transform` (mapping, conversion), `wait` (délai), `error` (exception, échec),
`task` (tâche à faire, chantier)

**Données** — `db`, `table` (collection, entité), `cache`, `variable`

**Acteurs** — `client` (front, navigateur, mobile), `user` (acteur humain, rôle), `note` (annotation libre)

### Imbrication

Tout bloc peut en contenir un autre, sans limite de profondeur. Deux écritures équivalentes :

```json
{ "id": "srv", "type": "server", "label": "API", "children": [
  { "id": "auth", "type": "service", "label": "AuthService" }
]}
```

```json
{ "id": "srv", "type": "server", "label": "API" },
{ "id": "auth", "type": "service", "label": "AuthService", "in": "srv" }
```

Préfère `children` quand la hiérarchie est l'information principale (une infra),
et `in` quand la liste est longue et plate (beaucoup de variables).

## 3. Les liens (`edges`)

```json
{ "from": "auth", "to": "users", "kind": "data", "label": "SELECT", "arrow": "to" }
```

- `from` / `to` : un `id` (ou un `label`, s'il est unique dans le document)
- `kind` : `data` (bleu, plein) · `call` (jaune, plein) · `event` (rose, tirets) ·
  `dep` (gris, pointillés) · `flow` (vert, plein, enchaînement d'étapes)
- `label` : ce qui transite — `userId`, `POST /login`, `order.created`, `INSERT`
- `arrow` : `to` (défaut), `from`, `both`, `none`

Formes courtes acceptées : `"a -> b"` et `"a -> b : étiquette"`.

Un lien peut relier **n'importe quels blocs**, y compris deux variables situées dans deux
serveurs différents — c'est précisément ce qui rend une chaîne de données lisible.

## 4. Ce qui fait un bon schéma

**Modélise les variables, pas seulement les boîtes.** L'intérêt de l'outil est de montrer
*où vit la donnée*. Un `server` vide n'apprend rien ; un `server` contenant les variables
qu'il manipule, reliées à leurs colonnes en base, oui.

**Fais parler les liens.** Un lien sans étiquette entre deux services est une flèche de plus.
`POST /login`, `order.created`, `SELECT users` racontent le système.

**Choisis le bon axe.** `flow` pour un enchaînement d'étapes (ce sont les liens qui créent
les colonnes de gauche à droite), `data` pour une donnée qui circule, `dep` pour « utilise ».

**Groupe.** Un `group` ou un `cluster` autour de chaque frontière réelle (machine, réseau,
domaine, équipe) rend le schéma lisible d'un coup d'œil.

**Reste dans une taille utile.** 15 à 40 blocs par schéma. Au-delà, découpe en plusieurs
schémas (un par domaine) plutôt que de tout empiler.

**Ordonne tes déclarations.** À l'intérieur d'une colonne, les blocs apparaissent dans
l'ordre où tu les déclares : mets l'important en premier.

## 5. Exemple complet

```json
{
  "name": "Inscription utilisateur",
  "nodes": [
    { "id": "front", "type": "client", "label": "Formulaire web", "children": [
      { "id": "email", "type": "variable", "label": "email", "dtype": "string" },
      { "id": "pwd", "type": "variable", "label": "password", "dtype": "secret" }
    ]},
    { "id": "api", "type": "server", "label": "API", "desc": "Node.js · Express", "children": [
      { "id": "signup", "type": "trigger", "label": "POST /signup" },
      { "id": "check", "type": "condition", "label": "email déjà pris ?" },
      { "id": "hash", "type": "transform", "label": "hash du mot de passe" },
      { "id": "create", "type": "action", "label": "créer l'utilisateur" },
      { "id": "conflict", "type": "error", "label": "409 Conflict" }
    ]},
    { "id": "db", "type": "db", "label": "PostgreSQL", "children": [
      { "id": "users", "type": "table", "label": "users", "children": [
        { "id": "uid", "type": "variable", "label": "id", "dtype": "uuid" },
        { "id": "umail", "type": "variable", "label": "email", "dtype": "string" }
      ]}
    ]},
    { "id": "mailer", "type": "external", "label": "Service e-mail" }
  ],
  "edges": [
    { "from": "front", "to": "signup", "kind": "call", "label": "POST /signup" },
    { "from": "signup", "to": "check", "kind": "flow" },
    { "from": "check", "to": "conflict", "kind": "flow", "label": "oui" },
    { "from": "check", "to": "hash", "kind": "flow", "label": "non" },
    { "from": "hash", "to": "create", "kind": "flow" },
    { "from": "create", "to": "users", "kind": "data", "label": "INSERT" },
    { "from": "create", "to": "mailer", "kind": "event", "label": "user.created" },
    { "from": "email", "to": "umail", "kind": "dep" }
  ]
}
```

## 6. Modifier un schéma existant

L'utilisateur peut te fournir son schéma actuel : dans Logigram, *Importer →
**Copier le schéma actuel (format IA)*** produit exactement le format décrit ici,
sans coordonnées. Travaille sur ce JSON, renvoie-le entier, il le réimporte avec
*Remplacer*. Ses `id` sont dérivés des noms de blocs : conserve-les pour ne pas casser
les liens.

Pour n'ajouter qu'un morceau, fournis un JSON ne contenant que le nouveau, et dis-lui
d'utiliser *Ajouter au schéma* : le fragment est posé à droite de l'existant.
Attention, un `in` ne peut viser qu'un bloc **du même fragment** — on ne peut pas
imbriquer dans un bloc déjà présent à l'écran. Pour cela, repasse par le schéma complet.

## 7. Avant de rendre

- [ ] JSON valide : pas de commentaire, pas de virgule finale, guillemets droits
- [ ] Chaque `in`, `from`, `to` pointe vers un `id` réellement déclaré
- [ ] Les `id` sont uniques
- [ ] Chaque `type` figure au catalogue
- [ ] Les variables portent un `dtype`
- [ ] Les liens importants portent un `label`
- [ ] Pas de `x`/`y` — laisse la mise en page se faire

Les erreurs ne bloquent pas l'import : Logigram signale ce qu'il n'a pas compris
(type inconnu, référence introuvable, doublon) et importe le reste. Si l'utilisateur
te rapporte ces avertissements, corrige le JSON et renvoie-le en entier.
