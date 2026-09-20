import '../../connections/friendship.dart';
import 'share_plan.dart';

/// **Un plan de partage, écrit et relu tel quel** (Brouillons, 2026-09-20) :
/// la story, la bibliothèque, chaque conversation cochée avec ses réglages,
/// les croisés, et les règles de visionnage. Ce que l'utilisateur avait
/// choisi sur « À qui ? » revient tel quel.
abstract final class SharePlanCodec {
  static Map<String, dynamic> toJson(SharePlan p) => {
    'story': p.story == null
        ? null
        : {
            'tier': p.story!.tier.name,
            'shareable': p.story!.shareable,
            'saveable': p.story!.saveable,
          },
    'library': p.library == null
        ? null
        : {
            'isPublic': p.library!.isPublic,
            'shareable': p.library!.shareable,
            'saveable': p.library!.saveable,
            'caption': p.library!.caption,
            'anchored': p.library!.anchored,
          },
    'conversations': [
      for (final c in p.conversations)
        {
          'conversationId': c.conversationId,
          'peerId': c.peerId,
          'memberIds': c.memberIds,
          'label': c.label,
          'saveable': c.saveable,
          'dansLeChat': c.dansLeChat,
          'aussiDansLaBibliotheque': c.aussiDansLaBibliotheque,
        },
    ],
    'crossed': [
      for (final c in p.crossed) {'userId': c.userId, 'label': c.label},
    ],
    'regles': {
      'maxViews': p.regles.maxViews,
      'viewDurationSeconds': p.regles.viewDurationSeconds,
      'scrubbable': p.regles.scrubbable,
    },
  };

  static SharePlan fromJson(Map<String, dynamic> j) {
    final story = (j['story'] as Map?)?.cast<String, dynamic>();
    final library = (j['library'] as Map?)?.cast<String, dynamic>();
    final regles = (j['regles'] as Map?)?.cast<String, dynamic>() ?? const {};
    return SharePlan(
      story: story == null
          ? null
          : StoryShare(
              tier: FriendshipTier.values.byName(story['tier'] as String),
              shareable: story['shareable'] as bool? ?? false,
              saveable: story['saveable'] as bool? ?? false,
            ),
      library: library == null
          ? null
          : LibraryShare(
              isPublic: library['isPublic'] as bool? ?? false,
              shareable: library['shareable'] as bool? ?? false,
              saveable: library['saveable'] as bool? ?? false,
              caption: library['caption'] as String?,
              anchored: library['anchored'] as bool? ?? false,
            ),
      conversations: [
        for (final raw in j['conversations'] as List? ?? const [])
          _conversation((raw as Map).cast<String, dynamic>()),
      ],
      crossed: [
        for (final raw in j['crossed'] as List? ?? const [])
          CrossedShare(
            userId: (raw as Map)['userId'] as String,
            label: raw['label'] as String,
          ),
      ],
      regles: ViewingRules(
        maxViews: (regles['maxViews'] as num?)?.toInt(),
        viewDurationSeconds: (regles['viewDurationSeconds'] as num?)?.toInt(),
        scrubbable: regles['scrubbable'] as bool? ?? false,
      ),
    );
  }

  static ConversationShare _conversation(Map<String, dynamic> c) =>
      ConversationShare(
        conversationId: c['conversationId'] as String?,
        peerId: c['peerId'] as String?,
        memberIds: (c['memberIds'] as List).cast<String>(),
        label: c['label'] as String,
        saveable: c['saveable'] as bool? ?? false,
        dansLeChat: c['dansLeChat'] as bool? ?? true,
        aussiDansLaBibliotheque: c['aussiDansLaBibliotheque'] as bool? ?? false,
      );
}
