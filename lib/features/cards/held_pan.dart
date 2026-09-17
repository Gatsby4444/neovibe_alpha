import 'package:flutter/gestures.dart';

/// **Le temps de pose : ce qui sépare un défilement d'un geste de carte.**
///
/// Proposition de Jay, 2026-09-17, après deux essais ratés sur la distance et
/// l'angle : *« si l'utilisateur fait un mouvement bref c'est un scroll, et
/// pour activer l'orientation il doit conserver son doigt un petit peu plus
/// longtemps sur la card avant de le glisser »*.
///
/// ### Pourquoi c'est la bonne métrique, alors que la distance ne l'était pas
///
/// Un défilement et un geste de carte se ressemblent en **distance** et en
/// **direction** : les départager là-dessus, c'est arbitrer entre deux erreurs
/// (soit la carte vole des défilements, soit l'inverse — les deux ont été
/// essayés, les deux ont gêné). Ils ne se ressemblent pas du tout en
/// **intention** : on effleure pour défiler, on **saisit** pour manipuler. Le
/// temps entre le contact et le premier mouvement mesure exactement cette
/// différence-là.
///
/// ### Comment
///
/// Pendant [kTempsDePose], les mouvements ne sont pas transmis au
/// reconnaisseur : il ne peut donc pas franchir son seuil, ni gagner. Si le
/// doigt part tout de suite, le défilement gagne seul. S'il s'attarde, la
/// carte entre dans la course — et il lui faut alors son déplacement habituel
/// pour l'emporter, compté **à partir de là** : la carte ne saute pas.
class HeldPanGestureRecognizer extends PanGestureRecognizer {
  HeldPanGestureRecognizer({super.debugOwner, this.delai = kTempsDePose});

  /// Le temps pendant lequel le doigt doit rester posé avant de pouvoir
  /// emmener la carte.
  final Duration delai;

  Duration? _pose;
  var _parcouru = 0.0;
  var _renonce = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pose = event.timeStamp;
    _parcouru = 0;
    _renonce = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (_renonce) return;
    final pose = _pose;
    if (pose != null &&
        event is PointerMoveEvent &&
        event.timeStamp - pose < delai) {
      _parcouru += event.delta.distance;
      // ⚠️ **Parti trop tôt = ce n'est plus pour la carte, et ça ne le
      // redeviendra pas.** Le premier jet se contentait d'ignorer ces
      // mouvements : le doigt reprenait la carte dès la 120ᵉ milliseconde,
      // même s'il était parti à la première — donc un défilement prolongé
      // finissait par retourner la carte. Un contre-test l'a montré.
      if (_parcouru > computeHitSlop(event.kind, gestureSettings)) {
        _renonce = true;
        resolve(GestureDisposition.rejected);
      }
      return;
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pose = null;
    _renonce = false;
    _parcouru = 0;
    super.didStopTrackingLastPointer(pointer);
  }
}

/// **120 ms.** En dessous, l'œil ne distingue plus « poser puis glisser » de
/// « glisser » : le geste de carte partirait encore tout seul. Au-dessus de
/// 200, la pose devient une attente consciente — et Jay demande justement
/// l'inverse, *« un effet inconscient »*.
const kTempsDePose = Duration(milliseconds: 120);
