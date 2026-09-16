import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// **Les barres système au-dessus d'un écran noir** : icônes claires.
///
/// ⚠️ **Le thème de l'app fixe `systemOverlayStyle` pour TOUTES les AppBar**
/// (`core/theme.dart`) : identité claire → icônes sombres. Une AppBar noire
/// hérite donc d'icônes **sombres sur du noir**, c'est-à-dire invisibles. Ce
/// n'est pas une supposition : `material/app_bar.dart` (Flutter 3.44, lu le
/// 2026-09-16) résout
/// `widget.systemOverlayStyle ?? appBarTheme.systemOverlayStyle ?? defaults ??
/// _systemOverlayStyleForBrightness(…)` — la déduction par luminosité du fond
/// n'a lieu **que** si personne n'a répondu avant, et le thème répond
/// toujours.
///
/// Un écran noir dit donc lui-même de quelle couleur sont les icônes :
/// - **avec une AppBar** : `systemOverlayStyle: kSystemBarsOnDark` sur
///   l'AppBar — c'est elle qui couvre la barre d'état, un `AnnotatedRegion`
///   posé plus bas ne l'atteindrait pas ;
/// - **sans AppBar** : [DarkSystemBars] autour du `Scaffold`.
const kSystemBarsOnDark = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  // iOS lit `statusBarBrightness`, qui désigne le FOND et non les icônes :
  // les deux sont opposés, ce n'est pas une faute (même remarque que le thème).
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
);

/// Un écran noir **sans AppBar** : il annonce [kSystemBarsOnDark] tant qu'il
/// est au-dessus. L'écran d'en dessous reprend le sien en repartant — c'est
/// tout l'intérêt de l'annotation sur l'appel impératif
/// (`SystemChrome.setSystemUIOverlayStyle`), qui, lui, resterait en place
/// après la fermeture.
class DarkSystemBars extends StatelessWidget {
  const DarkSystemBars({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: kSystemBarsOnDark,
    child: child,
  );
}
