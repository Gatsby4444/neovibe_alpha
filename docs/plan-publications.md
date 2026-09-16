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
| Visionneur | ~~`library/album_viewer_screen.dart`~~ → **`library/feed/`** depuis la v0.9.189 (§9.4) | le fil du profil (`PublicationsFeedScreen`) et le plein écran des Vibes (`VibesReelScreen`) |

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

### 9.3 Retours de Jay sur la v0.9.187 — v0.9.188 (2026-09-15)

*« Cela ne convient pas encore. Il y a plusieurs problèmes. »* Six points ;
le 4 (le visionneur de la bibliothèque) est mis de côté — *« on va le
reconstruire de A à Z »*.

| # | Vu | Cause | Fait |
|---|---|---|---|
| 1 | galerie : beaucoup de cases noires, très lente | chaque vignette demandée au système à l'affichage, dans l'ordre d'arrivée, sur 3 fils : les cases visibles attendaient derrière celles déjà sorties de l'écran ; une vignette refusée par le système restait grise, indiscernable d'une attente | `GalleryFeed` : **file LIFO** (la dernière demandée part la première), six en vol, une case qui disparaît **retire** sa demande (`forget`) ; `NativeGallery.kt` : autant de fils que de cœurs (≤ 6), **repli** quand `loadThumbnail` refuse (décodage réduit + EXIF, ou première image d'une vidéo) ; trois états distincts à l'écran (attente, image, refusée) ; vignettes de 256 px, aperçu de 720 |
| 2 | la grille à peine visible (deux lignes) | l'aperçu prenait un 3:4 plein largeur | la grille est un **panneau qu'on tire** (`DraggableScrollableSheet`, de 42 % à **80 %** de l'écran, avec crans) par-dessus l'aperçu |
| 3 | thème clair / sable : interface en noir, textes et boutons illisibles | l'éditeur forçait un thème sombre « comme Instagram » | **la DA prime** : `EditorColors.of(context)` lit la palette de l'identité ; plus aucun `Theme` forcé (éditeur, galerie, légende, autocollants, appareil photo). Seul le fond derrière l'image reste un gris neutre, et ce qui se pose sur l'image reste blanc sur voile sombre |
| 5 | le cadrage « pas pro » : on ne voit pas bien l'image, on ne sait pas ce qui sera publié | le cadre 3:4 était tout l'aperçu | `MediaPreview` refait : **l'image entière est visible, assombrie hors du cadre** ; le cadre est délimité ; **grille des tiers** pendant le geste ; bouton **Adapter / Remplir** (`CropSpec.fitZoom`, zoom < 1 = l'image entière avec bandes noires ; les deux shaders peignent noir hors de l'image) ; ce qui est clair est exactement l'export |
| 6 | l'éditeur de texte : un encadré avec fond et « Écris… », qui perd l'utilisateur | l'écran de texte à part, avec le champ du thème (fond sable) et une invite | **le texte se tape sur l'image** (`_InlineTextField` dans l'aperçu) : ni fond, ni bordure, ni invite, le curseur seul ; même police, même taille, même largeur maximale que le peintre (`OverlayPainter.textStyle`) ; centré, il grandit des deux côtés et passe à la ligne au bord ; en écriture, la barre du bas devient police · couleur · alignement · fond et « Terminé » ; **après, le déplacement est bloqué au bord du cadre** (`OverlayObject.clampedTo`, boîte tournée comprise), jamais reformaté |

Tests : +5 (`clampedTo`, Adapter / Remplir) — **509**.

### 9.4 « Voir les publications » — v0.9.189 (2026-09-15)

*« C'est beaucoup mieux, maintenant on a une très bonne base. »* Jay a
tranché la suite : **deux fils, deux types de contenus** — les Vibes se
regardent comme des Reels, les albums comme un feed de publications ; et le
profil, comme Instagram, mène aux deux. Trois réponses : **oui aux likes**,
**oui au plein écran des Vibes tout de suite**, **oui à la même page pour le
profil d'un autre**.

**Ce qui change pour l'utilisateur.** Toucher une case de la grille n'ouvre
plus une publication seule : on arrive sur **la page des publications de ce
profil**, posée sur celle qu'on a touchée, et on **fait défiler** les autres
(Cards et albums mêlés, dans l'ordre du profil). Chaque publication a son
en-tête (qui, quand), son média, ses actions (aimer · enregistrer · partager
· retirer / signaler), sa légende. Une Vibe s'y **retourne sur place** ; la
toucher l'ouvre **en plein écran façon Reels** : une Vibe par écran, on
glisse vers le haut pour la suivante, les actions à droite, l'auteur et la
légende en bas ; tirer vers le bas depuis la première ferme. Le cœur compte
les likes ; toucher le compte dit **qui a aimé**.

| Pièce | Fichier | Rôle |
|---|---|---|
| **Les likes, serveur** | `20260915210000_les_likes.sql` | `content_likes (content_id, user_id)` sur **`contents`** — un like porte sur le contenu, quel que soit son format ; lecture et pose gardées par `private.content_audience` (on n'aime que ce qu'on peut voir) ; `content_likes_summary(uuid[])` (compte + « moi ») pour tout un fil en un appel, `toggle_like`, `content_likers` (qui, quand ; 200 max, `security definer` pour lire les profils) |
| **Les likes, client** | `core/content/likes.dart` | `LikesStore` : un état par contenu, `load` en lot, `toggle` **optimiste** (le cœur répond au doigt, le serveur confirme, sinon retour) |
| **La cellule** | `feed/publication_cell.dart` | **LA** cellule d'un fil, réutilisée demain par le feed local : en-tête (`timeAgo`, type de Vibe en pastille, tap → le profil), média, actions, légende dépliable ; la vue se compte quand la cellule est **active** |
| **Qui est actif** | `feed/active_item_tracker.dart` | la cellule visible à plus de la moitié dont le centre est le plus près du centre de l'écran ; c'est elle qui joue ses vidéos et compte sa vue — jamais deux à la fois |
| **L'album** | `feed/album_carousel.dart` | `PageView` horizontal au ratio, « n/N », points, vidéo en boucle muette (tap = son), média suivant demandé d'avance |
| **La Vibe** | `feed/vibe_card_view.dart` | la carte recto/verso retournable (`FlippableCard`, axe horizontal), même composant en cellule et en plein écran |
| **Les actions** | `feed/publication_actions.dart` | à plat ou en colonne ; `LikeButton`, `SaveButton`, repartage (`RecipientPickerScreen` en mode repost), retirer / `ContentOverflowMenu` ; `showLikers` |
| **Le fil du profil** | `feed/publications_feed_screen.dart` | la liste, **ancrée** sur la publication touchée (`core/widgets/anchored_list.dart` — elle est l'origine du défilement, rien n'est estimé) ; `openPublications(context, items, index)` |
| **Les Vibes plein écran** | `feed/vibes_reel_screen.dart` | `PageView` vertical, une Vibe par page ; fermeture par **sur-défilement** depuis la première (la liste tient le geste vertical, on lit ce qu'elle rapporte — même décision et même animation que `PullDownToClose`) |
| **Les grilles** | `mini_card.dart` (`onTap`), `profile_screen.dart`, `user_library_screen.dart` | la grille décide où mène le tap : le fil de **ce** profil, avec **sa** liste |
| **Le chat** | `chat_screen.dart` | une publication repartagée s'ouvre dans le même fil, seule |
| **Supprimés** | `publication_viewer_screen.dart`, `album_viewer_screen.dart` | les deux visionneurs à un contenu ; leurs appelants (grille, chat) et ce qu'ils appelaient (relevés : tout reste utilisé ailleurs) |

**Ce qui reste à faire ensuite** : le **feed** lui-même (les deux sources :
la géographie, et ce que les amis ont **ajouté** — anonyme jusqu'au like, qui
ouvre le chat 24 h ; le scroll qui se durcit vers 60) — la cellule, le
suivi d'activité, le carrousel, la carte et les likes sont prêts à y être
branchés tels quels.

### 9.5 Premier test de Jay sur la v0.9.189 — v0.9.190 (2026-09-15)

*« Correct mais pas encore satisfaisant. »* Trois points.

| # | Vu | Cause | Fait |
|---|---|---|---|
| 1 | en retournant une Card du fil, « un flash de la face d'une autre card » | la face **photo** prenait la hauteur de l'image *une fois décodée* — zéro avant. Le verso retourné est un widget neuf : la cellule s'écrasait à 37 px (marge + liseré) le temps d'une image, la liste remontait pour combler, la Card **suivante** passait sous le doigt, puis tout revenait | **toute face impose le portrait 9:16 dans tous ses états** (`kVibeFaceRatio` : en attente, photo, vidéo, erreur — `vibe_face.dart`). Test `vibe_face_layout_test.dart` avec contre-test (37 px sans, 398 px avec) |
| 2 | retourner la dernière Card fait remonter la page d'une Card | même cause : tout en bas, la liste « trop courte » d'une Card ramène la position au nouveau bas, et quand la cellule regrandit la position ne revient pas | même réparation |
| 3 | *« on avait choisi de supprimer la direction 3D avec le doigt, mais tu l'as laissée pour les Cards à simple face »* — et Jay constate que **le geste libre et le défilement cohabitent très bien** | le 2026-09-14 j'avais affirmé qu'on ne pouvait pas avoir les deux (le vertical à la fermeture) et remplacé le geste libre par une inclinaison « à l'attrape » ; la seule Card à l'avoir gardé était celle que j'avais oubliée. **Vérifié dans la source de Flutter** (`gestures/monodrag.dart`) : le reconnaisseur vertical de l'écran n'accepte que sur sa composante, à 18 px ; le geste libre de la carte accepte à 36 px de distance totale ; le premier qui accepte gagne. **Un départ vertical va à l'écran, un départ horizontal à la carte — puis tout le geste lui appartient** | **le geste libre remis partout** (fil, Vibes plein écran, chat, stories, sauvegardes, Drop) : `TiltableCard` et `FlippableCard` perdent `fullScreen` et `tiltAtGrab` ; seules les **mini-cards** de la grille gardent l'axe contraint (distance fixe, elles sont trop petites). Test `card_gesture_arena_test.dart` : dans une liste, un départ vertical défile sans toucher la carte, un départ horizontal retourne sans défiler |

Défaut latent attrapé par ce test : le contrôleur d'animation de
`TiltableCard` était un `late final` avec initialiseur — pour une carte jamais
touchée, son premier accès était `dispose()`, qui créait un ticker sur un
élément démonté. Créé dans `initState` désormais. Tests : **512**.

### 9.6 Deuxième test de Jay sur la v0.9.190 — v0.9.191 (2026-09-16)

*« Mon test révèle encore des bugs UI qui nuisent à l'UX. »* Deux points, plus
« vérifie le reste aussi ».

| # | Vu | Cause | Fait |
|---|---|---|---|
| 1 | *« cliquer sur une card dans le profil ouvre le viewer, mais pas en face de la card »* — son hypothèse : les hauteurs qui s'adaptent à l'image | le fil **estimait** le décalage (une hauteur devinée par publication) puis corrigeait *si* la cellule visée avait été construite. La correction n'a lieu que si l'estimation tombe à moins d'un `cacheExtent` de la vérité ; l'erreur s'accumulant à chaque cellule, au-delà d'une vingtaine de publications la cellule n'existe pas et **plus rien ne corrige** — sans erreur levée | **`AnchoredList`** (`core/widgets/anchored_list.dart`) : la publication touchée **est** l'origine du défilement (`CustomScrollView.center`), les précédentes vivent aux décalages négatifs. Exact quels que soient le nombre d'éléments et leurs hauteurs — plus rien à estimer. `test/anchored_list_test.dart` (4), contre-test fait (sans l'origine, 3 tests rouges) |
| 2 | *« dans le viewer, spécialement pour les cards, les boutons ne sont pas bien placés »* (le cœur sur la carte, le marque-page à cheval sur son bord) | la carte prenait toute la largeur et la colonne d'actions était un `Positioned` **par-dessus** | **`ReelLayout`** : la carte au centre de ce qui reste, les actions dans une **gouttière** réservée à droite calées sur le bas de la carte, l'auteur **sous** la carte, la bande de la croix réservée en haut. `test/reel_layout_test.dart` (5) mesure les trois boîtes, contre-test fait (l'ancienne superposition → rouge) |

**Le reste, vérifié à la source :**

- **Les icônes système invisibles sur un écran noir.** Le thème fixe
  `systemOverlayStyle` pour **toutes** les AppBar (identité claire → icônes
  sombres) ; une AppBar noire en héritait donc, icônes sombres sur noir.
  Vérifié dans `material/app_bar.dart` : la déduction par luminosité du fond
  n'a lieu que si personne n'a répondu avant, et le thème répond toujours.
  → `core/widgets/system_bars.dart` (`kSystemBarsOnDark`, `DarkSystemBars`),
  passé aux 8 AppBar noires et aux 2 écrans noirs sans AppBar (les Vibes
  plein écran, le visionneur de story).
- **La cellule d'une Vibe dans le fil** : la largeur de la carte se calculait
  sans son cadre (marge + liseré), donc la carte était ~30 px sous le plafond
  de 72 % annoncé (`VibeFaceFrame.chrome(type)`, une seule définition) ; et la
  ligne d'actions partait du bord de l'écran alors que la carte est centrée —
  toute la cellule se cale maintenant sur la largeur de la carte.
- **Le contrôleur de pages des Vibes plein écran** ne se recalait pas après un
  « Retirer » : en supprimant la dernière, il pointait hors de la liste.
- **Le compte de likes à zéro** affichait un libellé vide, qui occupait une
  ligne et décalait la colonne du plein écran.

### 9.7 Troisième passe sur le visionneur — v0.9.192 (2026-09-16)

Jay sur la v0.9.191 : *« ok c'est mieux sauf pour les boutons dans le plein
écran car en fait tu as décalé la card et donc elle n'est plus centrée, ce
n'est pas joli »*. Quatre demandes.

| # | Demande de Jay | Fait |
|---|---|---|
| 1 | *« incorporer les boutons dans la card à droite, mais qu'ils bougent avec la card de manière dynamique (les mêmes des deux côtés et mêmes états) »* | `VibeFaceFrame.overlay` : un calque **dans le cadre**, donc dans le `Transform` de la carte — il s'incline et se retourne avec elle. `VibeCardView.overlay` le passe aux **deux faces** (et aux états d'attente) : c'est le **même widget** des deux côtés, et ce qu'il affiche (aimé ? enregistré ?) vient des providers, jamais de la face — les deux ne *peuvent pas* diverger |
| 2 | *« mettre toute la partie (PP, username, date, type) au-dessus et pas en dessous, et de même incorporée à la card »* | `VibeCardChrome` (`feed/vibe_card_chrome.dart`) : identité en haut, actions en colonne à droite, légende en bas — plus deux voiles dégradés pour que le blanc reste lisible sur une image claire. La croix reste **par-dessus et fixe** (fermer est une commande de l'écran), et passe en haut à **droite** puisque le haut-gauche de la carte porte l'identité |
| 3 | *« pour les boutons dans la vue fil, mets-les aussi en haut à droite, au-dessus de la card, sur la même ligne que la pp et l'username, à l'horizontal, car dans le format actuel on ne peut pas bien voir toutes les parties du contenu sur l'écran en une fois »* | l'en-tête de `PublicationCell` prend les actions à droite, **resserrées** (`ActionMetrics`, `dense`) ; la rangée sous le média disparaît (−48 px par cellule). Date et type passent sur une deuxième ligne sous le pseudo, mises à l'échelle (`FittedBox`) : « One of One » ne rentre pas toujours à côté de la date dans une cellule de Vibe |
| 4 | *« pour les deux vues, mets le bouton supprimer dans un menu qui affichera les options puisqu'on va en ajouter »* | la corbeille quitte la barre ; `ContentOverflowMenu` gagne `mine` + `onRemove` : **un seul « … » partout**, qui montre les options du propriétaire sur mon contenu (« Retirer » aujourd'hui, les suivantes demain) et celles de la modération sur celui des autres. On ne se signale toujours pas soi-même |

**Ce que la carte gagne** : plus rien n'est *à côté* d'elle, donc plus rien ne
la décale — elle est centrée et occupe tout l'écran. C'est la leçon des deux
essais précédents : **tant qu'une commande est à côté du contenu, elle le
déplace ; dedans, elle ne coûte rien.**

Mesures partagées : `core/widgets/action_button.dart` (`ActionMetrics`,
`ActionIconButton`) — une seule définition des deux tailles, pour que quatre
boutons sur une même ligne ne se règlent pas chacun de leur côté.

Tests : `test/vibe_card_chrome_test.dart` (4) — le calque ne prend aucune
place (la carte reste centrée, au pixel près), tout est dans le cadre, la
bande de la barre de lecture vidéo reste libre, et **les boutons bougent avec
la carte quand le doigt l'incline**. Contre-test fait : posés au-dessus de la
carte, ils restent immobiles et le test passe au rouge. `reel_layout_test.dart`
supprimé (il mesurait la mise en page que Jay a écartée).

