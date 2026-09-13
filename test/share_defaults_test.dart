import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/cards/send/share_defaults.dart';
import 'package:neovibe/features/cards/send/share_plan.dart';
import 'package:neovibe/features/connections/friendship.dart';

/// Ce que ces tests défendent : **les trois niveaux de défaut, dans l'ordre**
/// (plan §2.4) — et une préférence qui se relit telle qu'elle a été écrite.
void main() {
  group('resolveSaveable — son défaut, sinon le mien, sinon non', () {
    test('le défaut par ami gagne sur le général', () {
      expect(
        resolveSaveable(
          friendId: 'lea',
          perFriend: const {'lea': false},
          general: true,
        ),
        isFalse,
      );
      expect(
        resolveSaveable(
          friendId: 'lea',
          perFriend: const {'lea': true},
          general: false,
        ),
        isTrue,
      );
    });

    test('sans défaut par ami, le général', () {
      expect(
        resolveSaveable(friendId: 'max', perFriend: const {}, general: true),
        isTrue,
      );
    });

    test('sans rien, non', () {
      expect(
        resolveSaveable(friendId: 'max', perFriend: const {}, general: false),
        isFalse,
      );
    });
  });

  group('ShareDefaults — la préférence', () {
    test('aller-retour JSON sans perte', () {
      const d = ShareDefaults(
        story: StoryShare(
          tier: FriendshipTier.close,
          shareable: true,
          saveable: false,
        ),
        library: LibraryShare(isPublic: true, shareable: false, saveable: true),
        peopleSaveable: true,
      );
      final relu = ShareDefaults.fromJson(d.toJson());
      expect(relu, d);
      expect(relu.story.tier, FriendshipTier.close);
      expect(relu.library.isPublic, isTrue);
      expect(relu.peopleSaveable, isTrue);
    });

    test(
      'une clé absente vaut son défaut, une valeur inconnue le palier bas',
      () {
        final relu = ShareDefaults.fromJson({
          'story': {'tier': 'vip'},
        });
        expect(relu.story.tier, FriendshipTier.friend);
        expect(relu.story.shareable, isFalse);
        expect(relu.library.saveable, isFalse);
        expect(relu.peopleSaveable, isFalse);
      },
    );
  });
}
