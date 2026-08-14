import 'package:flutter/material.dart';

import '../../../core/day_cycle.dart';
import '../../../core/motion.dart';
import '../../../core/theme.dart';

/// Aperçu du **cycle de 24 h** : le curseur parcourt la journée, le fond suit.
///
/// ### Pourquoi cet écran existe
///
/// On ne peut pas juger un cycle de 24 h en attendant 24 h. Ici Jay balaie la
/// journée au pouce et voit l'arc entier en dix secondes — c'est ce qui rend
/// une retouche de palette discutable en une phrase (« 21 h est sale ») plutôt
/// qu'en une session de test.
///
/// Le **défilement accéléré** répond à l'autre moitié de la question : le
/// curseur montre les *couleurs*, pas la *vitesse*. Seule une lecture continue
/// dit si le mouvement est bien imperceptible.
///
/// ⚠️ **Outil de développement** — à retirer avec la section Développeur avant
/// la prod (voir `RAPPELS.md`).
class DayCyclePreviewScreen extends StatefulWidget {
  const DayCyclePreviewScreen({super.key});

  @override
  State<DayCyclePreviewScreen> createState() => _DayCyclePreviewScreenState();
}

class _DayCyclePreviewScreenState extends State<DayCyclePreviewScreen>
    with SingleTickerProviderStateMixin {
  /// Une journée en 24 s, comme la maquette Rive — un rapport rond qui rend
  /// les deux comparables (1 s = 1 h).
  static const _dayInSeconds = 24;

  late final _run = AnimationController(
    vsync: this,
    duration: const Duration(seconds: _dayInSeconds),
  )..addListener(() => setState(() {}));

  double _manualHour = 12;
  var _playing = false;

  double get _hour => _playing ? _run.value * 24 : _manualHour;

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  void _togglePlay() {
    setState(() {
      _playing = !_playing;
      if (_playing) {
        _run
          ..value = _manualHour / 24
          ..repeat();
      } else {
        _run.stop();
        _manualHour = _run.value * 24;
      }
    });
  }

  String _clock(double hour) {
    final h = hour.floor() % 24;
    final m = ((hour - hour.floor()) * 60).floor();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  String _hex(Color c) =>
      '#${((c.a * 255).round() << 24 | (c.r * 255).round() << 16 | (c.g * 255).round() << 8 | (c.b * 255).round()).toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    final p = DayCycle.at(_hour);
    final ratio = contrastRatio(p.accent, Colors.white);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Le fond : les trois arrêts du moment.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [p.top, p.middle, p.bottom],
                stops: const [0, DayCycle.middleStop, 1],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _header(p),
                const Spacer(),
                _samples(p, ratio),
                const Spacer(),
                _controls(p, ratio),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(DayPalette p) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
    child: Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        const Spacer(),
        Text(
          _clock(_hour),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w200,
            letterSpacing: 2,
            fontFeatures: [FontFeature.tabularFigures()],
            shadows: [Shadow(color: Color(0x8C000000), blurRadius: 8)],
          ),
        ),
      ],
    ),
  );

  /// Les mêmes témoins que la maquette Rive : une surface neutre qui porte du
  /// texte, deux sondes posées à nu sur le fond, et l'accent.
  Widget _samples(DayPalette p, double ratio) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // La stratégie du fond : ce qui porte du texte reste NEUTRE, posé en
        // voile par-dessus le dégradé. Le contraste est donc garanti par
        // construction, quelle que soit l'heure.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: NeoNeutrals.gray900.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Surface neutre',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Le dégradé est un fond d\'écran. Tout ce qui porte du texte '
                'reste neutre par-dessus : la lisibilité ne dépend donc pas '
                'de l\'heure.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        // Les sondes : le cas de nos boutons caméra, une icône seule sans fond.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _probe(Colors.white, 'blanc'),
            const SizedBox(width: 28),
            _probe(Colors.black, 'noir'),
          ],
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ).copyWith(backgroundBuilder: null),
            onPressed: () {},
            child: Text('Accent — ${ratio.toStringAsFixed(2)}:1'),
          ),
        ),
      ],
    ),
  );

  Widget _probe(Color color, String label) => Column(
    children: [
      Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(height: 6),
      Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          shadows: [Shadow(color: Color(0x8C000000), blurRadius: 6)],
        ),
      ),
    ],
  );

  Widget _controls(DayPalette p, double ratio) => Container(
    margin: const EdgeInsets.all(16),
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
    decoration: BoxDecoration(
      color: NeoNeutrals.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(22),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                p.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // Le curseur montre les COULEURS ; seul le défilement montre la
            // VITESSE. Les deux sont nécessaires pour juger.
            TextButton.icon(
              onPressed: _togglePlay,
              icon: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              label: Text(
                _playing ? 'Pause' : 'Jouer 24 h en $_dayInSeconds s',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
          ),
          child: Slider(
            value: _hour.clamp(0, 24),
            max: 24,
            divisions: 24 * 12, // pas de 5 minutes
            label: _clock(_hour),
            onChanged: (v) => setState(() {
              _playing = false;
              _run.stop();
              _manualHour = v;
            }),
          ),
        ),
        DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 11,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('haut ${_hex(p.top)}'),
              Text('milieu ${_hex(p.middle)}'),
              Text('bas ${_hex(p.bottom)}'),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'accent ${_hex(p.accent)} · ${ratio.toStringAsFixed(2)}:1 sur blanc',
          style: TextStyle(
            color: ratio >= DayCycle.accentMinContrast
                ? Colors.white70
                : NeoTheme.accentPink,
            fontSize: 11,
          ),
        ),
      ],
    ),
  );
}

/// Le fond du thème NeoVibe, à l'heure courante.
///
/// Isolé ici pour l'instant : il ne sera branché sur les vrais écrans qu'une
/// fois la palette validée par Jay. **Rien dans l'app ne l'utilise encore.**
class DayCycleBackground extends StatelessWidget {
  const DayCycleBackground({super.key, required this.hour, this.child});

  final double hour;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final p = DayCycle.at(hour);
    return AnimatedContainer(
      // Le fond ne s'anime pas « vers » une nouvelle couleur : il EST la
      // couleur de l'instant. Cette durée ne sert qu'aux rebuilds ponctuels
      // (retour d'arrière-plan), pour qu'ils ne sautent pas.
      duration: NeoMotion.ample,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [p.top, p.middle, p.bottom],
          stops: const [0, DayCycle.middleStop, 1],
        ),
      ),
      child: child,
    );
  }
}
