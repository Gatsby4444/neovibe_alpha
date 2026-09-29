import 'dart:async';
import 'dart:io';

/// Les deux faces d'une vidéo Oneshot, une fois ADOPTÉES par le brouillon.
typedef FacesOneshot = ({File recto, File verso});

/// **La fin d'une vidéo Oneshot** : arrêter la double vidéo, adopter les deux
/// faces, puis journaliser leur taille — sortie de l'écran de capture pour
/// être éprouvée sans caméra (test/oneshot_video_test.dart).
///
/// Les règles qu'elle tient :
/// - l'arrière est le recto, l'avant le verso (consigne de Jay) ;
/// - **les deux faces ou aucune** : si la seconde adoption échoue, rien n'est
///   rendu (l'écran ne se retrouve pas avec un recto sans verso) ;
/// - le journal lit les faces ADOPTÉES — l'adoption DÉPLACE les fichiers
///   (`VibeDraftKeeper.adopt`), l'ancien chemin n'existe plus ;
/// - **un journal ne fait jamais échouer une prise**. Le 2026-09-30, la ligne
///   de journal relisait les chemins d'avant l'adoption, levait, et toute
///   vidéo Oneshot avortait alors que les deux faces étaient là (depuis
///   v0.9.227, l'arrivée des brouillons).
Future<FacesOneshot> terminerVideoOneshot({
  required Future<({File back, File front})> Function() arreter,
  required Future<File> Function(File) adopter,
  required Future<void> Function(String) journal,
}) async {
  final shots = await arreter();
  final recto = await adopter(shots.back);
  final verso = await adopter(shots.front);
  unawaited(
    Future(() async {
      await journal(
        'Oneshot : double vidéo GPU écrite — '
        'recto ${await recto.length() ~/ 1024} Ko, '
        'verso ${await verso.length() ~/ 1024} Ko',
      );
    }).catchError((Object _) {}),
  );
  return (recto: recto, verso: verso);
}
