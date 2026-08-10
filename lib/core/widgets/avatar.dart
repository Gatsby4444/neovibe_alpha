import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../supabase_providers.dart';

/// Chemin de l'avatar dans le bucket, à partir de ce qui est stocké dans
/// `profiles.avatar_url`.
///
/// Tolère les deux formes, parce que la base contient les deux :
/// - le **chemin** (`<uid>/avatar.jpg`), ce qu'on enregistre depuis le
///   2026-08-10 ;
/// - une ancienne **URL publique** complète, éventuellement suivie d'un
///   `?v=…` de contournement de cache.
String? avatarPath(String? stored) {
  if (stored == null || stored.isEmpty) return null;
  var value = stored;
  const marker = '/avatars/';
  final at = value.indexOf(marker);
  if (at != -1) value = value.substring(at + marker.length);
  final query = value.indexOf('?');
  if (query != -1) value = value.substring(0, query);
  return value.isEmpty ? null : value;
}

/// URL signée d'un avatar.
///
/// Le bucket `avatars` est **privé** depuis le 2026-08-10 (« contrôle complet
/// de l'écosystème ») : il n'y a plus d'URL publique, chaque affichage demande
/// une autorisation au serveur, qui vérifie que l'appelant a le droit de voir
/// ce profil.
///
/// Signée pour 1 h et mise en cache par le provider : on ne redemande pas une
/// autorisation à chaque reconstruction de widget.
final avatarUrlProvider = FutureProvider.family<String?, String>((
  ref,
  stored,
) async {
  final path = avatarPath(stored);
  if (path == null) return null;
  try {
    return await ref
        .watch(supabaseProvider)
        .storage
        .from('avatars')
        .createSignedUrl(path, 3600);
  } catch (_) {
    // Profil hors de portée, ou fichier absent : on retombe sur l'initiale.
    return null;
  }
});

/// Photo de profil, ronde, avec repli.
///
/// Point de passage **unique** pour tout affichage d'avatar. Sans cela, rendre
/// le bucket privé aurait imposé de retoucher treize écrans — et le prochain
/// changement de règle en imposerait treize de plus.
class Avatar extends ConsumerWidget {
  const Avatar({
    super.key,
    required this.stored,
    this.radius = 20,
    this.fallback,
    this.backgroundColor,
  });

  /// Valeur brute de `profiles.avatar_url`.
  final String? stored;
  final double radius;

  /// Affiché tant qu'il n'y a pas d'image : initiale, icône…
  final Widget? fallback;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = stored == null
        ? null
        : ref.watch(avatarUrlProvider(stored!)).value;
    return CircleAvatar(
      radius: radius,
      backgroundColor:
          backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
      backgroundImage: url == null ? null : NetworkImage(url),
      child: url == null ? fallback : null,
    );
  }
}

/// Avatar qui **remplit** son parent, pour les cas où la forme est déjà donnée
/// par le conteneur — typiquement l'anneau dégradé des stories, qui découpe
/// lui-même son enfant.
class AvatarFill extends ConsumerWidget {
  const AvatarFill({super.key, required this.stored, required this.fallback});

  final String? stored;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = stored == null
        ? null
        : ref.watch(avatarUrlProvider(stored!)).value;
    if (url == null) return fallback;
    return Image.network(url, fit: BoxFit.cover);
  }
}
