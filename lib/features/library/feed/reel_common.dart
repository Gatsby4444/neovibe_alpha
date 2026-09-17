import 'package:flutter/material.dart';

import '../../../core/models/library_item.dart';
import '../../../core/models/profile.dart';
import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../../core/utils/formats.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/card_type_badge.dart';
import '../../../core/widgets/press_veil.dart';
import '../../../core/widgets/pull_down_to_close.dart';
import '../open_profile.dart';

/// **Ce que les deux plein-écrans partagent** — celui des Vibes et celui des
/// Flows : l'identité de l'auteur, sa légende, et la fermeture au
/// sur-défilement.
///
/// Ils existaient une seule fois, dans l'écran des Vibes, tant qu'il n'y avait
/// qu'un plein écran. Le second (les Flows, 2026-09-17) en avait besoin à
/// l'identique : deux copies auraient divergé au premier réglage.

/// L'identité, en haut de la carte : photo, pseudo, date, type. Un appui mène
/// au profil de l'auteur (sauf le mien).
class ReelIdentity extends StatelessWidget {
  const ReelIdentity({
    super.key,
    required this.item,
    required this.owner,
    required this.mine,
  });

  final LibraryItem item;
  final Profile? owner;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final name = owner?.displayName ?? '';
    // Le voile dit au doigt qu'il a été entendu (Jay, 2026-09-17) ; clair,
    // parce qu'il se pose sur une image.
    return PressVeil(
      clair: true,
      onTap: owner == null || mine ? null : () => openProfile(context, owner!),
      child: Row(
        children: [
          Avatar(
            stored: owner?.avatarUrl,
            radius: 16,
            fallback: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
          ),
          const SizedBox(width: NeoSpace.sm),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: NeoSpace.sm),
          Text(
            timeAgo(item.createdAt),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(width: NeoSpace.sm),
          CardTypeBadge(type: item.cardType, fontSize: 10),
        ],
      ),
    );
  }
}

/// La légende, en bas de la carte — deux lignes, dépliable au tap.
class ReelCaption extends StatefulWidget {
  const ReelCaption({super.key, required this.text});

  final String text;

  @override
  State<ReelCaption> createState() => _ReelCaptionState();
}

class _ReelCaptionState extends State<ReelCaption> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: Text(
        widget.text,
        maxLines: _expanded ? 10 : 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
    );
  }
}

/// **Tirer vers le bas depuis la première page ferme.** Ici la liste tient
/// le geste vertical (c'est le défilement) : on ne peut pas poser un second
/// reconnaisseur par-dessus, il perdrait toujours. On lit donc ce que la
/// liste rapporte quand elle bute en haut — le sur-défilement — et on
/// applique la **même décision** et la **même animation** que
/// [PullDownToClose] (seuil, vitesse, échelle).
class OverscrollToClose extends StatefulWidget {
  const OverscrollToClose({
    super.key,
    required this.atFirstPage,
    required this.onClose,
    required this.child,
  });

  final bool atFirstPage;
  final VoidCallback onClose;
  final Widget child;

  @override
  State<OverscrollToClose> createState() => _OverscrollToCloseState();
}

class _OverscrollToCloseState extends State<OverscrollToClose>
    with SingleTickerProviderStateMixin {
  var _drag = 0.0;
  var _closing = false;
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() => setState(() => _drag = _tween.evaluate(_anim)));
  var _tween = Tween<double>(begin: 0, end: 0);

  bool _onNotification(ScrollNotification n) {
    if (_closing || !widget.atFirstPage) return false;
    if (n is OverscrollNotification && n.overscroll < 0) {
      // Le doigt tire vers le bas alors qu'on est déjà en haut.
      _anim.stop();
      setState(() => _drag -= n.overscroll);
    } else if (n is ScrollEndNotification && _drag > 0) {
      final height = context.size?.height ?? 800;
      final velocity = n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0;
      final ferme = PullDownToClose.shouldClose(
        drag: _drag,
        velocity: velocity,
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
    return false;
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
    final height = MediaQuery.sizeOf(context).height;
    final scale = PullDownToClose.scaleFor(drag: _drag, height: height);
    final t = (_drag / (height * PullDownToClose.distancePleineEchelle)).clamp(
      0.0,
      1.0,
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
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
