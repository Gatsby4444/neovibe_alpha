# La file de publication — ce qui existe (2026-09-19 ; les Vibes depuis le 2026-09-21)

> Description de ce qui est **construit** le 2026-09-19 (v0.9.220), en
> réponse à la décision de Jay : *« Je veux qu'on fasse comme les autres.
> Les 5 points, même le 5ᵉ car c'est essentiel pour une bonne UX. »*
> Écrite pour les albums et les Flows ; **depuis le 2026-09-21, c'est la
> Vibe qui y passe** (Jay : *« on fait la file native maintenant pour les
> vibes »*), les albums et les Flows étant sortis du MVP le même jour
> (`docs/formats-mis-de-cote.md`).
> Le contrat côté serveur (les versions, le traitement en clair en mémoire)
> est un chantier à part : `docs/serveur-media.md`.

## Ce que ça change pour l'utilisateur

| Avant | Maintenant |
|---|---|
| « Envoyer » une Vibe vers ma bibliothèque → un envoi simple, sous mes yeux, dans l'app | « Envoyer » → la Vibe **apparaît tout de suite** dans la grille, à sa place, avec son anneau d'avancement ; le bandeau d'envoi de la caméra se règle aussitôt (la destination est « déposée ») |
| fermer l'app ou perdre le réseau au milieu = la Vibe est perdue, à refaire | fermer l'app, couper le réseau, redémarrer le téléphone : la Vibe **finit quand même** (notification « Envoi… 43 % ») |
| une coupure = tout renvoyer | une coupure = repartir **de l'octet où le serveur en était** |
| une erreur = un bandeau qui disparaît | une erreur = la case reste, avec un point d'exclamation ; un appui propose **Réessayer** / **Abandonner** |

## Qui fait quoi

```
Dart, à « Envoyer » (SharePublisher)     Kotlin, avec ou sans l'app
──────────────────────────────────────   ──────────────────────────
LibraryRepository.publish(faces…)        PublishService (premier plan, dataSync)
  copie les faces (déjà finales)           └ PublishPipeline.process(job), pas à pas :
    dans le dossier de la publication          preparing  : index MP4 en tête, scelle
  écrit la couverture (cover.jpg)              uploading  : TUS, 2 fichiers à la fois, reprenable
  tire la clé → own_keys.json                  registering: RPC publish_to_library
  calcule où iront les scellés (own/)          done       : scellés → cache own/, dossier vidé
  PublishBridge.enqueue(job.json) ────────►  job.json
  PublishBridge.release(id, droits…) ─────►  release.json   (aussitôt : les réglages
                                                             d'une Vibe sont connus à l'envoi)
Dart, abandon d'un échec
  PublishBridge.cancel(id) ──────────────►  cancel         (lu entre deux pas)

Kotlin → Dart : neovibe/publish/events {jobs:[…]} → PendingPublications → PendingCell
```

**Le Dart ne scelle plus, n'envoie plus une publication.** Il copie, il
dépose. Les faces sont **rendues avant**, en Dart, par l'éditeur de Vibes
(`MediaExport`, à « Suivant ») : un même rendu sert toutes les destinations
d'un envoi (story, chat, bibliothèque), la file ne reçoit que la version
finale — sans `source` ni `transcode`, donc **sans transcodage**. La phase
`waiting` (« déposé mais pas encore publié ») existe toujours dans le
pipeline ; une Vibe ne s'y arrête pas, `release.json` étant écrit juste
après `job.json`.

Le pipeline sait encore transcoder une vidéo qui arrive avec `source` +
`transcode` (testé sur la JVM, `PublishPipelineTest`) : c'est la voie prévue
pour les vidéos importées dans une Vibe, à venir (Jay, 2026-09-21).

## Les fichiers

`<filesDir>/publish/<id>/` — **pas sous `work/`**, que `WorkDir.sweep()`
balaie au démarrage de l'app (« rien n'est en vol à ce moment-là » n'est
plus vrai d'une publication que le service finit sans l'app).

| Fichier | Écrit par | Lu par |
|---|---|---|
| `job.json` | **le service seulement** | le service, le pont (instantanés) |
| `release.json` | **l'app seulement** (« Publier ») | le service, à `waiting` |
| `cancel` | **l'app seulement** | le service, entre deux pas |
| `face_0.jpg` / `.mp4`, `face_1.…` | l'app (copie des faces finales) | le service ; effacés dès que scellés |
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

- **Le transcodage d'une Vibe dans la file** : aujourd'hui l'éditeur rend
  la face en Dart avant l'envoi (elle doit servir aux autres destinations).
  Le jour des vidéos importées, la file reçoit `source` + `transcode` et
  transcode elle-même.
- **Le serveur** ne calcule pas encore de versions (`docs/serveur-media.md`).
- **iOS** : même `job.json`, même pipeline, `URLSession` en arrière-plan
  (`docs/parties-natives-par-os.md` § 10).
- Une publication déposée mais **jamais libérée** (l'utilisateur a quitté
  l'app en tapant sa légende sans revenir) reste `waiting` sur le disque et
  dans le coffre. Le service la garde ; à décider : la purger après N jours,
  ou la proposer comme brouillon.
