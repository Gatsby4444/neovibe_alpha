# Les formats mis de côté — albums et Flows (retirés le 2026-09-21)

> Ce document dit **ce qui a été construit, où le retrouver, et ce qu'il
> faudrait pour le réintroduire**. Il ne décrit pas l'app d'aujourd'hui :
> depuis le 2026-09-21, la bibliothèque, le feed et l'éditeur n'ont **qu'un
> format, la Vibe**.

## La décision

Le 2026-09-21, après un pré-mortem (dix causes d'échec probables, les
premières produit : pas de besoin réel, cold start, trop construit avant
d'avoir validé une boucle d'usage, copie de Snapchat/Instagram), Jay a
tranché :

> *« NeoVibe doit être cool et doit être l'app qu'on sort en soirée ou à
> chaque activité entre amis, pas l'app qui nous permet de faire différentes
> publications avec des formats différents et mélangés, cela complexifie
> l'app au regard de l'utilisateur. »*
>
> 1. Les contenus « publication » et « Flow » : **un éditeur pour un format,
>    les Vibes**.
> 2. Le feed multiple : **le feed n'affiche que des Vibes**.
>
> *« Il ne faut pas perdre les compétences et les modèles que l'on a
> construits […] on garde ce que l'on a acquis, juste ce n'est pas dans le
> MVP. »*

Le retrait est **propre** (choisi par Jay parmi deux options) : le code est
retiré, pas laissé en place derrière un interrupteur — un reste mort
d'aujourd'hui est la panne de demain (`CLAUDE.md`, règle 8). L'acquis vit
dans l'historique git.

## Où retrouver l'acquis

