import 'dart:io';

import '../../../core/utils/ids.dart';
import 'media_edit.dart';
import 'color_grade.dart';
import '../native_media.dart';

/// **Ce que l'éditeur d'une Vibe manipule** — pur : pas de widget, pas de
/// réseau. Le recto, le verso s'il existe, chacun avec ses réglages
/// ([MediaEdit] : cadrage, filtre, corrections, calques, découpe).
/// L'éditeur l'affiche, l'export le lit.
///
/// Jay, 2026-09-18 : *« refais-moi l'éditeur des Vibes, l'actuel est vraiment
/// trop basique, inspire-toi de celui qu'on a créé pour les Flows »*. Le
/// moteur (panneaux, aperçu, export, [MediaEdit]) vient de là ; les Flows
/// et les albums sont sortis du MVP le 2026-09-21, le moteur est resté.
class VibeEditDraft {
  const VibeEditDraft({required this.front, this.back});

  final MediaEdit front;

  /// Nul = Vibe à face unique (verso passé à la prise).
  final MediaEdit? back;

  /// Une Vibe est un 9:16, point — pas d'outil Format.
  static const aspect = MediaAspect.reel;

  /// Une face vidéo dure au plus une minute (la règle de la capture).
  static const maxVideoMs = kMaxFaceVideoMs;

  bool get hasBack => back != null;

  MediaEdit face({required bool front}) => front ? this.front : back!;

  VibeEditDraft update(bool isFront, MediaEdit Function(MediaEdit) f) => isFront
      ? VibeEditDraft(front: f(front), back: back)
      : VibeEditDraft(front: front, back: f(back!));

  /// Une face **telle que capturée** : aucun réglage. C'est ce que « Original »
  /// rend, et ce qui permet à l'export de **ne pas retranscoder** une vidéo
  /// qu'on n'a pas touchée — une génération de compression et vingt secondes
  /// de moins.
  static bool isPristine(MediaEdit m) =>
      m.crop == CropSpec.none &&
      m.filter == MediaFilter.normal &&
      m.filterStrength == 1 &&
      m.adjust == ColorGrade.none &&
      m.overlays.isEmpty &&
      m.trim == null;

  bool get frontEdited => !isPristine(front);
  bool get backEdited => back != null && !isPristine(back!);

  /// La même face, sans aucun réglage.
  static MediaEdit pristine(MediaEdit m) => MediaEdit(
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
    Future<MediaEdit> face(File f, bool isVideo) async {
      final probe = await NativeMedia.probe(f.path);
      return MediaEdit(
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
