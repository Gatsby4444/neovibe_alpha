import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../content/likes.dart';

/// **Aimer au geste, et le voir.**
///
/// Demandes de Jay du 2026-09-17 : *« sur le mode plein écran sur une card, un
/// appui long like la card, et une animation du like »* ; *« pour les
/// publications, appui long ou double tap = like »*.
///
/// Trois règles, et elles tiennent ensemble :
///
/// 1. **Le geste n'enlève jamais un like.** Un double tap sur une publication
///    déjà aimée rejoue l'animation sans rien défaire — un geste rapide ne
///    doit pas pouvoir détruire ce qu'on ne voulait pas toucher. Retirer un
///    like reste le travail du cœur, qui, lui, se vise.
/// 2. **L'animation part même si le serveur met du temps** : elle dit « c'est
///    parti », pas « c'est arrivé » (le compte, lui, est déjà optimiste dans
///    [LikesStore]).
/// 3. **Le geste n'avale rien** : le tap ordinaire reste disponible pour
///    celui qui le portait déjà (retourner une carte, couper le son).
///
/// ⚠️ Un `onDoubleTap` **retarde** le `onTap` du temps du second appui
/// (~300 ms) : c'est le prix, et c'est pour ça qu'il n'est posé que là où
/// Jay l'a demandé — sur les publications, pas sur les Vibes, où le tap
/// retourne la carte et doit rester immédiat.
class LikeBurst extends ConsumerStatefulWidget {
  const LikeBurst({
    super.key,
    required this.contentId,
    required this.child,
    this.onTap,
    this.doubleTap = false,
    this.longPress = true,
    this.size = 108,
  });

  final String contentId;
  final Widget child;

  /// Ce que le tap simple faisait déjà, s'il faisait quelque chose.
  final VoidCallback? onTap;

  /// Le double tap aime (les publications).
  final bool doubleTap;

  /// L'appui long aime (partout).
  final bool longPress;

  /// La taille du cœur qui jaillit.
  final double size;

  @override
  ConsumerState<LikeBurst> createState() => _LikeBurstState();
}

class _LikeBurstState extends ConsumerState<LikeBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _aimer() async {
    final deja = ref.read(likesStoreProvider)[widget.contentId]?.liked ?? false;
    _anim.forward(from: 0);
    if (deja) return; // on ne défait pas au geste (règle 1)
    try {
      await ref.read(likesStoreProvider.notifier).toggle(widget.contentId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible pour l\'instant.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // ⚠️ **opaque**, pas « deferToChild » : un média encore en
      // chargement ne peint rien, et le geste tomberait dans le vide à
      // l'endroit même où l'utilisateur regarde. La carte, plus profonde,
      // garde ses propres gestes.
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTap: widget.doubleTap ? _aimer : null,
      onLongPress: widget.longPress ? _aimer : null,
      child: Stack(
        alignment: Alignment.center,
        children: [
          widget.child,
          // Le cœur ne prend aucun doigt et ne change aucune taille : il ne
          // fait que passer.
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (context, _) =>
                      _Coeur(t: _anim.value, size: widget.size),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Le cœur qui jaillit : il bondit un peu au-delà de sa taille, retombe, et
/// s'efface. `t` va de 0 (rien) à 1 (fini).
class _Coeur extends StatelessWidget {
  const _Coeur({required this.t, required this.size});

  final double t;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (t == 0 || t == 1) return const SizedBox.shrink();
    // Échelle : 0,4 → 1,15 → 1,0 ; opacité : pleine, puis fondue sur le
    // dernier tiers.
    final echelle = t < 0.45
        ? Curves.easeOutBack.transform(t / 0.45) * 1.15
        : 1.15 - 0.15 * Curves.easeOut.transform((t - 0.45) / 0.55);
    final opacite = t < 0.65 ? 1.0 : 1 - (t - 0.65) / 0.35;
    return Opacity(
      opacity: opacite.clamp(0, 1),
      child: Transform.scale(
        scale: echelle.clamp(0.0, 1.3),
        child: Icon(
          Icons.favorite,
          size: size,
          color: Colors.white,
          shadows: const [Shadow(color: Colors.black38, blurRadius: 18)],
        ),
      ),
    );
  }
}
