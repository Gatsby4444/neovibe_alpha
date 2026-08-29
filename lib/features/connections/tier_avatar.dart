import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets/avatar.dart';
import 'friendship.dart';
import 'friendships_repository.dart';

/// Une photo de profil **entourée de son palier d'amitié**.
///
/// ## Pourquoi un widget et pas trois lignes recopiées
///
/// L'anneau doit apparaître au même endroit dans la liste d'amis, le Cercle,
/// le Ping et les stories. Recopié quatre fois, il aurait quatre épaisseurs,
/// quatre tailles, et le jour où Jay change une couleur il faudrait retrouver
/// les quatre. Le coût d'ajouter le cinquième cas est ce qui décide : ici il
/// vaut une ligne.
///
/// ## Il lit le palier lui-même, et c'est voulu
///
/// ⚠️ Le faire recevoir le palier obligerait chaque écran à aller le chercher —
/// donc à connaître le dépôt, donc à décider quoi faire pendant le chargement.
/// Quatre écrans, quatre réponses. Ici il n'y en a qu'une, et elle est prudente :
/// pas d'anneau tant qu'on ne sait pas.
class TierAvatar extends ConsumerWidget {
  const TierAvatar({
    super.key,
    required this.peerId,
    required this.storedAvatar,
    required this.initiale,
    this.size = 44,
  });

  final String peerId;
  final String? storedAvatar;
  final String initiale;
  final double size;

  /// L'épaisseur de l'anneau. Assez fine pour rester un liseré : un anneau
  /// épais mange la photo, et c'est la photo qu'on vient regarder.
  static const _epaisseur = 2.5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tier = ref.watch(tierOfProvider(peerId));
    final avatar = Avatar(
      stored: storedAvatar,
      radius: size / 2,
      fallback: Text(initiale),
    );

    if (!tier.porteUnAnneau) {
      return SizedBox(width: size, height: size, child: avatar);
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: tier.anneau(context.palette),
      ),
      padding: const EdgeInsets.all(_epaisseur),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // Le liseré de respiration entre l'anneau et la photo : sans lui les
          // deux se touchent et l'anneau a l'air d'une bavure.
          color: Theme.of(context).scaffoldBackgroundColor,
        ),
        child: Padding(
          padding: const EdgeInsets.all(1.5),
          child: ClipOval(child: avatar),
        ),
      ),
    );
  }
}

/// Le filtre par palier, tel qu'il est proposé à l'écran.
///
/// ⚠️ **`tous` n'est PAS un palier**, c'est l'absence de filtre. Le ranger dans
/// `FriendshipTier` aurait mis une valeur d'affichage dans une échelle sociale
/// — et toute comparaison `>= tous` serait devenue vraie pour tout le monde.
enum FiltreDePalier {
  tous('Tous', null),
  proches('Proches', FriendshipTier.close),
  inseparables('Inséparables', FriendshipTier.inner);

  const FiltreDePalier(this.label, this.minimum);

  final String label;

  /// Le palier minimum retenu. `null` = on ne filtre pas.
  final FriendshipTier? minimum;

  bool retient(FriendshipTier tier) =>
      minimum == null || tier.atteint(minimum!);
}
