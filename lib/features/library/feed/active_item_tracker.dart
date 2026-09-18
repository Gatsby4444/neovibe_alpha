import 'package:flutter/material.dart';

import '../../../app.dart' show routeObserver;

/// **Quel élément du fil est « actif »** — celui dont le centre est le plus
/// proche du centre de la fenêtre. C'est lui qui joue ses vidéos et compte
/// une vue ; les autres se taisent.
///
/// Les éléments s'enregistrent avec [TrackedItem] ; le suiveur relit leurs
/// positions à chaque défilement (et une fois posé) et publie l'identifiant
/// de l'actif dans [active]. Rien d'autre : ce que « actif » déclenche
/// appartient à chaque cellule.
///
/// ⚠️ **Un fil recouvert n'a AUCUN élément actif.** Jusqu'au 2026-09-18, le
/// suiveur ne connaissait que le défilement : quand un plein écran se posait
/// par-dessus le fil (une Vibe, un Flow), l'élément sous le doigt restait
/// « actif » — son lecteur vidéo continuait de décoder, invisible, pendant
/// que le plein écran ouvrait le sien sur la **même** vidéo. Deux décodeurs
/// pour une image, et la vue comptée deux fois. Un décodeur est une ressource
/// matérielle comptée (v0.9.197) : le suiveur écoute donc le navigateur et
/// publie `null` tant qu'un autre écran le recouvre.
class ActiveItemTracker extends StatefulWidget {
  const ActiveItemTracker({super.key, required this.child});

  final Widget child;

  static ActiveItemTrackerState of(BuildContext context) =>
      context.findAncestorStateOfType<ActiveItemTrackerState>()!;

  @override
  State<ActiveItemTracker> createState() => ActiveItemTrackerState();
}

class ActiveItemTrackerState extends State<ActiveItemTracker> with RouteAware {
  final active = ValueNotifier<String?>(null);
  final _items = <String, BuildContext>{};

  /// La route du fil, pour savoir quand un autre écran la recouvre.
  PageRoute<dynamic>? _route;

  /// Vrai tant qu'un écran est posé par-dessus le fil.
  var _covered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) routeObserver.unsubscribe(this);
      _route = route;
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    // Tout de suite, pas à la prochaine image : le plein écran qui arrive va
    // ouvrir son lecteur, celui du fil doit déjà s'être tu.
    _covered = true;
    if (active.value != null) active.value = null;
  }

  @override
  void didPopNext() {
    _covered = false;
    _schedule();
  }

  void register(String id, BuildContext ctx) {
    _items[id] = ctx;
    _schedule();
  }

  void unregister(String id) {
    _items.remove(id);
  }

  var _scheduled = false;

  /// Un seul calcul par image, quel que soit le nombre de notifications.
  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _recompute();
    });
  }

  void _recompute() {
    if (_covered) {
      if (active.value != null) active.value = null;
      return;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final viewportCenter = box.size.height / 2;
    String? best;
    var bestDistance = double.infinity;
    for (final entry in _items.entries) {
      final ro = entry.value.mounted ? entry.value.findRenderObject() : null;
      if (ro is! RenderBox || !ro.hasSize) continue;
      final top = ro.localToGlobal(Offset.zero, ancestor: box).dy;
      final center = top + ro.size.height / 2;
      // Un élément dont la moitié n'est pas dans la fenêtre n'est pas actif,
      // même s'il est le plus proche : on ne joue pas une vidéo qu'on ne
      // voit pas.
      final visibleTop = top.clamp(0.0, box.size.height);
      final visibleBottom = (top + ro.size.height).clamp(0.0, box.size.height);
      final visibleFraction = (visibleBottom - visibleTop) / ro.size.height;
      if (visibleFraction < 0.5) continue;
      final d = (center - viewportCenter).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = entry.key;
      }
    }
    if (active.value != best) active.value = best;
  }

  @override
  void dispose() {
    if (_route != null) routeObserver.unsubscribe(this);
    active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        _schedule();
        return false;
      },
      child: widget.child,
    );
  }
}

/// Un élément suivi : il s'enregistre à sa pose, se retire à sa dépose.
class TrackedItem extends StatefulWidget {
  const TrackedItem({super.key, required this.id, required this.child});

  final String id;
  final Widget child;

  @override
  State<TrackedItem> createState() => _TrackedItemState();
}

class _TrackedItemState extends State<TrackedItem> {
  ActiveItemTrackerState? _tracker;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tracker ??= context.findAncestorStateOfType<ActiveItemTrackerState>();
    _tracker?.register(widget.id, context);
  }

  @override
  void dispose() {
    _tracker?.unregister(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
