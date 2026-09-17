import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// **Donner plus de marge au doigt qui ne part pas tout droit.**
///
/// ### Ce que Jay a vu, et ce que la source dit
///
/// *« Dans le fil on passe bien du mouvement de card au scroll même si le
/// doigt part légèrement de travers ; en plein écran la marge d'erreur semble
/// plus réduite »* (2026-09-17). Les réglages, eux, sont **identiques** des
/// deux côtés — vérifié dans la source de Flutter le 2026-09-17 :
/// `Scrollable` lit `MediaQuery.maybeGestureSettingsOf(context)`
/// (`scrollable.dart`), et les deux seuils sortent de là
/// (`computeHitSlop` / `computePanSlop`, `gestures/events.dart`).
///
/// Ce qui change, c'est la **conséquence** : dans le fil, un défilement parti
/// par erreur déplace la liste de trois pixels et on recommence ; en plein
/// écran, il **change de Vibe**. Le même taux d'erreur devient insupportable.
/// La réparation n'est donc pas d'aligner des réglages déjà alignés, c'est de
/// donner au plein écran **plus de marge qu'au fil**.
///
/// ### Le calcul, pour qu'il ne soit pas magique
///
/// Deux reconnaisseurs se disputent le doigt, et le premier qui atteint son
/// seuil gagne :
///
/// - le **défilement** compte la seule composante verticale, et accepte à
///   `touchSlop` (18 px par défaut) ;
/// - la **carte** compte la distance totale, et accepte à `panSlop`
///   (= `touchSlop × 2`, soit 36 px).
///
/// Un geste qui part à un angle θ de la verticale parcourt `d` et monte de
/// `d·cos θ`. La carte gagne quand `panSlop < touchSlop / cos θ`, c'est-à-dire
/// au-delà de `θ = arccos(touchSlop / panSlop)` :
///
/// | seuil du défilement | la carte gagne à partir de |
/// |---|---|
/// | 18 px (par défaut) | **60°** de la verticale — il faut viser l'horizontale |
/// | 30 px ([facteur] 1,67) | **34°** — un départ de travers suffit |
///
/// Au-delà de `panSlop` (36), le défilement ne gagnerait plus **jamais**, même
/// tout droit : [facteur] est donc borné en dessous de 2.
class ScrollSlop extends StatelessWidget {
  const ScrollSlop({super.key, required this.child, this.facteur = 1.67})
    : assert(facteur >= 1 && facteur < 2, 'au-delà de 2, plus de défilement');

  final Widget child;

  /// De combien le seuil du **défilement** est élargi. 1 = les réglages de
  /// l'appareil.
  final double facteur;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final base = mq.gestureSettings.touchSlop ?? kTouchSlop;
    return MediaQuery(
      data: mq.copyWith(
        gestureSettings: DeviceGestureSettings(touchSlop: base * facteur),
      ),
      child: child,
    );
  }
}

/// **Rétablit les réglages de gestes de l'appareil** pour son sous-arbre.
///
/// À poser **dans** un [ScrollSlop], autour de ce qui doit garder ses gestes
/// normaux : sans ça, la carte hériterait elle aussi du seuil élargi (son
/// `panSlop` vaut le double du `touchSlop` lu au même endroit) et deviendrait
/// plus dure à attraper — l'inverse de ce qu'on cherche.
///
/// Les réglages ne sont pas transportés : ils se relisent à la source, la
/// vue (`DeviceGestureSettings.fromView`), exactement comme le fait
/// `MediaQuery.fromView` à la racine de l'app.
class DeviceGestures extends StatelessWidget {
  const DeviceGestures({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      gestureSettings: DeviceGestureSettings.fromView(View.of(context)),
    ),
    child: child,
  );
}