**Le tag `v0.9.236`** (2026-09-20 soir) est la dernière version qui contient
tout : les albums, les Flows, le fil des publications, les trois fils de
Pulse. `git show v0.9.236:<chemin>` rend n'importe quel fichier ; `git
checkout v0.9.236 -- <chemin>` le ramène.

| Ce qui a existé | Où c'était (chemins de `v0.9.236`) | Documents |
|---|---|---|
| **L'éditeur d'album** : 1 à 20 médias feuilletés, un ratio (3:4 imposé après le test de Jay ; 1:1, 4:5, 1,91:1 lisibles), l'outil Format, la bande des médias, l'ordre, la légende avec sa police | `lib/features/library/album_editor/album_editor_screen.dart`, `album_flow.dart`, `album_caption_screen.dart`, `album_draft.dart` (`AlbumDraft`, `splitPlan`), `album_draft_keeper.dart` | `docs/plan-publications.md`, `docs/plan-refonte-partage.md` §6–§7 |
| **Le Flow** : une vidéo publiée seule, 9:16, jusqu'à 3 minutes, plein écran façon Reels, l'habillage DANS la vidéo (`FlowFrame`, mesures pures testées) | `lib/features/library/feed/flows_reel_screen.dart`, `flow_frame.dart`, `test/flow_frame_test.dart`, `test/flow_test.dart` | rapports des 2026-09-17, 18, 20 |
| **Le fil des publications** : cellules à l'Instagram (en-tête, carrousel, barre d'actions, légende dépliable, « Modifier la description »), le suiveur de l'élément actif (un seul décodeur vidéo à la fois) | `publications_feed_screen.dart`, `publication_cell.dart`, `publication_caption.dart`, `album_carousel.dart`, `caption_editor.dart`, `edit_caption_sheet.dart`, `active_item_tracker.dart` | `docs/plan-publications.md` §9 |
| **La grille à trois onglets** du profil (Tout 4:5 / Vibes 9:16 / Flows) et le choix du « + » (Vibe / photos-vidéos / Flow) | `publications_tabs.dart`, `publish_choice_sheet.dart` | — |
| **Le feed à trois natures** : liserés de couleur par nature (`KindColors`), légende, un fil par nature | `lib/core/widgets/kind_colors.dart`, `lib/features/pulse/pulse_feed_screen.dart` (v0.9.236) | `docs/feed-pulse.md` (v0.9.236) |
| **La galerie du téléphone en multi-sélection** avec appareil photo du système, découpe des vidéos longues en plusieurs médias (`splitPlan`), filtre « vidéos seulement » | `album_editor/gallery/gallery_import.dart` (`toDraftMedia`, `fromFiles`, `capture`) | — |
| **Le dépôt d'un album à la file native** : rendu des photos par le shader, calque PNG des vidéos, paramètres du transcodage (`videoSpec`) passés au service qui transcode | `album_editor/publish_preparer.dart` (`PublishPreparer`) | `docs/file-de-publication.md` (v0.9.236) |
| **Les brouillons d'album** (écrits seuls, repris à l'étape près) | `album_draft_keeper.dart`, `DraftKind.publication` / `.flow`, `drafts_screen.dart` | rapport du 2026-09-20 |
| **Le seed** d'albums et de Flows par les bots | `tool/seed_feed.dart` (`_album`, `_flow`) | — |

## Ce qui est resté, et sous quel nom

Le **moteur d'édition** écrit pour l'album est le socle de l'éditeur de
Vibes (Jay, 2026-09-18 : *« inspire-toi de celui qu'on a créé pour les
Flows »*). Il est resté, déplacé sous `lib/features/cards/editor/` et
renommé — un dossier `album_editor` sans album aurait menti :

| Avant | Après |
|---|---|
| `AlbumDraftMedia` | `MediaEdit` (`media_edit.dart`) — une face et tout ce qu'on lui a fait |
| `AlbumAspect` (4 ratios + `reel`) | `MediaAspect { reel }` — le seul cadre : 9:16 |
| `AlbumDraftCodec` | `MediaEditCodec` — une face seule |
| `AlbumExport` | `MediaExport` |
| `AlbumFilter` | `MediaFilter` |
| `kAlbumMaxVideoMs` | `kMaxFaceVideoMs` |
| `gallery/` | `cards/editor/gallery/` — réduite au choix d'un média (l'autocollant image) |

Et **la file native de publication** (`android/…/publish/`), écrite pour les
albums, sert désormais aux Vibes (`docs/file-de-publication.md`). Le
pipeline garde sa capacité de transcodage (`source` + `transcode`), testée,
pour les vidéos importées dans une Vibe à venir.

En base, **rien n'a bougé** : `library_items.kind` garde ses trois valeurs,
`library_media` ses colonnes (`poster_path`, `duration_ms`, `width`,
`height`), `publish_to_library` et `feed_items` leurs paramètres. L'app ne
lit et n'écrit que `kind = 'card'`, positivement (`kLibraryKindVibe`). Les
albums et Flows des bots (et de Charles) ont été **purgés** le 2026-09-21
(25 contenus, 145 fichiers) ; les octets des bots effacés sous leur identité,
ceux de Charles inscrits en `storage_tombstones`, balayés par son app après
le délai de grâce.

## Pour réintroduire un jour

Dans l'ordre où les choses se sont construites, ce qu'il faudrait :

1. **Un modèle de brouillon à plusieurs médias** (`AlbumDraft` : liste,
   ratio commun, `add` / `remove` / `reorder`, `splitPlan`) — `git show
   v0.9.236:lib/features/library/album_editor/album_draft.dart`.
2. **Le ratio** : rendre à `MediaAspect` ses valeurs, et à l'export
   (`MediaExport.outputSize`) et à la géométrie du cadrage leur paramètre —
   ils le prennent déjà en argument.
3. **L'écran** : `album_editor_screen.dart` (bande des médias, Format), la
   galerie en multi-sélection (`GalleryImport.toDraftMedia`, `fromFiles`),
   l'écran de légende.
4. **Le dépôt** : `PublishPreparer` — rendre les photos, calculer
   `videoSpec`, passer `source` + `transcode` au service ; `PublishJob`
   reprend `kind` et `aspectW`/`aspectH`.
5. **L'affichage** : `LibraryKind` dans le modèle, le carrousel, le fil des
   publications ou une autre présentation ; `feed_items(p_kind)` prend déjà
   la nature.

Mais la question à se poser d'abord est celle de Jay : *« ce contenu a-t-il
obligé quelqu'un à sortir de chez lui ? »* Un album de photos importées de
la galerie n'y répond pas mieux qu'une Vibe prise sur place.
