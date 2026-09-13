import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Ce que rend un enregistrement terminé : le fichier **en clair** et sa durée.
///
/// ⚠️ Le fichier est en clair sur le disque, dans le répertoire temporaire, et
/// c'est **l'appelant** qui le supprime une fois scellé et déposé — voir
/// `ConversationsRepository.sendVoice`. Il ne vit que le temps de l'envoi,
/// comme la capture vidéo avant scellement.
class VoiceRecording {
  const VoiceRecording({required this.file, required this.duration});
  final File file;
  final Duration duration;
}

/// Le micro des messages vocaux — **la cuisine**, rien d'autre.
///
/// Parle au natif (`NativeVoiceRecorder.kt`, canal `neovibe/voice`) et rend ce
/// qu'il constate : un fichier et une durée. Il ne scelle pas, n'envoie pas,
/// ne dessine pas. Un seul enregistrement à la fois (le natif refuse le
/// second avec `BUSY`).
///
/// ⚠️ **La permission micro se demande AVANT** `start`, par l'écran, avec
/// `permission_handler`. Ici on ne fait que transmettre l'échec s'il survient.
class VoiceRecorder {
  VoiceRecorder();

  static const _channel = MethodChannel('neovibe/voice');

  /// Durée maximale d'un vocal. Au-delà, l'écran arrête l'enregistrement de
  /// lui-même ; le serveur refuse de toute façon (`send_voice_message`).
  static const maxDuration = Duration(minutes: 2);

  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _channel.invokeMethod<void>('start', {'path': path});
  }

  /// Termine et rend le fichier. Lève `PlatformException(TOO_SHORT)` si rien
  /// n'a pu être écrit — l'appelant l'affiche, il n'y a rien à envoyer.
  Future<VoiceRecording> stop() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('stop');
    if (raw == null) {
      throw PlatformException(code: 'EMPTY', message: 'aucun son enregistré');
    }
    return VoiceRecording(
      file: File(raw['path'] as String),
      duration: Duration(milliseconds: (raw['durationMs'] as num).toInt()),
    );
  }

  /// Abandonne : le natif supprime le fichier.
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  /// Amplitude de l'instant, 0..32767. Lue à la cadence de l'écran.
  Future<int> amplitude() async =>
      await _channel.invokeMethod<int>('amplitude') ?? 0;
}

final voiceRecorderProvider = Provider<VoiceRecorder>((ref) => VoiceRecorder());
