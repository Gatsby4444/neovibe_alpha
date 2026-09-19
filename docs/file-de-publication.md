# La file de publication — ce qui existe (2026-09-19)

> Description de ce qui est **construit** le 2026-09-19 (v0.9.220), en
> réponse à la décision de Jay : *« Je veux qu'on fasse comme les autres.
> Les 5 points, même le 5ᵉ car c'est essentiel pour une bonne UX. »*
> Le contrat côté serveur (les versions, le traitement en clair en mémoire)
> est un chantier à part : `docs/serveur-media.md`.

## Ce que ça change pour l'utilisateur

| Avant | Maintenant |
|---|---|
| « Publier » → un bandeau « Préparation… 2/5 » en tête du profil, pendant une minute | « Suivant » → le travail commence **pendant qu'on tape la légende** ; « Publier » → la publication **apparaît tout de suite** dans la grille, à sa place, avec son anneau d'avancement |
| l'écran se figeait ~9 s par vidéo (scellage Dart) | rien ne se fige : transcodage, scellage et envoi sont natifs, sur un fil de travail |
| fermer l'app = perdre la publication | fermer l'app, couper le réseau, redémarrer le téléphone : la publication **finit quand même** (notification « Envoi… 43 % ») |
| une coupure = tout renvoyer | une coupure = repartir **de l'octet où le serveur en était** |
| une erreur = un bandeau qui disparaît | une erreur = la case reste, avec un point d'exclamation ; un appui propose **Réessayer** / **Abandonner** |

## Qui fait quoi

```
Dart, à « Suivant »                      Kotlin, avec ou sans l'app
──────────────────────                   ──────────────────────────
PublishPreparer.start(draft)             PublishService (premier plan, dataSync)
  rend les photos (shader de l'aperçu)     └ PublishPipeline.process(job), pas à pas :
  rend le calque des vidéos (PNG)              preparing  : transcode, couverture, scelle
  calcule les paramètres du transcodage        uploading  : TUS, 2 fichiers à la fois, reprenable
  copie la source vidéo dans le dossier        waiting    : tout est déposé, il manque « Publier »
  écrit la couverture (cover.jpg)              registering: RPC publish_to_library
  tire la clé → own_keys.json                  done       : scellés → cache own/, dossier vidé
  calcule où iront les scellés (own/)
  PublishBridge.enqueue(job.json) ────────►  job.json
                                           
Dart, à « Publier »                       
  PublishBridge.release(id, légende…) ───►  release.json   (lu à `waiting`)
Dart, retour en arrière                    
  PublishBridge.cancel(id) ──────────────►  cancel         (lu entre deux pas)

Kotlin → Dart : neovibe/publish/events {jobs:[…]} → PendingPublications → PendingCell
```

**Le Dart ne transcode plus, ne scelle plus, n'envoie plus une publication.**
Il rend ce que seul Flutter sait rendre (le shader de l'aperçu), il calcule,
il dépose. La Vibe (une ou deux faces, envoyées sous les yeux de
l'utilisateur) garde son chemin dans `LibraryRepository.publish`.

## Les fichiers

`<filesDir>/publish/<id>/` — **pas sous `work/`**, que `WorkDir.sweep()`
balaie au démarrage de l'app (« rien n'est en vol à ce moment-là » n'est
plus vrai d'une publication que le service finit sans l'app).

| Fichier | Écrit par | Lu par |
|---|---|---|
| `job.json` | **le service seulement** | le service, le pont (instantanés) |
| `release.json` | **l'app seulement** (« Publier ») | le service, à `waiting` |
| `cancel` | **l'app seulement** | le service, entre deux pas |
| `album_*.jpg`, `album_*_src.mp4`, `*_overlay.png` | l'app | le service ; effacés dès que scellés |
| `*.seal` | le service | l'envoi ; copiés dans `own/` puis effacés |
| `cover.jpg` | l'app | la grille (`PendingCell`) ; reste jusqu'à l'acquittement |

`<filesDir>/publish_session.json` — url, clé publique, jeton : un autre
fichier, une autre durée de vie (la connexion, pas l'envoi).

⚠️ **Deux écrivains, deux fichiers.** Si l'app écrivait `job.json` en posant
la légende pendant qu'une vidéo se transcode, l'un des deux écraserait
l'autre — en silence. C'est la règle 2 de `CLAUDE.md`.

## Les trois sortes d'erreurs

| Ce que le serveur dit | Ce que la file fait |
|---|---|
| 401, ou 400/403 « JWS » du coffre | `AuthExpired` → le service demande un jeton à l'app (`needToken`) et **attend**. Il ne renouvelle jamais le jeton lui-même : le jeton de renouvellement est à usage unique, l'employer d'ici déconnecterait l'app. Si l'app est fermée, la publication attend son prochain lancement — c'est la limite assumée de « survit à la fermeture » |
| un autre 4xx (« Une publication contient de 1 à 20 médias ») | `Rejected` → **échec**, avec le message ; rien ne se réessaie seul |
| réseau, 5xx | `IOException` → attente croissante (5 s, 10 s, 20 s… 5 min), et le retour du réseau réveille tout de suite |
| transcodage / scellage raté | **échec** : même fichier, même décodeur, il échouerait pareil |

## Ce qui a été vérifié à la source

- Le protocole TUS de Supabase, **depuis le PC avec un bot de dev**
  (`scratchpad/tus_probe.py`, 2026-09-19) : création → `Location` absolue ;
  `HEAD` → `Upload-Offset` ; `PATCH` de 6 Mo puis du reste → 204 ; l'objet
  existe à la bonne taille ; le propriétaire peut l'effacer ; `x-upsert: true`
  accepté sur un chemin neuf. **`X-HTTP-Method-Override: PATCH` est ignoré**
  (pris pour une création) — d'où OkHttp.
- La forme des erreurs : RPC refusée = 400 + `message` lisible ; jeton faux =
  401 `PGRST301` (PostgREST) et **400** `"statusCode":"403"` (coffre).
- Le pipeline, sur la JVM sans codec ni réseau (`PublishPipelineTest`, 8) :
  reprise à l'offset, attente croissante, jeton, refus, annulation, JSON.

## Ce qui n'est PAS fait

- **La position de la Vibe** : elle garde son envoi Dart (petit, sous les
  yeux). La faire passer par la file demanderait le rendu natif de ses
  faces éditées — à décider.
- **Le serveur** ne calcule pas encore de versions (`docs/serveur-media.md`).
- **iOS** : même `job.json`, même pipeline, `URLSession` en arrière-plan
  (`docs/parties-natives-par-os.md` § 10).
- Une publication déposée mais **jamais libérée** (l'utilisateur a quitté
  l'app en tapant sa légende sans revenir) reste `waiting` sur le disque et
  dans le coffre. Le service la garde ; à décider : la purger après N jours,
  ou la proposer comme brouillon.
