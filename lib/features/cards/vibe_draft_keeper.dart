import 'dart:io';

import '../../core/drafts/draft_store.dart';
import '../../core/models/card.dart';
import '../../core/utils/ids.dart';
import '../library/album_editor/album_draft_codec.dart';
import '../library/album_editor/overlay_model.dart';
import 'editor/vibe_edit_draft.dart';
import 'native_media.dart';
import 'send/share_plan.dart';
import 'send/share_plan_codec.dart';

/// **Ce qu'un brouillon de Vibe contient** : les faces telles que
/// capturées, le type, où on en était, les retouches et le plan de partage.
/// Trois écrans le remplissent, chacun sa part : la capture (faces, étape),
/// l'éditeur (retouches), « À qui ? » (plan).
class VibeDraftState {
  VibeDraftState({
    required this.type,
    this.front,
    this.back,
    this.frontIsVideo = false,
    this.backIsVideo = false,
    this.frontImported = false,
    this.backImported = false,
    this.step = 'capture',
    this.edit,
    this.plan,
  });

  factory VibeDraftState.fromJson(Map<String, dynamic> j) {
    final edit = (j['edit'] as Map?)?.cast<String, dynamic>();
    final plan = (j['plan'] as Map?)?.cast<String, dynamic>();
    return VibeDraftState(
      type: CardType.values.byName(j['type'] as String),
      front: j['front'] == null ? null : File(j['front'] as String),
      back: j['back'] == null ? null : File(j['back'] as String),
      frontIsVideo: j['frontIsVideo'] as bool? ?? false,
      backIsVideo: j['backIsVideo'] as bool? ?? false,
      frontImported: j['frontImported'] as bool? ?? false,
      backImported: j['backImported'] as bool? ?? false,
      step: j['step'] as String? ?? 'capture',
      edit: edit == null
          ? null
          : VibeEditDraft(
              front: AlbumDraftCodec.mediaFromJson(
                (edit['front'] as Map).cast<String, dynamic>(),
              ),
              back: (edit['back'] as Map?) == null
                  ? null
                  : AlbumDraftCodec.mediaFromJson(
                      (edit['back'] as Map).cast<String, dynamic>(),
                    ),
            ),
      plan: plan == null ? null : SharePlanCodec.fromJson(plan),
    );
  }

  CardType type;
  File? front;
  File? back;
  bool frontIsVideo;
  bool backIsVideo;
  bool frontImported;
  bool backImported;

  /// `capture` (il manque une face), `edit` (dans l'éditeur), `share`
  /// (sur « À qui ? »).
  String step;
  VibeEditDraft? edit;
  SharePlan? plan;

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'front': front?.path,
    'back': back?.path,
    'frontIsVideo': frontIsVideo,
    'backIsVideo': backIsVideo,
    'frontImported': frontImported,
    'backImported': backImported,
    'step': step,
    'edit': edit == null
        ? null
        : {
            'front': AlbumDraftCodec.mediaToJson(edit!.front),
            'back': edit!.back == null
                ? null
                : AlbumDraftCodec.mediaToJson(edit!.back!),
          },
    'plan': plan == null ? null : SharePlanCodec.toJson(plan!),
  };

  /// Ce que la liste dit : « recto vidéo, verso photo ».
  String get summary {
    String face(bool isVideo) => isVideo ? 'vidéo' : 'photo';
    return [
      if (front != null) 'recto ${face(frontIsVideo)}',
      if (back != null) 'verso ${face(backIsVideo)}',
    ].join(', ');
  }
}

/// Un brouillon de Vibe à reprendre : son identifiant et son état.
class VibeResume {
  const VibeResume({required this.id, required this.state});

  factory VibeResume.fromDraft(Draft d) =>
      VibeResume(id: d.id, state: VibeDraftState.fromJson(d.payload));

  final String id;
  final VibeDraftState state;
}

/// **Le gardien d'un brouillon de Vibe** — l'équivalent de
/// `AlbumDraftKeeper` pour la prise, l'édition et le partage.
///
/// Les faces capturées naissent dans un dossier temporaire du système : à
/// peine posées, elles sont **déplacées** dans le dossier du brouillon
/// ([adopt]) — avant que le récap ne les affiche.
///
/// ⚠️ **Rien ne s'écrit sans le consentement de l'utilisateur** (Jay,
/// 2026-09-20) : une Vibe est un format façon Snap, souvent une prise
/// privée ; garder à son insu ce qu'il ne veut finalement plus envoyer
/// serait une trahison de « ce qui se passe sur NeoVibe reste sur
/// NeoVibe ». L'état vit en mémoire ([update]) et n'est écrit que par
/// [flush], à « Garder en brouillon ». Si l'app meurt avant, le dossier —
/// sans `draft.json` — est balayé au prochain démarrage : pas de
/// consentement, pas de brouillon. Les publications, elles, s'écrivent
/// seules (`AlbumDraftKeeper`) : ce sont des imports, pas des prises.
class VibeDraftKeeper {
  VibeDraftKeeper(this._store, {String? id, VibeDraftState? state})
    : id = id ?? newUuid(),
      // Un nom de paramètre ne peut pas être privé : l'affectation explicite
      // est la seule forme possible, et l'analyse ne le sait pas.
      // ignore: prefer_initializing_formals
      _state = state;

