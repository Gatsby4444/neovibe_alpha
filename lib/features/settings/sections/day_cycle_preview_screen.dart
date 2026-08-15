import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/day_cycle.dart';
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

  /// L'ordre des palettes à l'essai. Les heures n'en font PAS partie : elles
  /// sont recalculées par [DayCycle.autoSchedule] à chaque changement.
  late List<DayAnchor> _order = List.of(DayCycle.palettes);

  /// Le calendrier qui en découle — c'est lui qu'on affiche.
  late List<DayAnchor> _schedule = DayCycle.anchors;

  /// Vrai tant qu'on est sur l'ordre livré dans l'app.
  var _pristine = true;

  /// L'ordre d'essai **survit à la fermeture de l'app** (demande de Jay,
  /// 2026-08-15) : seul « Réinitialiser » le rend à celui du code.
  ///
  /// Stocké par **noms de palettes**, jamais par indices : un ordre enregistré
  /// par position désignerait les mauvaises couleurs à la première retouche de
  /// `DayCycle.anchors`. C'est la même raison que `StartupTab`.
  static const _orderKey = 'day_cycle_preview_order';

  @override
  void initState() {
    super.initState();
    _loadOrder();
  }

  Future<void> _loadOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_orderKey);
    if (saved == null || !mounted) return;

    // ⚠️ Reconstruction TOLÉRANTE : on repart des palettes du code et on les
    // trie selon l'ordre enregistré. Une palette renommée ou ajoutée depuis
    // n'est donc pas perdue — elle retombe à la fin — et une palette
    // enregistrée qui n'existe plus est simplement ignorée.
    //
    // Sans ça, le premier changement de palette laisserait Jay sur un aperçu
    // vide ou incomplet, sans rien pour le lui dire.
    final byLabel = {for (final a in DayCycle.palettes) a.label: a};
    final rebuilt = <DayAnchor>[
      for (final label in saved) ?byLabel.remove(label),
      // Ce qui n'était pas dans l'ordre enregistré retombe à la fin.
      ...byLabel.values,
    ];

    if (rebuilt.length != DayCycle.palettes.length) return;
    setState(() {
      _order = rebuilt;
      _pristine = false;
      _schedule = DayCycle.autoSchedule(_order);
    });
  }

  Future<void> _saveOrder() async {
    final prefs = await SharedPreferences.getInstance();
    if (_pristine) {
      await prefs.remove(_orderKey);
    } else {
      await prefs.setStringList(_orderKey, [for (final a in _order) a.label]);
    }
  }

  /// L'ordre au presse-papier, prêt à être collé dans une conversation.
  ///
  /// Jay : *« ajoute un bouton pour copier l'ordre de sorte que je t'envoie
  /// l'ordre choisi à implémenter »*. On copie donc **les heures calculées et
  /// les hexadécimaux**, pas seulement les noms : c'est ce qu'il faut pour
  /// réécrire `DayCycle.anchors` sans rien redeviner.
  String _orderAsText() {
    String hex(Color c) => _hex(c);
    final b = StringBuffer()
      ..writeln('Ordre du cycle de 24 h — ${_order.length} palettes')
      ..writeln(
        'Heures calculées par DayCycle.autoSchedule '
        '(au prorata de la distance de couleur).',
      )
      ..writeln(
        'Dérive max sur 3 min : '
        '${DayCycle.worstSessionDrift(_schedule).toStringAsFixed(4)} '
        '(seuil ${DayCycle.justNoticeable})',
      )
      ..writeln();
    for (var i = 0; i < _order.length; i++) {
      final a = _order[i];
      b.writeln(
        'DayAnchor(${_schedule[i].hour.toStringAsFixed(2)}, '
        'Color(0xFF${hex(a.top).substring(1)}), '
        'Color(0xFF${hex(a.bottom).substring(1)}), '
        "'${a.label}'),",
      );
    }
    return b.toString();
  }

  double get _hour => _playing ? _run.value * 24 : _manualHour;

  void _reorder(int from, int to) {
    setState(() {
      // `onReorderItem` (et non l'ancien `onReorder`) livre un index déjà
      // ajusté au retrait de l'élément : rien à corriger ici.
      _order.insert(to, _order.removeAt(from));
      _pristine = false;
      _schedule = DayCycle.autoSchedule(_order);
    });
    _saveOrder();
  }

  void _resetOrder() {
    setState(() {
      _order = List.of(DayCycle.palettes);
      _pristine = true;
      _schedule = DayCycle.anchors;
    });
    _saveOrder();
  }

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
    final p = DayCycle.at(_hour, schedule: _schedule);
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
                const SizedBox(height: 2),
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        const Spacer(),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
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
            // L'indicateur en direct, demandé par Jay : il nomme ce qui est
            // affiché à l'instant même — donc les DEUX palettes en jeu au
            // milieu d'un segment, pas seulement la plus proche.
            Text(
              p.description,
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                shadows: [Shadow(color: Color(0xB3000000), blurRadius: 6)],
              ),
            ),
          ],
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

  /// La feuille de réordonnancement — demande de Jay, 2026-08-15.
  ///
  /// ### Ce que l'utilisateur pose, et ce que le moteur en déduit
  ///
  /// Jay pose **l'ordre**, jamais les heures. Celles-ci sont recalculées par
  /// [DayCycle.autoSchedule] au prorata de la distance de couleur de chaque
  /// segment — ce qui donne une vitesse perçue uniforme, donc un arrangement
  /// qui tient quel que soit l'ordre choisi.
  ///
  /// C'est ce partage qui rend la fonctionnalité sûre : régler des heures à la
  /// main rouvrirait la porte à un segment trop rapide (le défaut que le test
  /// des 1440 minutes avait attrapé deux fois), et il n'y aurait personne pour
  /// le voir sur un ordre composé par l'utilisateur.
  ///
  /// Le verdict est affiché quand même, parce qu'une garantie qu'on n'affiche
  /// pas est une garantie qu'on ne sait pas vérifier.
  void _openOrderSheet() {
    _run.stop();
    setState(() => _playing = false);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: NeoNeutrals.gray900,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) {
          final drift = DayCycle.worstSessionDrift(_schedule);
          final ok = drift < DayCycle.justNoticeable;
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.75,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Ordre des dégradés',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copier l\'ordre',
                          icon: const Icon(Icons.copy_all_outlined),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: _orderAsText()),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Ordre copié — heures comprises'),
                              ),
                            );
                          },
                        ),
                        if (!_pristine)
                          TextButton(
                            onPressed: () {
                              _resetOrder();
                              setSheet(() {});
                            },
                            child: const Text('Réinitialiser'),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                    child: Row(
                      children: [
                        Icon(
                          ok ? Icons.check_circle_outline : Icons.warning_amber,
                          size: 18,
                          color: ok ? Colors.white70 : NeoTheme.accentPink,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ok
                                ? 'Imperceptible : ${drift.toStringAsFixed(4)} '
                                      'de dérive sur 3 min (seuil '
                                      '${DayCycle.justNoticeable}).'
                                : 'Visible : ${drift.toStringAsFixed(4)} de '
                                      'dérive sur 3 min, au-dessus du seuil '
                                      '${DayCycle.justNoticeable}.',
                            style: TextStyle(
                              fontSize: 12,
                              color: ok ? Colors.white70 : NeoTheme.accentPink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ReorderableListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: _order.length,
                      // `onReorderItem` et non `onReorder` : la variante
                      // dépréciée livrait un index calculé AVANT le retrait de
                      // l'élément, qu'il fallait corriger soi-même. Celle-ci
                      // l'a déjà fait — et c'est exactement le décalage d'un
                      // cran qui se serait vu à chaque déplacement vers le bas.
                      onReorderItem: (from, to) {
                        _reorder(from, to);
                        setSheet(() {});
                      },
                      itemBuilder: (context, i) {
                        final a = _order[i];
                        // L'heure vient du calendrier recalculé, pas de la
                        // palette : c'est elle qui change quand on réordonne.
                        final at = _schedule[i].hour;
                        final next = _schedule[i + 1].hour;
                        return ListTile(
                          key: ValueKey(a.label),
                          leading: Container(
                            width: 34,
                            height: 46,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [a.top, a.bottom],
                              ),
                            ),
                          ),
                          title: Text(a.label),
                          subtitle: Text(
                            '${_clock(at)} → ${_clock(next)}  ·  '
                            '${(next - at).toStringAsFixed(1)} h',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: const Icon(Icons.drag_handle),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

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
            TextButton.icon(
              onPressed: _openOrderSheet,
              icon: const Icon(Icons.reorder, color: Colors.white, size: 20),
              label: Text(
                _pristine ? 'Ordre' : 'Ordre modifié',
                style: TextStyle(
                  color: _pristine ? Colors.white : NeoTheme.accentPink,
                ),
              ),
            ),
            const Spacer(),
            // Le curseur montre les COULEURS ; seul le défilement montre la
            // VITESSE. Les deux sont nécessaires pour juger.
            TextButton.icon(
              onPressed: _togglePlay,
              icon: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              label: Text(
                _playing ? 'Pause' : 'Jouer $_dayInSeconds s',
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
