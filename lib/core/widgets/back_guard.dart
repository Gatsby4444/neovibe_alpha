import 'package:flutter/material.dart';

/// **Qui répond au retour système, dans cet ordre : d'abord ce qui est posé
/// par-dessus, ensuite l'écran.**
///
/// Un `PopScope` ne suffit pas quand un écran en contient un autre : Flutter
/// appelle **tous** les `PopScope` d'une même route à chaque retour. Avec la
/// coquille (« appuie une deuxième fois pour quitter ») et une couverture
/// (le fil posé sur le profil, 2026-09-19) sur la même route, un retour
/// aurait fermé la couverture **et** affiché le message de sortie.
///
/// Ici, une seule règle : ce qui se pose par-dessus s'**inscrit** ([register])
/// et est consulté en premier, du plus récent au plus ancien ; s'il ne reste
/// personne, [onUnhandled] décide — quitter l'app pour la coquille, fermer
/// l'écran par défaut.
class BackGuard extends StatefulWidget {
  const BackGuard({super.key, required this.child, this.onUnhandled});

  final Widget child;

  /// Le retour n'a été pris par personne. Nul = l'écran se ferme.
  final VoidCallback? onUnhandled;

  static BackGuardState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<BackGuardState>();

  @override
  State<BackGuard> createState() => BackGuardState();
}

/// Un intercepteur : rend `true` s'il a pris le retour.
typedef BackInterceptor = bool Function();

class BackGuardState extends State<BackGuard> {
  final _interceptors = <BackInterceptor>[];

  void register(BackInterceptor i) => setState(() => _interceptors.add(i));

  void unregister(BackInterceptor i) {
    if (!mounted) return;
    setState(() => _interceptors.remove(i));
  }

  /// Le retour, quelle qu'en soit l'origine.
  void _onBack() {
    for (final i in _interceptors.reversed) {
      if (i()) return;
    }
    final unhandled = widget.onUnhandled;
    if (unhandled != null) {
      unhandled();
    } else {
      // `pop()` direct : `maybePop` repasserait par ce `PopScope`.
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sans intercepteur ni règle propre, la route se ferme normalement (et
    // Android garde son animation de retour anticipé).
    final natural = _interceptors.isEmpty && widget.onUnhandled == null;
    return PopScope(
      canPop: natural,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBack();
      },
      child: widget.child,
    );
  }
}