  final DraftStore _store;
  final String id;
  VibeDraftState? _state;
  Future<void>? _writing;
  var _dirty = false;
  var _deleted = false;

  Future<Directory> get dir => _store.dir(id);

  /// L'état, tel que le dernier écran l'a laissé.
  VibeDraftState? get state => _state;

  /// Un fichier (face capturée, image d'autocollant) rejoint le dossier du
  /// brouillon. Idempotent.
  Future<File> adopt(File source) async {
    final d = await dir;
    if (source.path.startsWith(d.path)) return source;
    // Un préfixe unique : deux prises de suite peuvent porter le même nom
    // de fichier natif, et un renommage écraserait la précédente.
    final name = '${newUuid().substring(0, 8)}_${source.uri.pathSegments.last}';
    final target = '${d.path}${Platform.pathSeparator}$name';
    try {
      return await source.rename(target);
    } on FileSystemException {
      final copied = await source.copy(target);
      try {
        await source.delete();
      } catch (_) {}
      return copied;
    }
  }

  Future<StickerOverlay> adoptSticker(StickerOverlay s) async {
    final path = s.imagePath;
    if (path == null) return s;
    final moved = await adopt(File(path));
    if (moved.path == path) return s;
    return StickerOverlay(
      id: s.id,
      imagePath: moved.path,
      cx: s.cx,
      cy: s.cy,
      scale: s.scale,
      rotation: s.rotation,
    );
  }

  /// Un écran a changé quelque chose : l'état est mis à jour — en mémoire
  /// seulement, jusqu'à [flush].
  void update(void Function(VibeDraftState s) change, {CardType? type}) {
    if (_deleted) return;
    final s = _state ??= VibeDraftState(type: type ?? CardType.standard);
    change(s);
    _dirty = true;
  }

  /// « Garder en brouillon » : l'état est écrit, maintenant.
  Future<void> flush() async {
    final s = _state;
    if (s == null || !_dirty || _deleted || s.front == null) return;
    _dirty = false;
    await _writing;
    _writing = _write(s);
    await _writing;
  }

  Future<void> _write(VibeDraftState s) async {
    try {
      await _store.save(
        Draft(
          id: id,
          kind: DraftKind.vibe,
          step: s.step,
          updatedAt: DateTime.now(),
          payload: s.toJson(),
          cover: await _cover(s),
          summary: s.summary,
        ),
      );
    } catch (_) {
      // Un brouillon qui ne s'écrit pas n'arrête pas la prise.
    }
  }

  Future<String?> _cover(VibeDraftState s) async {
    final front = s.front;
    if (front == null) return null;
    if (!s.frontIsVideo) return front.path;
    final file = File(
      '${(await dir).path}${Platform.pathSeparator}cover_${front.uri.pathSegments.last}.jpg',
    );
    if (await file.exists()) return file.path;
    final ok = await NativeMedia.videoThumbnail(
      source: front.path,
      dest: file.path,
      width: 320,
    );
    return ok ? file.path : null;
  }

  /// « Supprimer » : le brouillon et ses fichiers s'effacent.
  Future<void> delete() async {
    _deleted = true;
    await _writing;
    await _store.delete(id);
  }

  /// **La Vibe est partie** : le brouillon n'a plus lieu d'être — mais ses
  /// fichiers, si. L'envoi tourne en arrière-plan, et il lit les faces DANS
  /// ce dossier : les effacer ici, c'était les effacer sous lui
  /// (2026-09-20, chez Jay : « SEAL_FAILED », « Cannot open file » sur les
  /// douze destinations d'une Vibe). On retire seulement `draft.json` ; le
  /// dossier, sans lui, est balayé au prochain démarrage de l'app — quand
  /// plus aucun envoi de cette session ne peut le lire.
  Future<void> release() async {
    _deleted = true;
    await _writing;
    await _store.forget(id);
  }
}
