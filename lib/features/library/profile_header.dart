import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/theme.dart';
import '../../core/widgets/gradient.dart';
import '../cards/cards_repository.dart';

/// En-tête de profil (consigne Jay 2026-07-13) : PP à gauche avec les stats
/// à sa droite, puis en dessous et alignés à gauche : username, tag name
/// (typo distincte, sans guillemets ni mention), bio repliable (« voir
/// plus » au-delà de 130 caractères).
/// Réutilisé sur mon profil et sur celui d'une connexion ou d'un croisé.
/// [onFriendsTap] : sur MON profil, le compteur d'amis ouvre la liste.
class ProfileHeader extends ConsumerWidget {
  const ProfileHeader({super.key, required this.profile, this.onFriendsTap});
  final Profile profile;
  final VoidCallback? onFriendsTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(profileStatsProvider(profile.id)).value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Anneau en dégradé de marque autour de la photo de profil
              GradientRing(
                size: 100,
                child: CircleAvatar(
                  radius: 44,
                  backgroundImage: profile.avatarUrl == null
                      ? null
                      : NetworkImage(profile.avatarUrl!),
                  child: profile.avatarUrl == null
                      ? Text(
                          profile.displayName.characters.first.toUpperCase(),
                          style: const TextStyle(fontSize: 30),
                        )
                      : null,
                ),
              ),
              if (stats != null)
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _Stat(
                        value: stats.friends,
                        label: 'amis',
                        onTap: onFriendsTap,
                      ),
                      _Stat(value: stats.posts, label: 'posts'),
                      _Stat(value: stats.cardsWeek, label: 'cards / 7 j'),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            profile.displayName,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (profile.tagName != null && profile.tagName!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                profile.tagName!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.muted,
                  fontStyle: FontStyle.italic,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          if (profile.bio != null && profile.bio!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _ExpandableBio(bio: profile.bio!),
            ),
        ],
      ),
    );
  }
}

/// Bio repliée au-delà de 130 caractères affichés : « voir plus » (même typo
/// que la bio, plus blanc et lumineux) déplie le reste, « voir moins » à la
/// fin replie.
class _ExpandableBio extends StatefulWidget {
  const _ExpandableBio({required this.bio});
  final String bio;

  static const foldLength = 130;

  @override
  State<_ExpandableBio> createState() => _ExpandableBioState();
}

class _ExpandableBioState extends State<_ExpandableBio> {
  var _expanded = false;
  late final TapGestureRecognizer _toggle = TapGestureRecognizer()
    ..onTap = () => setState(() => _expanded = !_expanded);

  @override
  void dispose() {
    _toggle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyMedium;
    // « voir plus » : le halo était un blanc sur blanc en thème clair, donc
    // invisible. Il suit désormais la couleur de texte du thème (2026-08-10).
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final link = base?.copyWith(
      color: onSurface,
      fontWeight: FontWeight.w600,
      shadows: [
        Shadow(color: onSurface.withValues(alpha: 0.38), blurRadius: 8),
      ],
    );
    if (widget.bio.length <= _ExpandableBio.foldLength) {
      return Text(widget.bio, style: base);
    }
    return Text.rich(
      _expanded
          ? TextSpan(
              style: base,
              children: [
                TextSpan(text: widget.bio),
                TextSpan(text: ' voir moins', style: link, recognizer: _toggle),
              ],
            )
          : TextSpan(
              style: base,
              children: [
                TextSpan(
                  text:
                      '${widget.bio.substring(0, _ExpandableBio.foldLength).trimRight()}… ',
                ),
                TextSpan(text: 'voir plus', style: link, recognizer: _toggle),
              ],
            ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.onTap});
  final int value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          children: [
            Text(
              '$value',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.muted),
            ),
          ],
        ),
      ),
    );
  }
}
