import 'package:flutter/material.dart';
import 'package:rive/rive.dart' as rive;

import '../diagnostics/app_log.dart';

/// Le bouton d'envoi dessiné par Jay dans Rive.
///
/// Fichier : `assets/rive/watch_reel_button.riv` — artboard `Main Board`,
/// state machine `State Machine 1`, ViewModel `SendButton`.
///
/// ## Ce qui est piloté depuis le Dart
///
/// | Propriété du ViewModel | Rôle |
/// |---|---|
/// | `label` (string) | le texte du bouton — **quatre libellés différents selon la destination** |
/// | `pressedBg` / `pressedBtn` (bool) | l'état pressé, alimenté par les listeners Rive eux-mêmes |
///
/// Les deux booléens **ne sont pas écrits ici** : ce sont les listeners
/// `down`/`up`/`exit` de la state machine qui les portent, donc l'animation
/// répond au doigt sans aller-retour par Flutter. Les lire depuis le Dart n'a
/// aucun intérêt ; les écrire entrerait en conflit avec eux.
///
/// ## Le geste, lui, vient de Flutter
///
/// `RiveHitTestBehavior.transparent` : les listeners Rive reçoivent le
/// pointeur (donc l'animation joue) **et** le geste traverse jusqu'au
/// `GestureDetector`. C'est le seul des quatre modes qui donne les deux —
/// `translucent` aurait laissé Rive consommer le tap dès qu'une zone est
/// touchée, c'est-à-dire exactement sur le bouton.
///
/// ## Dégradation
///
/// Tant que le fichier n'est pas chargé, et **définitivement s'il échoue**,
/// c'est [fallback] qui s'affiche. Un bouton d'envoi absent rend l'app
/// inutilisable : le rendu Rive est un habillage, jamais une dépendance.
class RiveSendButton extends StatefulWidget {
  const RiveSendButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.fallback,
    this.height = 62,
  });

  /// Texte affiché dans le bouton. Poussé dans la propriété `label` du
  /// ViewModel — sans elle, il aurait fallu quatre `.riv`.
  final String label;

  /// Null = bouton inerte (envoi en cours). L'animation reste vivante : elle
  /// dit que l'app n'est pas figée.
  final VoidCallback? onPressed;

  /// Ce qui s'affiche si Rive n'est pas disponible.
  final Widget fallback;

  final double height;

  @override
  State<RiveSendButton> createState() => _RiveSendButtonState();
}

class _RiveSendButtonState extends State<RiveSendButton> {
  static const _asset = 'assets/rive/watch_reel_button.riv';

  rive.File? _file;
  rive.RiveWidgetController? _controller;
  rive.ViewModelInstance? _viewModel;
  rive.ViewModelInstanceString? _label;

  /// Le chargement a échoué : on ne réessaie pas à chaque `build`. Un asset
  /// manquant ou un moteur natif absent ne se répare pas tout seul, et
  /// réessayer boucherait le journal à chaque image.
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await rive.File.asset(
        _asset,
        riveFactory: rive.Factory.rive,
      );
      if (file == null) throw StateError('fichier illisible');
      final controller = rive.RiveWidgetController(file);
      final viewModel = controller.dataBind(rive.DataBind.auto());
      if (!mounted) {
        viewModel.dispose();
        controller.dispose();
        file.dispose();
        return;
      }
      setState(() {
        _file = file;
        _controller = controller;
        _viewModel = viewModel;
        _label = viewModel.string('label')?..value = widget.label;
      });
    } catch (e) {
      AppLog.instance.error('Rive', 'bouton d\'envoi indisponible : $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(RiveSendButton old) {
    super.didUpdateWidget(old);
    // Le libellé peut changer sans que le graphique soit rechargé (le même
    // bouton sert les quatre destinations).
    if (widget.label != old.label) _label?.value = widget.label;
  }

  @override
  void dispose() {
    // Ressources natives : elles ne sont pas ramassées par le GC Dart au
    // moment où l'écran disparaît. Ordre inverse de la création.
    _label?.dispose();
    _viewModel?.dispose();
    _controller?.dispose();
    _file?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_failed || controller == null) return widget.fallback;

    return SizedBox(
      height: widget.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Opacity(
          opacity: widget.onPressed == null ? 0.55 : 1,
          child: rive.RiveWidget(
            controller: controller,
            fit: rive.Fit.contain,
            hitTestBehavior: rive.RiveHitTestBehavior.transparent,
          ),
        ),
      ),
    );
  }
}
