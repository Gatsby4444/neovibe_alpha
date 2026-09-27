import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/library_item.dart';
import '../models/story.dart';
import '../api/nv_api.dart';

/// Ce que désigne un repartage : une story ou une publication, jamais une
/// copie.
///
/// [story] et [item] sont tous deux nuls quand la source a disparu — expirée,
/// retirée par son auteur, ou révoquée. Ce n'est pas une erreur à masquer :
/// c'est l'état qu'il faut **dire** à l'utilisateur, parce qu'un raccourci
/// vers rien doit s'annoncer comme tel.
typedef SharedContent = ({Story? story, LibraryItem? item});

/// Résout un Content ID en l'objet qu'il désigne.
///
/// Deux requêtes au plus : le contexte dans `contents`, puis la table de
/// format correspondante. La RLS fait le tri — un contenu hors de mon audience
/// revient simplement vide, sans révéler qu'il existe.
final sharedContentProvider = FutureProvider.family<SharedContent, String>((
  ref,
  contentId,
) async {
  final client = ref.watch(nvApiProvider);

  final content =
      await client.op('content_flags', {'id': contentId})
          as Map<String, dynamic>?;
  if (content == null) return (story: null, item: null);

  final shareable = content['shareable'] as bool? ?? false;
  final saveable = content['saveable'] as bool? ?? false;

  switch (content['context'] as String) {
    case 'story':
      final row =
          await client.op('story_get', {'id': contentId})
              as Map<String, dynamic>?;
      if (row == null) return (story: null, item: null);
      // `shareable` vit sur `contents` : on le réinjecte pour que le modèle
      // soit complet sans imposer une seconde jointure.
      return (
        story: Story.fromJson({
          ...row,
          'contents': {'shareable': shareable, 'saveable': saveable},
        }),
        item: null,
      );

    case 'publication':
      final row =
          await client.op('library_item_get', {'id': contentId})
              as Map<String, dynamic>?;
      if (row == null) return (story: null, item: null);
      return (
        story: null,
        item: LibraryItem.fromJson({
          ...row,
          'contents': {'shareable': shareable, 'saveable': saveable},
        }),
      );

    default:
      // Un partage direct ou une bibliothèque de conversation ne se repartage
      // pas : le serveur le refuse déjà, ce cas ne devrait jamais arriver.
      return (story: null, item: null);
  }
});
