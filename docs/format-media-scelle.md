# Format des médias scellés — `NVC1`

**Statut** : en vigueur depuis le 2026-08-12 (v0.9.54).
**Ce document est normatif.** Il existe désormais **deux implémentations** du
format — Dart pour sceller, Kotlin pour ouvrir (et Swift plus tard). Toute
divergence entre elles est invisible à la compilation et ne se verrait qu'à
l'exécution, sur l'appareil de Jay. Ce fichier et les **vecteurs de test
croisés** (§6) sont ce qui les tient alignées.

---

## 1. Pourquoi deux implémentations

Le déchiffrement en Dart pur plafonne à ~2,7 Mo/s et s'exécute sur l'isolate qui
dessine l'écran : c'est la cause mesurée du saccadement de la v0.9.55. La
**lecture native directe** (décision de Jay, 2026-08-12) confie l'ouverture au
lecteur vidéo lui-même, qui réclame des intervalles d'octets et les reçoit
déchiffrés en natif, sur ses propres fils.

L'écriture reste en Dart : sceller se fait une fois, à l'envoi, hors du chemin
critique de l'affichage. **Le natif ne scelle jamais — il ne fait que lire.**

## 2. Disposition des octets

Tout est en **gros-boutiste** (big-endian), y compris l'en-tête.

```
  en-tête — 16 octets
    0..3    magie            'NVC1'  (0x4E 0x56 0x43 0x31)
    4..7    taille de bloc   uint32  — le clair d'un bloc plein
    8..15   longueur         uint64  — la longueur du CLAIR d'origine

  puis N blocs scellés, à la suite, sans séparateur :
    bloc i  = nonce (12 o) ‖ chiffré (L o) ‖ MAC (16 o)
```

- Algorithme : **AES-256-GCM**, clé de 32 octets, MAC de 16 octets (128 bits).
- `L` vaut la taille de bloc pour tous les blocs sauf le dernier, qui porte le
  reste (`longueur mod taille de bloc`, ou une taille pleine si le reste est nul
  et la longueur non nulle).
- **Aucune donnée associée** (AAD vide) — ni sur l'en-tête, ni ailleurs.
- **Un nonce par bloc, tiré aléatoirement.** Ne jamais dériver un nonce d'un
  compteur : deux médias scellés avec la même clé réutiliseraient les mêmes
  nonces, ce qui casse GCM. La clé est de toute façon propre à chaque média.
- La taille de bloc **est lue dans l'en-tête**, jamais supposée. La valeur émise
  aujourd'hui est 262 144 (256 Ko), mais un lecteur qui la code en dur casserait
  sur tout fichier scellé par une version future.

### Ce que cette disposition achète

La taille scellée d'un bloc plein est **fixe** : `taille de bloc + 28`. La
position du bloc *i* se **calcule** :

```
  position(i) = 16 + i × (taille de bloc + 28)
```

Aucune table d'index à stocker, à maintenir, ni à corrompre — et un accès
aléatoire au clair en une seule lecture disque. C'est ce qui permet à un lecteur
vidéo de se déplacer dans la vidéo sans rien déchiffrer d'autre que les blocs
qu'il traverse.

### Cas limites, à traiter identiquement des deux côtés

| Cas | Attendu |
|---|---|
| Longueur 0 | en-tête seul, **aucun bloc**. Le fichier fait 16 octets. |
| Longueur multiple exact de la taille de bloc | le dernier bloc est **plein**, il n'y a pas de bloc final vide. |
| Fichier plus court que 16 octets | n'est pas du `NVC1` — refuser, ne pas deviner. |
| Magie absente | **format hérité** (§4), pas une erreur. |
| MAC invalide | **échec dur**. Ne jamais rendre d'octets non authentifiés, même partiellement décodés. |

## 3. Lecture d'un intervalle `[début, fin)`

```
  premier bloc = début ÷ taille de bloc
  dernier bloc = (fin − 1) ÷ taille de bloc
```

Chaque bloc est déchiffré **entier** (GCM n'authentifie qu'un message complet),
puis rogné : le premier au début demandé, le dernier à la fin demandée. La
mémoire vive nécessaire est donc d'**un bloc**, quelle que soit la taille du
média.

Un lecteur ne doit jamais garder en mémoire plus d'un bloc en clair à la fois,
ni écrire ce clair sur le disque — c'est le point même du format.

## 3 bis. Lecture à distance, sans télécharger le fichier

