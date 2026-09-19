# Le serveur média — contrat (écrit le 2026-09-19, rien de construit)

> Décision de Jay, 2026-09-19 : *« J'accepte que la vidéo soit en clair sur
> le serveur pour qu'il puisse calculer des versions différentes, enfin
> faire comme les autres. »* Ce fichier dit **ce que ce service fera**, ce
> qu'il ne fera **jamais**, et ce qu'il faut pour le commencer. Il ne décrit
> rien qui existe : au 2026-09-19, **tout le calcul reste sur le téléphone**
> (`docs/file-de-publication.md`).

## Pourquoi (en une phrase de tous les jours)

Aujourd'hui le téléphone fabrique **une seule version** de chaque vidéo
(1080 de large, ~8 Mbit/s) et tout le monde la reçoit telle quelle, en 4G
comme en Wi-Fi. Les autres applications gardent l'original et fabriquent
**plusieurs qualités** sur leurs serveurs, puis servent à chacun celle que sa
connexion supporte — c'est pour ça que « ça ne saccade pas chez eux ».

## Ce qui change, et ce qui ne change pas

| | Avant | Après |
|---|---|---|
| sur le stockage | scellé | **scellé** (inchangé) |
| sur les téléphones | scellé | **scellé** (inchangé) |
| sur le serveur média | *n'existe pas* | le clair **en mémoire, le temps du calcul**, jamais sur un disque |
| qui a la clé | la base (`content_media_keys`) | la base — **rien de nouveau** : le serveur pouvait déjà lire, il ne le faisait pas |

La promesse « ce qui se passe sur NeoVibe reste sur NeoVibe » vise la fuite
vers l'**extérieur** (capture, export, stockage volé) — pas notre propre
serveur, qui détient déjà les clés. C'est ce constat d'honnêteté qui a fondé
la décision.

## Ce que le service fera

1. **Recevoir** une notification « publication `X` inscrite » (déclencheur
   base → file de travail).
2. **Lire** le scellé depuis le coffre et la clé depuis `content_media_keys`,
   **déchiffrer en mémoire** (flux, jamais un fichier temporaire en clair).
3. **Fabriquer** les versions :
   - vidéo : 3 qualités (par ex. 480p ~1,2 Mbit/s, 720p ~3 Mbit/s, 1080p
     ~6 Mbit/s), **`moov` en tête**, images-clés toutes les 2 s (pour que le
     lecteur puisse sauter et changer de qualité au même endroit) ;
   - couverture : une image, deux tailles (vignette 400, plein 1080) ;
   - photo : deux tailles (400, 1080) — les vignettes du profil n'ont pas à
     décoder du 1080.
4. **Resceller** chaque version avec **la clé du contenu** (même format
   `NVC1`, `docs/format-media-scelle.md`) et la déposer à côté de l'original
   (`<owner>/<item>_<slot>_<variante>.<ext>`).
5. **Inscrire** les variantes en base (`library_media_variants` : place,
   variante, chemin, largeur, hauteur, débit, taille), et marquer l'original
   « traité ».
6. Sur échec : le noter, **garder l'original** — le téléphone continue de
   lire la version qu'il a fabriquée. Le traitement est un **plus**, jamais
   une condition.

## Ce que le service ne fera jamais

- Écrire un octet de clair sur un disque, un cache, un journal, une trace
  d'erreur (un `ffmpeg` qui lit un fichier temporaire en clair est
  **interdit** : entrée et sortie passent par des tubes).
- Garder une copie du clair après le calcul (mémoire libérée par version).
- Lire un contenu **hors** d'une tâche de publication (pas de « rescan »
  général : chaque lecture est liée à un événement d'inscription).
- Servir quoi que ce soit lui-même : il écrit dans le coffre, le coffre sert.

## Ce que le téléphone changera, quand le service existera

- **Le lecteur choisit sa version** : sur Wi-Fi la 1080, sur 4G la 720, la
  480 quand ça saccade (les images perdues sont déjà comptées :
  `SealedVideoValue.droppedFrames`). Le changement se fait à une image-clé.
- **La publication accélère** : le téléphone n'aura plus à produire un 1080
  soigné, un 720 rapide suffit (le serveur refait le reste). La vidéo de
  3 min qui coûtait 40 s de transcodage en coûtera ~15.
- Les vignettes lisent la petite taille.

## Ce qu'il faut pour commencer — décision de Jay

| Besoin | Pourquoi | Qui décide |
|---|---|---|
| **un VPS** (le serveur maison tranché le 2026-08-13) | Supabase n'exécute pas `ffmpeg` ; une fonction Edge est bornée en temps et en mémoire, une vidéo de 3 min ne s'y transcode pas | **Jay** — provisionner et payer (ordre de grandeur : 4 vCPU / 8 Go suffisent pour un seed dans une ville ; ~20–40 €/mois) |
| une clé de service **restreinte** au coffre et à `content_media_keys` | jamais la `service_role` complète sur une machine qui traite du clair | à écrire (rôle Postgres dédié + politique) |
| une file de tâches (table `media_jobs` + déclencheur) | pour que rien ne se perde entre l'inscription et le traitement | à écrire |
| le format `library_media_variants` et la lecture côté app | pour que le lecteur puisse choisir | à écrire, après le service |

⚠️ **Tant que le VPS n'existe pas, rien de ce fichier ne peut se construire.**
C'est le point à trancher en premier ; le reste est du code.
