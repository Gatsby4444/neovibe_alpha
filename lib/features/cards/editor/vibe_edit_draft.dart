import 'dart:io';

import '../../../core/models/library_item.dart';
import '../../../core/utils/ids.dart';
import '../../library/album_editor/album_draft.dart';
import '../../library/album_editor/color_grade.dart';
import '../native_media.dart';

/// **Ce que l'éditeur d'une Vibe manipule** — pur, comme [AlbumDraft] : pas
/// de widget, pas de réseau. Le recto, le verso s'il existe, chacun avec ses
/// réglages ([AlbumDraftMedia] : cadrage, filtre, corrections, calques,
/// découpe). L'éditeur l'affiche, l'export le lit.
///
/// Jay, 2026-09-18 : *« refais-moi l'éditeur des Vibes, l'actuel est vraiment
/// trop basique, inspire-toi de celui qu'on a créé pour les Flows »*. Le
/// modèle d'un média retouché est donc **le même** que celui des Flows —
/// c'est ce qui permet aux deux éditeurs de partager panneaux, aperçu et
/// export. Ce qui change, c'est le contenant : deux faces au lieu d'une
/// bande, et un format qui ne se choisit pas.
class VibeEditDraft {
  const VibeEditDraft({required this.front, this.back});

  final AlbumDraftMedia front;

  /// Nul = Vibe à face unique (verso passé à la prise).
  final AlbumDraftMedia? back;

  /// Une Vibe est un 9:16, point — pas d'outil Format.
  static const aspect = AlbumAspect.reel;

  /// Une face vidéo dure au plus une minute (la règle de la capture).
  static const maxVideoMs = kAlbumMaxVideoMs;

  bool get hasBack => back != null;

  AlbumDraftMedia face({required bool front}) => front ? this.front : back!;

  VibeEditDraft update(
    bool isFront,
    AlbumDraftMedia Function(AlbumDraftMedia) f,
  ) => isFront
      ? VibeEditDraft(front: f(front), back: back)
      : VibeEditDraft(front: front, back: f(back!));

  /// Une face **telle que capturée** : aucun réglage. C'est ce que « Original »
  /// rend, et ce qui permet à l'export de **ne pas retranscoder** une vidéo
  /// qu'on n'a pas touchée — une génération de compression et vingt secondes
  /// de moins.
  static bool isPristine(AlbumDraftMedia m) =>
      m.crop == CropSpec.none &&
      m.filter == AlbumFilter.normal &&
      m.filterStrength == 1 &&
      m.adjust == ColorGrade.none &&
      m.overlays.isEmpty &&
      m.trim == null;

  bool get frontEdited => !isPristine(front);
  bool get backEdited => back != null && !isPristine(back!);

  /// La même face, sans aucun réglage.
  static AlbumDraftMedia pristine(AlbumDraftMedia m) => AlbumDraftMedia(
    id: m.id,
    source: m.source,
    isVideo: m.isVideo,
    srcWidth: m.srcWidth,
    srcHeight: m.srcHeight,
    rotation: m.rotation,
    durationMs: m.durationMs,
  );

  VibeEditDraft restore({required bool isFront}) => update(isFront, pristine);

  /// Depuis ce que la capture a produit : le natif sonde chaque face
  /// (dimensions après rotation, durée). Lève si un fichier est illisible —
  /// l'appelant retombe alors sur le chemin sans éditeur.
  static Future<VibeEditDraft> fromFiles({
    required File front,
    File? back,
    required bool frontIsVideo,
    required bool backIsVideo,
  }) async {
    Future<AlbumDraftMedia> face(File f, bool isVideo) async {
      final probe = await NativeMedia.probe(f.path);
      return AlbumDraftMedia(
        id: newUuid(),
        source: f,
        isVideo: probe.isVideo,
        srcWidth: probe.width,
        srcHeight: probe.height,
        rotation: probe.rotation,
        durationMs: probe.isVideo ? (probe.durationMs ?? 0) : null,
      );
    }

    return VibeEditDraft(
      front: await face(front, frontIsVideo),
      back: back == null ? null : await face(back, backIsVideo),
    );
  }
}