*Ajouté le 2026-08-12, objectif de Jay : première image en moins de 300 ms.*

La propriété du §2 — **la position d'un bloc se calcule** — ne sert pas qu'au
disque. Elle permet de demander au serveur exactement les octets d'un bloc, par
une requête HTTP `Range`, **sans télécharger d'index au préalable**. C'est ce qui
rend le format directement utilisable en flux, sans le changer d'un octet.

- **Amorçage** : une seule requête `bytes=0-262187` ramène l'en-tête **et** le
  premier bloc. Un aller-retour mobile coûtant 100 à 200 ms sur une cible de
  300, en demander deux (l'en-tête, puis le premier bloc) aurait suffi à
  manquer la cible. La supposition sur la taille de bloc est **vérifiée** dès
  l'en-tête lu ; si elle est fausse, la demande est refaite proprement.
- **Cache partiel** : les octets sont écrits à leur **position définitive** dans
  un fichier de la taille finale, et une carte d'un octet par bloc dit ce qui
  est présent (une centaine d'octets pour une minute de vidéo). Il n'y a
  **aucune table de correspondance à tenir** — la position se recalcule.
- **Conséquence voulue** : un cache entièrement rempli **est** le fichier scellé
  d'origine, octet pour octet. Le lecteur local et le lecteur distant partagent
  donc le même fichier et le même format — pas deux caches aux règles
  différentes pour le même objet.
- **La garantie ne bouge pas** : un bloc arrivé par le réseau est authentifié
  comme les autres. Un octet modifié en transit est refusé, jamais rendu.

Implémentation : `SealedChunkStore.kt` (`LocalChunkStore`, `RemoteChunkStore`,
`HttpRangeFetcher`), vérifiée par `PartialStreamingTest.kt` — qui mesure **le
nombre d'octets ayant réellement voyagé**, seule assertion capable de distinguer
un vrai téléchargement progressif d'un téléchargement complet déguisé.

⚠️ **Limite connue** : l'URL signée expire (une heure). C'est large pour une
session de visionnage, mais le renouvellement **en cours de lecture** n'est pas
implémenté.

## 4. Le format hérité, et sa fin

Les médias scellés **avant** le 2026-08-12 le sont en **bloc unique** : le
fichier entier en une opération GCM, sans en-tête ni magie. Ils se reconnaissent
par l'absence de `NVC1`.

**Le natif n'implémente pas ce format** — décision du 2026-08-12. Un média
hérité continue de passer par le chemin Dart, qui écrit un fichier temporaire en
clair le temps du visionnage. Ces contenus s'éteignent d'eux-mêmes (24 h pour
une story, les publications se recréent). Le jour où plus aucun ne circule,
`MediaSeal` et la branche héritée de `MediaOpen` disparaissent — voir
`RAPPELS.md`, décisions en attente #11.

## 5. La clé

- 32 octets, encodée en **base64** partout où elle transite (Dart, canal de
  plateforme, base).
- Une clé par média, jamais réutilisée entre deux médias.
- Elle ne doit **jamais** être écrite dans un journal, ni côté Dart, ni côté
  natif — y compris tronquée. Un fragment de clé dans `CamLog` serait un secret
  en clair sur le disque de l'appareil.

## 6. Vecteurs de test croisés

Les vecteurs vivent dans `android/app/src/test/resources/seal-vectors/` et sont
**lus par les deux implémentations** :

| Fichier | Contenu |
|---|---|
| `manifest.json` | pour chaque vecteur : nom, longueur du clair, clé base64, SHA-256 du clair, et des intervalles avec leur SHA-256 |
| `*.nvc1` | le média scellé |

Les vecteurs couvrent : longueur nulle, plus petit qu'un bloc, exactement un
bloc, un bloc plus un octet, plusieurs blocs à dernier partiel — plus des
intervalles **à cheval sur une frontière de bloc**, qui est l'endroit où une
implémentation fausse se trahit.

- Côté Dart : `test/sealed_format_vectors_test.dart`
- Côté Kotlin : `android/app/src/test/kotlin/com/neovibe/neovibe/SealedChunkReaderTest.kt`

**Les vecteurs sont figés.** Ils ne sont régénérés (`dart run
tool/gen_seal_vectors.dart`) que si le format change délibérément — auquel cas
ce document change dans le même commit, et les deux implémentations aussi. Un
vecteur régénéré « pour faire passer le test » annule tout l'intérêt du
dispositif.
