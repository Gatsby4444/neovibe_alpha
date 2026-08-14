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
    this.busy = false,
    this.height = 96,
  });

  /// Texte affiché dans le bouton. Poussé dans la propriété `label` du
  /// ViewModel — sans elle, il aurait fallu quatre `.riv`.
  final String label;

  /// Null = bouton inerte.
  final VoidCallback? onPressed;

  /// Envoi en cours : le bouton **reste dans son état pressé** — celui où il
  /// devient rond — et sert de loader (demande de Jay, 2026-08-14). C'est le
  /// seul moment où le Dart écrit les booléens du ViewModel ; le reste du temps
  /// ils appartiennent aux listeners.
  final bool busy;

  /// Ce qui s'affiche si Rive n'est pas disponible.
  final Widget fallback;

  /// Hauteur du graphique. L'artboard fait 220 × 110, donc la largeur suit à
  /// `2 × height` — et c'est **exactement** la zone sensible au doigt.
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
  rive.ViewModelInstanceBoolean? _pressedBg;
  rive.ViewModelInstanceBoolean? _pressedBtn;

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
        _pressedBg = viewModel.boolean('pressedBg');
        _pressedBtn = viewModel.boolean('pressedBtn');
      });
      if (widget.busy) _holdPressed(true);
    } catch (e) {
      AppLog.instance.error('Rive', 'bouton d\'envoi indisponible : $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Maintient (ou relâche) l'état pressé depuis le Dart.
  ///
  /// Les mêmes booléens sont écrits par les listeners `down`/`up`/`exit` de la
  /// state machine. Il n'y a pas de conflit, et pas par chance : pendant
  /// [RiveSendButton.busy] le graphique passe en `RiveHitTestBehavior.none`,
  /// donc **Rive ne reçoit plus aucun pointeur** et ne peut plus rien écrire.
  /// La cause du conflit est supprimée, pas surveillée.
  void _holdPressed(bool held) {
    _pressedBg?.value = held;
    _pressedBtn?.value = held;
  }

  @override
  void didUpdateWidget(RiveSendButton old) {
    super.didUpdateWidget(old);
    // Le libellé peut changer sans que le graphique soit rechargé (le même
    // bouton sert les quatre destinations).
    if (widget.label != old.label) _label?.value = widget.label;
    if (widget.busy != old.busy) _holdPressed(widget.busy);
  }

  @override
  void dispose() {
    // Ressources natives : elles ne sont pas ramassées par le GC Dart au
    // moment où l'écran disparaît. Ordre inverse de la création.
    _label?.dispose();
    _pressedBg?.dispose();
    _pressedBtn?.dispose();
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
      child: Center(
        // La zone sensible épouse EXACTEMENT le graphique (artboard 220 × 110).
        //
        // Sans ça, le `GestureDetector` couvrait toute la largeur de la barre
        // alors que le bouton dessiné, en `Fit.contain`, n'en occupait que le
        // milieu : relâcher le doigt **à côté du bouton visible** déclenchait
        // quand même l'envoi. La règle demandée par Jay — relâcher hors de la
        // zone est un abandon — n'a de sens que si « la zone » est ce qu'on
        // voit.
        child: AspectRatio(
          aspectRatio: 220 / 110,
          child: GestureDetector(
            // `onTap` de Flutter ne se déclenche QUE si le doigt se pose et se
            // relève dans cette zone. Doigt maintenu sans relâcher : rien.
            // Relâché en dehors : `onTapCancel`, donc rien non plus. C'est le
            // comportement demandé, et il est natif — aucun garde-fou à écrire.
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: rive.RiveWidget(
              controller: controller,
              fit: rive.Fit.contain,
              // Pendant l'envoi, Rive ne reçoit plus rien : le bouton est
              // inerte, et surtout ses listeners ne peuvent plus défaire
              // l'état pressé que le Dart maintient.
              hitTestBehavior: widget.busy
                  ? rive.RiveHitTestBehavior.none
                  : rive.RiveHitTestBehavior.transparent,
            ),
          ),
        ),
      ),
    );
  }
}
