import 'package:flutter/material.dart';

import 'back_guard.dart';

/// **Une couverture posée sur un écran** — le fil d'un profil, par exemple
/// (Jay, 2026-09-19) : *« on est dans une surcouche de la page profil et pas
/// dans une page dédiée »*. La barre de navigation reste en dessous, et pour
/// partir on **découvre** l'écran d'un balayage vers la droite : la
/// couverture suit le doigt, l'écran est déjà là derrière — *« pas d'écran
/// noir intermédiaire, comme lorsqu'on retire une couverture »*.
///
/// Pourquoi pas une route : une route poussée couvre **tout**, la barre de
/// navigation comprise — c'est le contraire de ce que Jay demande. Ici,
/// l'hôte est dans la section, et la couverture avec lui.
///
/// Le retour système ferme la couverture avant tout ([BackGuard]).
class CoverHost extends StatefulWidget {
  const CoverHost({super.key, required this.child});

  final Widget child;

  static CoverHostState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<CoverHostState>();

  @override
  State<CoverHost> createState() => CoverHostState();
}

class CoverHostState extends State<CoverHost> {
  Widget? _cover;
  BackGuardState? _guard;

  bool get isCovered => _cover != null;

  /// Pose [cover] par-dessus l'écran (en remplaçant l'éventuelle précédente).
  void show(Widget cover) {
    setState(() => _cover = cover);
    _guard ??= BackGuard.maybeOf(context)?..register(_onBack);
  }

  void hide() {
    if (!mounted) return;
    setState(() => _cover = null);
    _guard?.unregister(_onBack);
    _guard = null;
  }

  bool _onBack() {
    if (_cover == null) return false;
    hide();
    return true;
  }

  @override
  void dispose() {
    _guard?.unregister(_onBack);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cover = _cover;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (cover != null)
          Uncoverable(
            key: const ValueKey('cover'),
            onUncovered: hide,
            child: cover,
          ),
      ],
    );
  }
}

/// **Le geste de découverte** : la couverture suit le doigt vers la droite,
/// et se retire si on l'a tirée assez loin ou assez vite.
///
/// ⚠️ **Il n'existe qu'en dehors de tout contenu** (Jay, 2026-09-19 : *« le
/// réflexe de vouloir swiper pour retourner une card existe, mais parfois ce
/// n'est pas une card ou c'est une card mono »*) : en-tête, légende, marges,
/// espaces entre les cellules — un `HorizontalDragGestureRecognizer`
/// ordinaire, que tout contenu, plus profond, bat. Une card à deux faces se
/// retourne, un carrousel se feuillette (et ne rend pas la main sur sa
/// première image), une card mono ou une photo seule **absorbent** le geste
/// sans rien faire (leur zone neutre). Un premier jet lisait aussi le
/// sur-défilement des carrousels pour découvrir depuis la première image ;
/// retiré le jour même à sa demande.
class Uncoverable extends StatefulWidget {
  const Uncoverable({
    super.key,
    required this.onUncovered,
    required this.child,
  });

  final VoidCallback onUncovered;
  final Widget child;

  /// Retirer la couverture : tirée sur plus d'un tiers de la largeur, ou
  /// lâchée d'un coup sec vers la droite (au-delà de quelques pixels, sinon
  /// un simple tap qui bouge d'un souffle déclencherait).
  static bool shouldUncover({
    required double dx,
    required double velocity,
    required double width,
  }) => dx > 12 && (dx > width * 0.3 || velocity > 600);

  @override
  State<Uncoverable> createState() => _UncoverableState();
}

class _UncoverableState extends State<Uncoverable>
    with SingleTickerProviderStateMixin {
  var _dx = 0.0;
  var _leaving = false;
  late final AnimationController _anim;
  var _tween = Tween<double>(begin: 0, end: 0);

  /// La largeur de la couverture, relevée à la mise en page — jamais lue sur
  /// le `RenderObject` pendant un build.
  var _width = 1.0;

  /// **Une liste de la couverture est en mouvement** (sur sa lancée après un
  /// geste). Flutter rend alors son contenu sourd au doigt — le prochain
  /// toucher sert à l'ARRÊTER — si bien qu'un balayage sur une card
  /// n'atteignait jamais la card, mais bien la couverture, au-dessus, qui
  /// fermait le fil (Jay, 2026-09-19 : *« comme si l'affichage de la card et
  /// sa délimitation n'étaient pas coordonnés »*). Un glissement qui commence
  /// pendant le mouvement est donc **ignoré** : il arrête la liste, rien
  /// d'autre.
  ///
  /// ⚠️ Mesuré par l'**instant du dernier mouvement sur la lancée**, pas par
  /// un drapeau début/fin : le toucher qui arrête la liste produit la
  /// notification de fin AVANT que notre geste ne commence (la liste, plus
  /// profonde, traite le doigt la première) — un drapeau serait déjà
  /// retombé. Un glissement qui commence moins de [_elan] après le dernier
  /// mouvement (`dragDetails == null` = sur la lancée, pas sous le doigt) est
  /// ignoré. L'horloge murale est assumée ici : c'est une fenêtre de geste,
  /// comme `kDoubleTapTimeout`, et le temps d'image ne court pas quand rien
  /// ne bouge.
  DateTime? _dernierElan;
  static const _elan = Duration(milliseconds: 120);

  /// Le glissement en cours a commencé pendant le mouvement : on n'en fait
  /// rien jusqu'au relâchement.
  var _ignore = false;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollUpdateNotification && n.dragDetails == null) {
      _dernierElan = DateTime.now();
    }
    return false;
  }

  void _dragStart() {
    final dernier = _dernierElan;
    _ignore = dernier != null && DateTime.now().difference(dernier) < _elan;
  }

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() => setState(() => _dx = _tween.evaluate(_anim)));
  }

  void _move(double delta) {
    if (_leaving || _ignore) return;
    _anim.stop();
    setState(() => _dx = (_dx + delta).clamp(0.0, _width));
  }

  void _release(double velocity) {
    if (_ignore) {
      _ignore = false;
      return;
    }
    if (_leaving || _dx <= 0) return;
    if (Uncoverable.shouldUncover(dx: _dx, velocity: velocity, width: _width)) {
      _leaving = true;
      _animateTo(_width).whenComplete(() {
        if (mounted) widget.onUncovered();
      });
    } else {
      _animateTo(0);
    }
  }

  TickerFuture _animateTo(double cible) {
    _tween = Tween(begin: _dx, end: cible);
    return _anim.forward(from: 0);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth.isFinite && constraints.maxWidth > 0
          ? constraints.maxWidth
          : MediaQuery.sizeOf(context).width;
      return _build(context);
    },
  );

  Widget _build(BuildContext context) {
    final t = (_dx / _width).clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Le voile sur l'écran découvert : présent tant que la couverture est
        // en place, il s'efface à mesure qu'elle s'en va. Il ne laisse pas
        // passer le doigt — l'écran d'en dessous n'est pas encore le sien.
        IgnorePointer(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.35 * (1 - t)),
          ),
        ),
        Transform.translate(
          offset: Offset(_dx, 0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                if (_dx > 0)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 18,
                    offset: const Offset(-6, 0),
                  ),
              ],
            ),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) => _dragStart(),
                onHorizontalDragUpdate: (d) => _move(d.delta.dx),
                onHorizontalDragEnd: (d) =>
                    _release(d.velocity.pixelsPerSecond.dx),
                onHorizontalDragCancel: () => _release(0),
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
