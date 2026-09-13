import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/motion.dart';
import '../../../core/theme.dart';
import 'voice_recorder.dart';

/// La barre d'enregistrement d'un vocal : elle **remplace** le champ de saisie
/// le temps de parler, puis rend la main.
///
/// Un point rouge, le chronomètre, une onde qui bouge avec la voix, et deux
/// gestes seulement : ✕ abandonner, ➤ envoyer. Tap-pour-commencer,
/// tap-pour-envoyer — pas de « maintenir appuyé » : un geste continu qui
/// lâche au mauvais moment envoie un vocal qu'on ne voulait pas.
///
/// À [VoiceRecorder.maxDuration], la barre arrête d'elle-même et envoie : la
/// limite est la même que celle du serveur, et l'utilisateur voit le
/// chronomètre y arriver.
///
/// Elle possède l'enregistrement : c'est elle qui appelle `stop` ou `cancel`.
/// L'écran ne reçoit que le résultat — un fichier et une durée — ou rien.
class VoiceRecordBar extends StatefulWidget {
  const VoiceRecordBar({
    super.key,
    required this.recorder,
    required this.onCancel,
    required this.onSend,
  });

  final VoiceRecorder recorder;
  final VoidCallback onCancel;
  final ValueChanged<VoiceRecording> onSend;

  @override
  State<VoiceRecordBar> createState() => _VoiceRecordBarState();
}

class _VoiceRecordBarState extends State<VoiceRecordBar> {
  static const _tick = Duration(milliseconds: 100);
  static const _bars = 24;

  Timer? _timer;
  final _startedAt = DateTime.now();
  Duration _elapsed = Duration.zero;
  final List<double> _levels = List.filled(_bars, 0.05);
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_tick, (_) => _onTick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _onTick() async {
    if (_done) return;
    final elapsed = DateTime.now().difference(_startedAt);
    // L'amplitude est lue ici, à la cadence de l'écran : le natif ne pousse
    // rien (dissociation acquisition / usage).
    final amp = await widget.recorder.amplitude();
    if (!mounted || _done) return;
    setState(() {
      _elapsed = elapsed;
      _levels.removeAt(0);
      // Échelle logarithmique : la voix parlée vit entre 1 000 et 15 000 sur
      // 32 767, une échelle linéaire ferait une onde presque plate.
      final level = amp <= 0
          ? 0.05
          : (math.log(amp) / math.log(32767)).clamp(0.05, 1.0);
      _levels.add(level);
    });
    if (elapsed >= VoiceRecorder.maxDuration) await _send();
  }

  Future<void> _send() async {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    try {
      final recording = await widget.recorder.stop();
      widget.onSend(recording);
    } on PlatformException catch (e) {
      // Trop court, ou rien d'écrit : il n'y a rien à envoyer, on rend la
      // main comme sur un abandon — en le disant.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.code == 'TOO_SHORT'
                  ? 'Trop court — parle un peu plus longtemps.'
                  : 'Enregistrement impossible : ${e.message ?? e.code}',
            ),
          ),
        );
      }
      widget.onCancel();
    }
  }

  Future<void> _cancel() async {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    try {
      await widget.recorder.cancel();
    } catch (_) {}
    widget.onCancel();
  }

  static String _mmss(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fieldColor = theme.colorScheme.surfaceContainerHighest;
    final borderColor = theme.colorScheme.outline;
    final fg = theme.colorScheme.onSurface;
    final remaining = VoiceRecorder.maxDuration - _elapsed;
    final nearEnd = remaining <= const Duration(seconds: 10);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 10, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.close_rounded),
              color: theme.colorScheme.onSurfaceVariant,
              tooltip: 'Abandonner',
              onPressed: _cancel,
            ),
            Expanded(
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: fieldColor,
                  border: Border.all(color: borderColor),
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    // Le point rouge qui bat : « ça enregistre ».
                    AnimatedOpacity(
                      opacity: _elapsed.inMilliseconds ~/ 500 % 2 == 0
                          ? 1
                          : 0.3,
                      duration: NeoMotion.fast,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE53935),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      nearEnd ? '-${_mmss(remaining)}' : _mmss(_elapsed),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: nearEnd ? const Color(0xFFE53935) : fg,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: CustomPaint(
                        painter: _WavePainter(
                          // Une copie : la liste est modifiée sur place, et un
                          // peintre qui reçoit la même instance ne repeint pas.
                          levels: List.of(_levels),
                          color: fg.withValues(alpha: 0.7),
                        ),
                        size: const Size(double.infinity, 22),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 34,
              height: 34,
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: Ink(
                  decoration: BoxDecoration(
                    gradient: context.palette.signatureCourte,
                    shape: BoxShape.circle,
                  ),
                  child: InkWell(
                    onTap: _send,
                    child: const Icon(
                      Icons.arrow_upward_rounded,
                      size: 21,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// L'onde : une barre par relevé, les plus récents à droite.
class _WavePainter extends CustomPainter {
  const _WavePainter({required this.levels, required this.color});
  final List<double> levels;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final step = size.width / levels.length;
    final mid = size.height / 2;
    for (var i = 0; i < levels.length; i++) {
      final x = step * i + step / 2;
      final h = math.max(2.0, levels[i] * size.height);
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.levels != levels || old.color != color;
}
