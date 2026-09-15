# Plan — les publications à plusieurs médias (chantier B2, « l'album »)

> Écrit le 2026-09-15 après la spécification de Jay (rapport
> `rapports-de-sessions/2026-09-15_00-34.md` §3), sur carte blanche :
> *« tu fais tout à fond et comme Instagram, la seule différence sera
> l'affichage du format »*. Suite du chantier A (`docs/plan-refonte-partage.md`).
>
> ✅ **CONSTRUIT le 2026-09-15 (v0.9.185)**, en une passe, les cinq étapes de
> §7. Ce qui s'écarte du plan et ce qui reste à vérifier sur l'appareil : §9.

---

## 0. Ce que Jay a tranché le 2026-09-15

| Sujet | Décision |
|---|---|
| Contenu d'une publication | **jusqu'à 11 médias** (photos et vidéos mêlées), **feuilletés à l'horizontale**, une **légende** |
| Format | **comme Instagram** : un seul ratio pour toute la publication, images comme Instagram. ⚠️ **Précisé après le test de la v0.9.185** : *« on avait dit vertical comme sur Instagram »* → **3:4 uniquement**, plus de choix (les 1:1 · 4:5 · 1.91:1 du premier jet sont retirés de l'éditeur ; un album déjà publié garde son ratio) |
| Sources | **galerie ou caméra** (l'appareil photo du téléphone) |
| Vidéo | **pas de 4K** ; **1 min max par média** ; une vidéo plus longue → **proposer de la découper** et répartir automatiquement sur plusieurs médias du carrousel, dans la limite des 11 |
| Éditeur | **digne d'Instagram**, sans les musiques ; « pour le reste tu pousses tout au max » |
| Où ça apparaît | **la grille du profil** (la bibliothèque) ; **le feed** si rendue publique. **Pas** dans le partage de Vibe ni de story. Le partage reste possible par « ajouter au feed d'un ami » |
| 🔴 La grille | **identique** : même conteneur, même format Card pour toutes les vignettes ; **seul le visionneur change** à l'ouverture |
| Le visionneur « deck » (carrousel de mini-cards) | **supprimé** ; son bouton devient **le bouton pour ajouter une publication** |
| Le « + » | ouvre un choix : **une Vibe** (notre caméra, restreinte à la publication) ou **des photos / vidéos** (l'éditeur) |
| Grille de décision (§7 du chat) | « je sais et c'est assumé » |

*« On construit un système hybride en promouvant le plus notre format Card
mais en gardant la possibilité de publier du contenu vertical puisque notre
format Card est limité dans la création de contenus classiques. »*

---

## 1. Vocabulaire

| Mot | Ce que c'est |
|---|---|
| **Publication** | tout ce qui est dans la bibliothèque du profil — le mot public, inchangé |
| **Card** (publication) | le format existant : une ou deux faces, retournement — `library_items.kind = 'card'` |
| **Album** | le nouveau format : 1 à 11 médias feuilletés, un ratio, une légende — `library_items.kind = 'album'`. Le mot n'apparaît **pas** dans l'interface (on dit « publication ») |
| **Média** | une photo ou une vidéo d'une publication, à sa place (`slot`) |

---

## 2. L'architecture — un contenu, un juge, plusieurs médias

**Constat (vérifié en base le 2026-09-15)** : une publication Card et un
album obéissent **aux mêmes règles** — même audience (`publication_audience`),
même durée de vie (permanente), aucune limite de vues, mêmes droits
partageable / sauvegardable portés par `contents`. Ce qui diffère est **le
format** (des faces qu'on retourne, des médias qu'on feuillette). La règle 2
de `CLAUDE.md` (deux objets aux règles différentes ne partagent pas la table)
ne s'applique donc pas : **c'est le même objet, avec deux formats**.

➡️ **`library_items` reste l'en-tête unique** de toute publication, et gagne
`kind` (`card` / `album`) et le ratio de l'album. **Les médias sortent dans
une table enfant `library_media`** (`item_id, slot, path, is_video,
duration_ms, poster_path, width, height`), **pour les deux formats** : une
Card y a ses faces aux places 0 et 1. Les colonnes `front_path` /
`back_path` / `front_is_video` / `back_is_video` **disparaissent** — un
chemin, une donnée (règle « un chemin, une donnée » du 2026-08-25).

Ce que ça donne côté règles : **aucune règle ne change de juge**.
`publication_audience(item)` reste la seule question ; `can_view_publication_file`
cherche le fichier dans `library_media` au lieu de deux colonnes ; le
déclencheur des octets à supprimer passe sur `library_media` (une ligne par
fichier, cascade depuis l'en-tête) ; `library_media_keys` et
`open_content_media` ne bougent pas (une clé par contenu, commune à tous ses
médias — comme les deux faces d'une Card aujourd'hui).

**Le socle Dart** (`ContentFace`, `ContentMediaCache`, `ContentPreloader`)
est aujourd'hui écrit en `front: bool`. Il passe en **`slot: int`** (0 = recto,
1 = verso) : le même chemin scellé → clé → clair sert les 11 médias d'un album
comme les 2 faces d'une Card. Stories et Vibes de chat gardent leur propre
front/back ; seule la bibliothèque est concernée par la table enfant.

**Le modèle `LibraryItem`** porte `kind`, `aspect` et `media: List<LibraryMedia>` ;
`frontPath` / `backPath` / `hasBack` deviennent des **lectures dérivées** des
places 0 et 1 — les écrans Card n'ont rien à réapprendre.

---

## 3. Serveur

Migration `20260915120000_les_albums.sql` :

1. `library_kind` (`card`, `album`) ; `library_items.kind` (défaut `card`),
   `aspect_w`, `aspect_h` (nuls pour une Card) ; `caption` inchangée.
2. `library_media` + reprise des 43 publications existantes (faces → places
   0/1), puis suppression des quatre colonnes de faces.
3. `publish_to_library` réécrite : `p_kind`, `p_media jsonb` (liste ordonnée
   `{path, is_video, duration_ms, poster_path, width, height}`), `p_aspect_w/h`.
   Contrôles serveur : 1 à 11 médias, chemins sous `<me>/`, `duration_ms ≤ 60 000`
   pour une vidéo, un ratio parmi les trois. Un seul appelant Dart.
4. `can_view_publication_file` via `library_media` (chemin **ou** poster).
5. Déclencheur `library_media_octets_a_supprimer` (le poster aussi) ; celui
   de `library_items` retiré (ses colonnes n'existent plus).
6. `profile_stats` relue (compte d'en-têtes, inchangée).
7. RLS de `library_media` : lecture par `publication_audience(item_id)`,
   écriture par le propriétaire (via la RPC seulement).

Rejoué sous RLS avant livraison : le propriétaire, un ami, un inconnu, un
bloqué ; fichier d'un média de place 7 ; poster d'une vidéo.

---

## 4. Client — de la grille au visionneur

| Pièce | Fichier | Rôle |
|---|---|---|
| Modèle | `core/models/library_item.dart` (+ `LibraryMedia`, `LibraryKind`, `AlbumAspect`) | égalité de valeur |
| Socle | `core/content/content_face.dart`, `content_media_cache.dart`, `content_preloader.dart` | `front` → `slot` |
| Dépôt | `library/library_repository.dart` | `publishCard(...)` (l'existant, réécrit sur `library_media`) et `publishAlbum(draft, onProgress)` : scelle chaque média et son poster avec **la même clé**, dépose, puis la RPC |
| Grille | `library/mini_card.dart` | `kind == album` : couverture = place 0 (poster si vidéo), **même cadre 9:16, même liseré**, pastille « ▣ N » à la place du tag de type ; pas de retournement ; tap → visionneur d'album |
| Profil | `library/profile_screen.dart`, `user_library_screen.dart` | le deck **supprimé** (`library_deck_screen.dart`, un seul lecteur de son import) ; le bouton « Parcourir en deck » devient « Publier » ; le `FloatingActionButton` d'import direct **retiré** (le nouveau chemin le remplace) |
| Choix | `library/publish_choice_sheet.dart` | « Une Vibe » → caméra Card restreinte à la publication (`VibeShareContext` restreint) ; « Photos ou vidéos » → l'éditeur |
| Visionneur | `library/album_viewer_screen.dart` | `PageView` horizontal, points, légende, mêmes actions que la Card (enregistrer le média courant, repartager, retirer, signaler), `PullDownToClose`, préchargement des voisins |

---

## 5. L'éditeur — `lib/features/library/album_editor/`

Écrit **chez nous**, comme le recadreur d'avatar et pour la même raison
(*« ce qui se passe sur NeoVibe reste sur NeoVibe »* — un éditeur tiers
verrait passer les photos en clair) : voir `avatar_cropper_screen.dart`.

| Étape | Écran | Ce qu'on y fait |
|---|---|---|
| 1 | **Choisir** (`album_picker.dart`) | galerie (multi, photos + vidéos, `image_picker` 1.2 `pickMultipleMedia`) ou l'appareil photo / la caméra du téléphone ; plafond 11 ; une vidéo > 60 s → proposition de **découpe** en morceaux de 60 s, répartis sur les places libres |
| 2 | **Éditer** (`album_editor_screen.dart`) | en haut l'aperçu dans le cadre du ratio ; en bas la bande des médias, **réordonnable** au doigt, avec « + » ; trois onglets : **Cadrer** (ratio commun 1:1 · 4:5 · 1.91:1, déplacement + zoom par média) · **Filtres** (presets nommés) · **Réglages** (luminosité, contraste, saturation, chaleur, teinte, fondu, vignette — par média) ; pour une vidéo : **rogner** (début / fin, ≤ 60 s), image de couverture choisie sur la frise |
| 3 | **Publier** (`album_caption_screen.dart`) | légende, visibilité (selon mes règles / publique), partageable, sauvegardable → **Publier** : l'envoi part en arrière-plan avec un bandeau « Publication… n/N » sur le profil |

**Le rendu est le même à l'aperçu et à l'export** : filtres et réglages sont
**une matrice de couleurs 4×5** (`ColorFilter.matrix`) + une vignette. La
photo exportée est dessinée par Flutter (`Canvas` + `ColorFilter`, recadrage
par matrice, sortie ≤ 1440 px), puis encodée en JPEG par le natif. La vidéo
passe par le **transcodeur natif** avec la même matrice dans son shader.

`album_draft.dart` : le brouillon est un modèle **pur et testé** (places,
ratio, recadrage, réglages, rognage, découpe) — l'éditeur ne fait qu'afficher
et l'export ne fait que lire.

---

## 6. Natif — `MediaTranscoder.kt` (nouveau) et `NativeMedia.kt` (étendu)

- **`MediaTranscoder`** : décodeur `MediaCodec` → `SurfaceTexture` → shader
  GL (recadrage par coordonnées de texture, matrice de couleurs, vignette) →
  encodeur H.264 sur `Surface` → `MediaMuxer` ; piste audio recopiée
  (`AAC` transcodée si le conteneur n'est pas AAC) ; **rognage** `startMs` /
  `endMs` ; sortie ≤ 1080 sur le grand côté, **3,5 Mbit/s** (le plafond des
  Cards, limite d'upload 50 Mo — `RAPPELS.md` #7). Même famille de code que
  `Camera2Gl.setupEncoder` / `drainEncoder`, volontairement **séparé** de la
  caméra (le chemin caméra n'est pas touché).
- **`NativeMedia`** : `probe` (durée, dimensions, rotation), `videoThumbnail`
  à un instant donné (existe), `encodeJpeg` (RGBA → JPEG).
- Catalogue `docs/parties-natives-par-os.md` mis à jour (équivalent iOS :
  `AVAssetExportSession` + `AVVideoComposition` / `CIFilter`).

---

## 7. L'ordre de construction — chaque étape livrable seule

1. **Serveur + modèle + socle `slot`** : rien ne change à l'écran, tout
   existant repasse (grille, visionneur Card, repartage, sauvegarde).
2. **Profil** : deck supprimé, bouton « Publier », feuille de choix, chemin
   « Une Vibe » (caméra restreinte).
3. **Visionneur d'album + vignette** (testables avec un album inséré en base
   par `tool/`).
4. **Éditeur photos** (choisir, cadrer, filtres, réglages, ordonner, légende,
   publier).
5. **Vidéos** : sonde, frise, rognage, découpe, transcodeur natif, poster.

---

## 8. Ce que ce plan ne fait pas

- Le **feed** (il lira `library_items` où `is_public`, les deux formats).
- Les **musiques** (écartées par Jay), le texte sur l'image, les autocollants.
- Les vignettes vidéo des **Cards** (`RAPPELS.md` #4) : le poster n'est
  obligatoire que pour les vidéos d'album — l'ajouter aux Cards vidéo est une
  ligne de plus dans `publishCard`, à faire dans la foulée si le temps le permet.

---

## 9. Ce qui a été construit, et ce qui s'écarte du plan (2026-09-15)

| Pièce | Fichier | Note |
|---|---|---|
| Serveur | `supabase/migrations/20260915120000_les_albums.sql` | comme §3, plus **`library_media.owner_id`** : au rejeu, le déclencheur des octets à supprimer tournait *après* la suppression de l'en-tête (cascade depuis `contents`) et ne trouvait plus le propriétaire — zéro pierre tombale. Le propriétaire est donc sur la ligne de média, comme `old.owner_id` dans l'ancien déclencheur. 17 contrôles sous RLS (propriétaire, ami, inconnu ; chemins hors dossier, 61 s, album vide, ratio 3:2 refusés ; fichier et poster de la place 7 ; clé en lot ; jointure PostgREST ; écriture directe refusée ; suppression → 0 média, 9 pierres tombales) |
| Socle | `content_face.dart` (`ContentSlot`, `slot: int`), `content_media_cache.dart`, `content_preloader.dart` | les places 0 et 1 gardent leurs anciens noms de fichier et suffixes (`front`/`back`, `f`/`b`) : les caches déjà posés restent valables. **« Complet » par place** dans l'index (un ancien `true` se lit comme « la place 0 »). La couverture d'une vidéo d'album a sa place fictive `100 + n` |
| Modèle | `library_item.dart` : `LibraryKind`, `AlbumAspect`, `LibraryMedia`, `LibraryItem.media`, `LibraryItem.select` | `frontPath` / `backPath` / `hasBack` dérivés ; `cardType` reste non nul (défaut `standard` pour un album, n'habille que le liseré) |
| Dépôt | `library_repository.dart` : `publish` (Card) et `publishAlbum` sur un seul `_publish` | une clé pour tous les médias ; les couvertures aussi en cache `own/` |
| Grille | `mini_card.dart` | album : couverture (poster si vidéo), pastille ▣ N ou ▶, pas de retournement, → `AlbumViewerScreen` |
| Visionneur | `album_viewer_screen.dart` | `PageView` au ratio, points, légende, enregistrer le média affiché (`id#place`), repartager, retirer, signaler, `PullDownToClose`, média suivant demandé d'avance |
| Profil | `profile_screen.dart`, `user_library_screen.dart`, `publish_choice_sheet.dart` | deck supprimé (`library_deck_screen.dart` retiré, un seul lecteur de son import), bouton « Publier » à sa place, **le bouton flottant d'import direct retiré** (l'éditeur le remplace), `AlbumPublishBanner` en tête |
| B1 — Une Vibe | `card_capture_screen.dart` (`publicationOnly`), `share_context.dart` (`libraryOnly`), `recipient_picker_screen.dart` | bibliothèque cochée d'office et non décochable, pas de story, pas de recherche, pas de « Groupes et amis », pas d'événement ; après l'envoi, retour au profil |
| Éditeur | `album_editor/` : `album_draft.dart` (pur), `color_grade.dart` (pur), `album_picker.dart`, `album_editor_screen.dart`, `album_caption_screen.dart`, `album_export.dart`, `album_publish_queue.dart`, `album_publish_banner.dart`, `album_flow.dart` | photos ramenées à ≤ 2160 px par `image_picker` avant l'éditeur ; export **1080 de large** (`AlbumExport.outputSize`, seule définition) ; 19 filtres = des `ColorGrade` ; 7 réglages posés par-dessus le filtre ; vignette = un voile radial à huit arrêts qui suit `Vignette.alphaAt` (aperçu et export) ; vidéo : aperçu par `video_player` en boucle sur le morceau, rognage `RangeSlider` ≤ 60 s, couverture choisie, découpe proposée à l'import |
| Natif | `MediaTranscoder.kt` (nouveau), `NativeMedia.kt` (+ `probe`, `encodeJpeg`, `transcode`, `videoThumbnail(atMs)`) | `docs/parties-natives-par-os.md` § 4 bis |
| Tests | `album_draft_test.dart` (24), `library_item_media_test.dart` (5) | 489 au total |

**À vérifier sur l'appareil — écrit sans téléphone** (`RAPPELS.md` #135) : le
sens de la rotation défaite dans le transcodeur pour une vidéo portrait ;
l'aperçu d'une photo couchée ; le temps de rendu d'une vidéo de 60 s.

**Limites écrites** : un seul album à la fois ; l'envoi ne survit pas à la mort
de l'app ; une vidéo sans piste AAC sort sans son ; les vidéos de Card n'ont
toujours pas de vignette (`RAPPELS.md` #4).

### 9.1 Retouches après le premier test de Jay (2026-09-15, v0.9.186)

| Vu par Jay | Cause | Fait |
|---|---|---|
| « Le format n'est pas bon, on avait dit vertical comme sur Instagram » | le premier jet offrait les trois ratios d'Instagram (1:1 · 4:5 · 1.91:1), défaut 4:5 ; Jay avait cadré en 1:1 | **3:4 uniquement** (tranché par Jay) : `AlbumAspect.tall`, `AlbumDraft.aspect` fixe, le sélecteur de ratio retiré de « Cadrer » (reste le geste + « Réinitialiser le cadrage »), `withAspect` supprimé ; migration `20260915180000_les_albums_en_3_4.sql` ajoute 3:4 aux ratios admis — l'album de test en 1:1 reste lisible à son ratio |
| dans la caméra restreinte, la feuille ⚙︎ montre les réglages de story | la feuille ne savait pas qu'elle servait une publication seule | `PublicationSettingsSheet.libraryOnly` : le bloc « Ma story » n'est pas dessiné |
| la vidéo sort couchée | **la rotation valait 0** : elle était lue sur le format de la piste (`MediaExtractor`), qui ne la portait pas sur le Xiaomi — la vidéo sortait telle que stockée (une prise portrait est rangée couchée, avec une étiquette de rotation). La vignette, elle, venait de `MediaMetadataRetriever`, qui la lit — d'où une vignette droite et une vidéo couchée | la rotation vient de la **sonde** (`probe`, déjà portée par `AlbumDraftMedia.rotation`) et passe à `transcode(rotation:)` ; `KEY_ROTATION` est mis à 0 sur le format donné au décodeur pour qu'aucun décodeur ne tourne de son côté (sinon deux fois). ⚠️ Le sens du redressement reste **à confirmer** au test suivant |

### 9.2 « Tout au max, comme Instagram » — v0.9.187 (2026-09-15)

Jay, captures d'Instagram à l'appui : *« c'est encore trop moyen […] tu
pousses tout au max, tu as carte blanche mais tu dois faire un rendu pro et
ergonomique, épuré comme le veut notre DA »*. Le principe tenu : **chaque
effet est défini une fois**, en pur Dart, et consommé par trois moteurs —
l'aperçu, l'export photo (un shader Flutter), le transcodeur vidéo (le même
shader en GL).

| Pièce | Fichier | Ce que c'est |
|---|---|---|
| **La galerie dans l'app** | `gallery/native_gallery.dart` (pont), `gallery_feed.dart` (pages + vignettes en cache LRU, cuisine), `gallery_screen.dart` (« Nouvelle publication » : grand aperçu 3:4, grille 4 colonnes, sélection **numérotée**, appareil photo en première case, permission expliquée), `gallery_import.dart` (copie, sonde, découpe des vidéos longues, appareil photo) | `NativeGallery.kt` ; l'ancien `album_picker.dart` (sélecteur système) supprimé |
| **La géométrie** | `crop_geometry.dart` (pur, 10 tests) | rectangle **inscrit** dans l'image tournée (jamais de coin vide), coins du cadre en coordonnées source, matrice équivalente, gestes ; `CropSpec` gagne `angle` (redresser ±45°) et `turns` (quarts de tour) |
| **Les couleurs** | `color_grade.dart` : + `shadows`, `highlights`, `sharpen`, `lux` (replié dans les autres par `resolved`), `scaled` (intensité), **`toUniforms()` = le contrat des shaders** (24 nombres) | 5 tests de plus |
| **Le shader** | `shaders/album_grade.frag` (Flutter) et le `FRAGMENT` de `MediaTranscoder.kt` (GL) — **la même formule** ; `grade_shader.dart` (`GradeShader.paint`, `GradePainter`, `GradedThumbPainter`) | l'aperçu photo et l'export photo passent par le même dessin |
| **Les calques** | `overlay_model.dart` (pur : `TextOverlay` — 6 polices, 14 couleurs, fond plein / translucide, alignement ; `StickerOverlay` — émoji ou image ; gestes bornés, `hits`), `overlay_painter.dart` (**le seul dessin**, aperçu et export), `text_editor_screen.dart`, `sticker_picker.dart` | pour une vidéo, le calque est rendu en PNG à la taille de sortie et brûlé par le transcodeur |
| **L'éditeur** | `editor_theme.dart` (sombre, épuré, l'accent de l'identité), `editor_images.dart` (images décodées, bornées, libérées), `media_preview.dart` (photo par le shader, vidéo par `CropGeometry.matrix`, calques, gestes, corbeille), `album_editor_screen.dart` (5 outils façon Instagram, panneaux **Annuler / Terminé** avec instantané, Filtre à **intensité au second tap**, Modifier en ronds : Redresser · Lux · Luminosité · Contraste · Chaleur · Saturation · Teinte · Hautes lumières · Ombres · Fondu · Vignette · Netteté, Rogner) | `album_caption_screen.dart` et la galerie dans le même thème |
| **L'export** | `album_export.dart` : photo = `GradeShader.paint` + `OverlayPainter` sur un canvas 1080×1440 → JPEG natif ; vidéo = coins + uniformes + PNG des calques → transcodeur | `EditorImages.decodeBounded` (`ImageDescriptor`, sans double décodage) |

**Ce que l'aperçu vidéo ne montre pas** : ombres, hautes lumières et netteté
(le lecteur ne passe pas par notre shader) — ils s'appliquent au rendu final.
Filtre, réglages linéaires, vignette, cadrage et calques se voient.

**Exclu, dit à Jay** : les musiques (sa décision), le direct, les modes
Story / Reel de la caméra Instagram (hors chantier), Tilt Shift et « Couleur »
(second temps).
