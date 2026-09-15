import 'package:flutter/material.dart';

import '../motion.dart';
import '../theme.dart';

/// **Tirer vers le bas pour fermer** — le geste unique de fermeture des
/// visionneurs plein écran (Jay, 2026-09-14).
///
/// Vibe en chat, story, publication, Drop, sauvegardes : un seul composant
/// autour de chacun, jamais une copie par écran. Le futur feed et les
/// mini-cartes dans les listes n'en ont pas.
///
/// ## Le geste
///
/// - Le doigt tire vers le **bas** : le contenu **suit le doigt** — il
///   descend, rétrécit (jusqu'à [scaleMin]) et le fond noir s'efface vers la
///   couleur de l'app. Tout est proportionnel, rien ne saute.
/// - Relâché au-delà de [seuil] de la hauteur, **ou** d'un coup sec
///   ([vitesseSeuil]) : le contenu finit sa course et [onClose] est appelé.
/// - En deçà : il revient en place d'un ressort.
/// - Vers le **haut** : rien.
///
/// ## Pourquoi ça ne mange pas le geste de la carte
///
/// Ce composant ne pose qu'un reconnaisseur **vertical** ; la carte garde son
/// geste **libre** (retourner, incliner dans les deux sens). Flutter les
/// départage à la direction des premiers millimètres : un départ vertical
/// ferme, un départ horizontal attrape la carte — et la carte garde alors
/// tout le geste. Le détail, la source et la correction du 2026-09-15 sont
/// sur [TiltableCard] (`flippable_card.dart`).
///
/// ## Ce que ce fichier ne décide pas
///
/// Ce que fermer *signifie* — une ouverture consommée, une story lue — est
/// l'affaire de l'écran, qui reçoit [onClose] et fait ce qu'il faisait déjà
/// avec sa croix. Ici on ne fait que reconnaître le geste et animer.
class PullDownToClose extends StatefulWidget {
  const PullDownToClose({
    super.key,
    required this.child,
    required this.onClose,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onClose;

  /// Faux = le geste est ignoré (contenu embarqué dans un autre écran).
  final bool enabled;

  /// Part de la hauteur de l'écran au-delà de laquelle relâcher ferme.
  /// « Un quart de l'écran » — validé par Jay.
  static const seuil = 0.25;

  /// Vitesse (px/s) vers le bas au-delà de laquelle un coup sec ferme, même
  /// court.
  static const vitesseSeuil = 700.0;

  /// Échelle du contenu quand le geste a parcouru [distancePleineEchelle] de
  /// la hauteur.
  static const scaleMin = 0.85;
  static const distancePleineEchelle = 0.5;

  /// **La décision, pure.** C'est la seule ligne qui puisse se tromper en
  /// silence : trop bas, l'écran se ferme sous un doigt qui voulait juste
  /// incliner ; trop haut, le geste « ne marche pas ».
  static bool shouldClose({
    required double drag,
    required double velocity,
    required double height,
  }) => drag >= height * seuil || (drag > 0 && velocity >= vitesseSeuil);

  /// L'échelle du contenu pour un déplacement donné — proportionnelle, bornée.
  static double scaleFor({required double drag, required double height}) {
    if (height <= 0) return 1;
    final t = (drag / (height * distancePleineEchelle)).clamp(0.0, 1.0);
    return 1 - (1 - scaleMin) * t;
  }

  @override
  State<PullDownToClose> createState() => _PullDownToCloseState();
}

class _PullDownToCloseState extends State<PullDownToClose>
    with SingleTickerProviderStateMixin {
  /// Déplacement courant, en px, jamais négatif.
  double _drag = 0;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: NeoMotion.ample,
  )..addListener(() => setState(() => _drag = _tween.evaluate(_anim)));

  Tween<double> _tween = Tween(begin: 0, end: 0);
  var _closing = false;

  void _onStart(DragStartDetails _) => _anim.stop();

  void _onUpdate(DragUpdateDetails d) {
    if (_closing) return;
    setState(() => _drag = (_drag + d.delta.dy).clamp(0.0, double.infinity));
  }

  void _onEnd(DragEndDetails d) {
    if (_closing) return;
    final height = context.size?.height ?? 800;
    final ferme = PullDownToClose.shouldClose(
      drag: _drag,
      velocity: d.velocity.pixelsPerSecond.dy,
      height: height,
    );
    if (ferme) {
      _closing = true;
      _animateTo(height).whenComplete(() {
        if (mounted) widget.onClose();
      });
    } else {
      _animateTo(0);
    }
  }

  TickerFuture _animateTo(double cible) {
    _tween = Tween(begin: _drag, end: cible);
    return _anim.forward(from: 0);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final height = MediaQuery.sizeOf(context).height;
    final scale = PullDownToClose.scaleFor(drag: _drag, height: height);
    // Le fond derrière le contenu : la couleur de l'app, qui se révèle à
    // mesure que le visionneur s'en va. La route reste opaque ; c'est ce
    // fond qui joue le rôle de « l'écran d'en dessous ».
    final t = (_drag / (height * PullDownToClose.distancePleineEchelle)).clamp(
      0.0,
      1.0,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: ColoredBox(
        color: Color.lerp(Colors.black, context.palette.ground, t)!,
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topCenter,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
