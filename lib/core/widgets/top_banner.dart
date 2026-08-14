import 'dart:async';

import 'package:flutter/material.dart';

/// Un bandeau court en haut de l'écran, qui glisse, dit une chose et s'en va.
///
/// Demande de Jay (2026-08-14) pour l'enregistrement d'une Vibe : « une petite
/// notification (genre popup pas notification réelle) dans un bandeau en haut ».
///
/// **Pourquoi pas un `SnackBar`.** Le SnackBar de Material arrive par le bas,
/// exactement là où vivent le bouton d'envoi et la barre d'onglets : il
/// recouvre ce sur quoi l'utilisateur vient de cliquer. Un `MaterialBanner`,
/// lui, pousse le contenu vers le bas et fait sauter la mise en page — sur un
/// écran d'envoi, la liste des destinataires se décalerait sous le doigt.
///
/// Ce bandeau-ci vit dans l'`Overlay` : il ne déplace rien et ne recouvre que
/// la zone de statut. C'est la seule des trois formes qui laisse l'écran
/// intact, ce qui compte d'autant plus qu'il annonce une action **déjà faite**
/// — il informe, il ne demande rien.
enum TopBannerTone {
  /// Ça vient de se produire.
  done,

  /// C'était déjà le cas — rien n'a changé, et ce n'est pas une erreur.
  already,
}

class TopBanner {
  TopBanner._();

  /// Le bandeau visible, s'il y en a un. Un seul à la fois : deux clics
  /// rapprochés remplacent le message au lieu d'empiler deux bandeaux qui se
  /// recouvriraient.
  static OverlayEntry? _current;
  static Timer? _timer;

  static void show(
    BuildContext context,
    String message, {
    TopBannerTone tone = TopBannerTone.done,
    Duration duration = const Duration(milliseconds: 2200),
  }) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _dismiss();
    final entry = OverlayEntry(
      builder: (context) => _TopBannerView(message: message, tone: tone),
    );
    _current = entry;
    overlay.insert(entry);
    _timer = Timer(duration, _dismiss);
  }

  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    _current?.remove();
    _current = null;
  }
}

class _TopBannerView extends StatefulWidget {
  const _TopBannerView({required this.message, required this.tone});

  final String message;
  final TopBannerTone tone;

  @override
  State<_TopBannerView> createState() => _TopBannerViewState();
}

class _TopBannerViewState extends State<_TopBannerView>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = switch (widget.tone) {
      TopBannerTone.done => scheme.primary,
      TopBannerTone.already => scheme.outline,
    };
    final icon = switch (widget.tone) {
      TopBannerTone.done => Icons.bookmark_added_rounded,
      TopBannerTone.already => Icons.bookmark_rounded,
    };
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 12,
      right: 12,
      child: FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, -0.6),
            end: Offset.zero,
          ).animate(curve),
          // Le bandeau est purement informatif : il ne doit intercepter aucun
          // geste, sinon un clic pressé juste après l'enregistrement tomberait
          // dessus au lieu du bouton visé.
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: accent.withValues(alpha: 0.55)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 19, color: accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.message,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
