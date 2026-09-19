import 'package:flutter/material.dart';

/// **Où est chaque contenu à l'écran** — pour qu'un plein écran puisse se
/// refermer **sur sa cellule** au lieu du centre de l'écran (Jay,
/// 2026-09-19 : *« l'impression que le plein écran redevient la card, à sa
/// place »*).
///
/// Un registre **par écran hôte** (le fil, la grille du profil), jamais
/// global : le fil est une couverture posée sur la grille, les deux tiennent
/// les mêmes contenus, et seul celui qui a ouvert le plein écran est la
/// bonne cible. Le plein écran reçoit donc le registre de qui l'ouvre
/// ([AnchorScope.of]) — il ne devine rien.
///
/// Deux services :
/// - [rectOf] : la position d'un contenu, en coordonnées globales ;
/// - [reveal] : demander à l'hôte de **montrer** ce contenu (le fil se
///   repose dessus, la grille le fait défiler en vue) — c'est ce qui fait que
///   le dessous suit le plein écran, et que la cible existe au moment de
///   viser.
class AnchorScope extends StatefulWidget {
  const AnchorScope({super.key, required this.child, this.onReveal});

  final Widget child;

  /// Montrer ce contenu. Nul = l'hôte ne sait pas bouger.
  final void Function(String id)? onReveal;

  static AnchorScopeState? of(BuildContext context) =>
      context.findAncestorStateOfType<AnchorScopeState>();

  @override
  State<AnchorScope> createState() => AnchorScopeState();
}

class AnchorScopeState extends State<AnchorScope> {
  final _anchors = <String, BuildContext>{};

  void register(String id, BuildContext ctx) => _anchors[id] = ctx;

  void unregister(String id, BuildContext ctx) {
    if (_anchors[id] == ctx) _anchors.remove(id);
  }

  /// Le contexte du contenu [id], pour le faire défiler en vue.
  BuildContext? contextOf(String id) {
    final ctx = _anchors[id];
    return ctx != null && ctx.mounted ? ctx : null;
  }

  /// La boîte du contenu [id] à l'écran, ou nulle s'il n'est pas posé.
  Rect? rectOf(String id) {
    final ctx = _anchors[id];
    if (ctx == null || !ctx.mounted) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final origin = box.localToGlobal(Offset.zero);
    return origin & box.size;
  }

  void reveal(String id) => widget.onReveal?.call(id);

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Un contenu posé : il s'inscrit à sa pose, se retire à sa dépose.
class Anchored extends StatefulWidget {
  const Anchored({super.key, required this.id, required this.child});

  final String id;
  final Widget child;

  @override
  State<Anchored> createState() => _AnchoredState();
}

class _AnchoredState extends State<Anchored> {
  AnchorScopeState? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope ??= AnchorScope.of(context);
    _scope?.register(widget.id, context);
  }

  @override
  void didUpdateWidget(covariant Anchored old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      _scope?.unregister(old.id, context);
      _scope?.register(widget.id, context);
    }
  }

  @override
  void dispose() {
    _scope?.unregister(widget.id, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
