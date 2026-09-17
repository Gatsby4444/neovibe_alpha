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
/// doigt part tout de suite, il **renonce définitivement** — un défilement
/// prolongé ne doit pas finir par retourner la carte.
///
/// ⚠️ **Une fois la pose faite, il gagne vite** : [seuilArme] pixels
/// suffisent, moins que les 18 px du défilement et du retournement. Sans
/// cela, un geste posé puis glissé à l'horizontale serait repris par le
/// retournement, et la manipulation n'existerait jamais (Jay, 2026-09-18 :
/// le swipe horizontal rapide doit retourner la carte **comme avant**, et
/// c'est la **zone centrale maintenue** qui donne la manipulation).
class HeldPanGestureRecognizer extends PanGestureRecognizer {
  HeldPanGestureRecognizer({
    super.debugOwner,
    this.delai = kTempsDePose,
    this.seuilArme = 8,
  });

  /// Le temps pendant lequel le doigt doit rester posé avant de pouvoir
  /// emmener la carte.
  final Duration delai;

  /// Le déplacement qui suffit à gagner **une fois la pose faite**. Plus
  /// petit que les seuils du défilement et du retournement : c'est ce qui
  /// donne la priorité à un geste délibéré.
  final double seuilArme;

  Duration? _pose;
  var _parcouru = 0.0;
  var _apresPose = 0.0;
  var _renonce = false;
  var _gagne = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pose = event.timeStamp;
    _parcouru = 0;
    _apresPose = 0;
    _renonce = false;
    _gagne = false;
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
    // La pose est faite : quelques pixels suffisent à emporter le geste.
    if (!_gagne && event is PointerMoveEvent) {
      _apresPose += event.delta.distance;
      if (_apresPose > seuilArme) {
        _gagne = true;
        resolve(GestureDisposition.accepted);
      }
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pose = null;
    _renonce = false;
    _gagne = false;
    _parcouru = 0;
    _apresPose = 0;
    super.didStopTrackingLastPointer(pointer);
  }
}

/// **90 ms** (Jay, 2026-09-18 ; 120 auparavant). Assez pour distinguer une
/// saisie d'un effleurement, assez court pour rester inconscient.
const kTempsDePose = Duration(milliseconds: 90);

/// **La part centrale de la carte qui écoute la pose.** Les bords — 20 % de
/// chaque côté — n'écoutent rien : ils sont là pour que le défilement et le
/// swipe soient sûrs d'eux (Jay : *« cela permet de libérer une zone sur les
/// côtés pour être sûr que c'est que du scroll »*).
const kZoneManipulation = 0.6;
