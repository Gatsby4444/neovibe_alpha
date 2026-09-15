import 'package:flutter/material.dart';

/// **Quel élément du fil est « actif »** — celui dont le centre est le plus
/// proche du centre de la fenêtre. C'est lui qui joue ses vidéos et compte
/// une vue ; les autres se taisent.
///
/// Les éléments s'enregistrent avec [TrackedItem] ; le suiveur relit leurs
/// positions à chaque défilement (et une fois posé) et publie l'identifiant
/// de l'actif dans [active]. Rien d'autre : ce que « actif » déclenche
/// appartient à chaque cellule.
class ActiveItemTracker extends StatefulWidget {
  const ActiveItemTracker({super.key, required this.child});

  final Widget child;

  static ActiveItemTrackerState of(BuildContext context) =>
      context.findAncestorStateOfType<ActiveItemTrackerState>()!;

  @override
  State<ActiveItemTracker> createState() => ActiveItemTrackerState();
}

class ActiveItemTrackerState extends State<ActiveItemTracker> {
  final active = ValueNotifier<String?>(null);
  final _items = <String, BuildContext>{};

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
