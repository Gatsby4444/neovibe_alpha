# Les logigrammes de NeoVibe

Six schémas à importer dans **Logigram** (`C:\Charles\logigram\index.html`) :
*Importer → **Remplacer le schéma*** avec le contenu d'un fichier `.json`.

Un schéma par fichier, **à ouvrir un par un** — pas tous ensemble. C'est délibéré :
l'outil recommande 15 à 40 blocs par schéma, et au-delà on ne voit plus rien.

## L'ordre de lecture

| # | Fichier | Ce qu'il répond | Blocs |
|---|---|---|---|
| 1 | `1-vue-ensemble.json` | **Commencer ici.** C'est quoi NeoVibe, et qui parle à qui ? | 25 |
| 2 | `2-le-ping.json` | Comment deux téléphones se découvrent sans internet | 28 |
| 3 | `3-devenir-amis.json` | Le parcours complet d'une demande d'ami | 32 |
| 4 | `4-une-vibe.json` | Ce qui arrive à une photo, de la capture au partage | 28 |
| 5 | `5-livraison-media.json` | Pourquoi un média ne peut pas fuiter | 21 |
| 6 | `6-modele-de-donnees.json` | Les 29 tables, rangées par famille | 39 |

Les schémas 1 à 3 se lisent d'affilée. Le 4 et le 5 vont ensemble (créer, puis
consulter). Le 6 est une carte de référence, à garder ouverte à côté des autres.

## Comment lire un schéma

- Les **flèches vertes** (`flow`) sont un enchaînement d'étapes : suis-les de
  gauche à droite, c'est l'histoire.
- Les **flèches bleues** (`data`) sont une donnée qui circule. L'étiquette dit
  quoi.
- Les **pointillés gris** (`dep`) veulent dire « dépend de » ou « s'applique
  à ». Ce ne sont pas des étapes.
- Les blocs **jaunes en losange** sont des questions (`condition`) : il en sort
  toujours au moins deux flèches, une par réponse.
- Les blocs **note** ne font rien : ils expliquent *pourquoi* c'est comme ça.
  Ce sont eux qu'il faut lire en premier quand on découvre le projet.

Raccourcis utiles dans Logigram : **F** ajuste la vue, **C** isole la chaîne
logique du bloc sélectionné, le panneau **Données** répond à « où vit cette
variable ? ».

## Les régénérer

```
python tool/build_logigrams.py
```

⚠️ **Le script valide avant d'écrire** : identifiants uniques, types du
catalogue, variables typées, et surtout chaque `in`/`from`/`to` qui pointe vers
un bloc réellement déclaré.

C'est nécessaire parce que **Logigram est tolérant à l'import** : il signale ce
qu'il n'a pas compris et importe le reste. Un lien vers un identifiant inexistant
ne casse donc rien — il disparaît simplement, et le schéma raconte autre chose
que ce qu'on voulait, sans que personne ne s'en aperçoive.

C'est exactement la famille de défauts que ce projet passe son temps à chasser :
*ce qui échoue en silence coûte plus cher que ce qui plante.*
