import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/message.dart';
import '../../../core/video/sealed_video_controller.dart';
import 'voice_playback.dart';

/// Quel vocal joue en ce moment — **un seul à la fois** dans toute l'app.
///
/// Deux vocaux qui parlent en même temps, c'est une cacophonie ; c'est ce que
/// tout le monde attend d'une messagerie. Chaque bulle s'y compare : si un
/// autre message y entre, elle se met en pause.
final playingVoiceProvider = NotifierProvider<PlayingVoice, String?>(
  PlayingVoice.new,
);

class PlayingVoice extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? messageId) => state = messageId;
}

/// **Le client** : la bulle d'un message vocal. Elle affiche, elle demande.
///
/// Rien ici ne parle au réseau ni au disque : la source vient de
/// [voiceSourceProvider], le son du lecteur natif (le même que les vidéos
/// scellées, en mode « sans image »). Le fichier reçu reste **scellé** sur
/// l'appareil ; la clé vit en mémoire, le temps de l'écran.
///
/// Avant la première écoute, la bulle montre la durée portée par le message :
/// pas un octet n'a été téléchargé. La première pression sur ▶ demande la clé,
/// ouvre le lecteur et joue.
class VoiceBubble extends ConsumerStatefulWidget {
  const VoiceBubble({super.key, required this.message, required this.isMine});

  final Message message;
  final bool isMine;

  @override
  ConsumerState<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends ConsumerState<VoiceBubble> {
  SealedVideoController? _controller;
  bool _opening = false;
  String? _error;

  Message get message => widget.message;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final c = _controller;
    if (c != null) {
      if (c.value.isPlaying) {
        await c.pause();
      } else {
        if (c.value.isCompleted ||
            (c.value.duration > Duration.zero &&
                c.value.position >= c.value.duration)) {
          await c.seekTo(Duration.zero);
        }
        ref.read(playingVoiceProvider.notifier).set(message.id);
        await c.play();
      }
      return;
    }
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final source = await ref.read(
        voiceSourceProvider((
          messageId: message.id,
          mediaPath: message.mediaPath ?? '',
        )).future,
      );
      final controller = SealedVideoController.audioStreaming(
        url: source.url,
        key: source.key,
        cachePath: source.cachePath,
      );
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      controller.addListener(_onValue);
      setState(() => _controller = controller);
      ref.read(playingVoiceProvider.notifier).set(message.id);
      await controller.play();
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _onValue() {
    if (!mounted) return;
    setState(() {});
  }

  static String _friendly(Object e) {
    final text = e.toString();
    if (text.contains('introuvable')) return 'Vocal expiré';
    return 'Vocal indisponible';
  }

  static String _mmss(Duration d) {
    final s = d.inSeconds;
    return '${(s ~/ 60).toString().padLeft(1, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = widget.isMine ? Colors.white : theme.colorScheme.onSurface;
    final track = fg.withValues(alpha: 0.28);

    // Un autre vocal a pris la parole : celui-ci se tait.
    ref.listen<String?>(playingVoiceProvider, (_, playing) {
      final c = _controller;
      if (c != null && playing != message.id && c.value.isPlaying) c.pause();
    });

    final c = _controller;
    final total = (c != null && c.value.duration > Duration.zero)
        ? c.value.duration
        : (message.duration ?? Duration.zero);
    final position = c?.value.position ?? Duration.zero;
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final playing = c?.value.isPlaying ?? false;

    final label =
        _error ??
        (playing || (c != null && position > Duration.zero)
            ? _mmss(total - position)
            : _mmss(total));

    return SizedBox(
      width: 210,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: _opening
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  )
                : IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 30,
                    color: fg,
                    tooltip: playing ? 'Pause' : 'Écouter',
                    icon: Icon(
                      playing
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                    ),
                    onPressed: _error == null ? _toggle : null,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // La barre se laisse saisir : glisser = se déplacer dans le
                // vocal. Inerte tant que le lecteur n'est pas ouvert.
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                    activeTrackColor: fg,
                    inactiveTrackColor: track,
                    thumbColor: fg,
                    disabledActiveTrackColor: fg,
                    disabledInactiveTrackColor: track,
                    disabledThumbColor: fg,
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: c == null
                        ? null
                        : (v) => c.seekTo(
                            Duration(
                              milliseconds: (total.inMilliseconds * v).round(),
                            ),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: fg.withValues(alpha: _error == null ? 0.85 : 1),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
