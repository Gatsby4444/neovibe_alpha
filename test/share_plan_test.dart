import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/features/cards/send/share_plan.dart';
import 'package:neovibe/features/connections/friendship.dart';

/// Ce que ces tests défendent : **un geste, plusieurs objets — et pas un
/// réglage qui traverse une frontière qu'il n'a pas le droit de franchir.**
///
/// Aucune de ces règles n'était couverte avant le 2026-08-30 : elles vivaient
/// éparpillées dans quatre écrans de paramétrage, et c'est précisément ce qui
/// avait laissé un `shareable` de story repartir avec une publication.
void main() {
  ConversationShare conv(String id, List<String> membres) =>
      ConversationShare(conversationId: id, memberIds: membres, label: id);

  group('le coût réel : combien de fois les octets montent', () {
    test('une seule destination : une montée', () {
      expect(const SharePlan(story: StoryShare()).televersements, 1);
    });

    test('🔴 dix amis dans deux conversations : TOUJOURS une montée', () {
      // C'est le point qui rassure : le nombre de destinataires ne multiplie
      // rien. Une Card, dix livraisons.
      final plan = SharePlan(
        conversations: [
          conv('a', ['1', '2', '3', '4', '5']),
          conv('b', ['6', '7', '8', '9', '10']),
        ],
      );
      expect(plan.destinataires, 10);
      expect(plan.televersements, 1);
    });

    test('story + bibliothèque + amis : trois montées', () {
      final plan = SharePlan(
        story: const StoryShare(),
        library: const LibraryShare(),
        conversations: [
          conv('a', ['1']),
        ],
      );
      expect(plan.televersements, 3);
    });

    test('la bibliothèque de conversation est un contexte de PLUS', () {
      // Le cinquième contexte de diffusion : son propre cycle de vie, son
      // propre reveal. Le confondre avec la livraison ferait un fichier sous
      // deux régimes — le défaut du 2026-08-11.
      final plan = SharePlan(
        conversations: [
          conv('a', ['1']).copyWith(aussiDansLaBibliotheque: true),
        ],
      );
      expect(plan.televersements, 2);
    });

    test('🔴 deux réglages DIFFÉRENTS coûtent deux montées', () {
      // C'est le prix honnête de la case « Sauvegardable » posée par ligne
      // dans la maquette de Jay : une Card ne porte qu'un `saveable`, donc
      // deux personnes qui n'ont pas le même en demandent deux.
      final plan = SharePlan(
        conversations: [
          conv('a', ['1']),
          conv('b', ['2']).copyWith(saveable: true),
        ],
      );
      expect(plan.lotsDeCercle, hasLength(2));
      expect(plan.televersements, 2);
    });

    test('les croisés voyagent GRATUITEMENT dans le lot non sauvegardable', () {
      // Un croisé n'a droit à aucune sauvegarde : il ne peut donc jamais
      // ouvrir un lot à lui seul quand un ami non sauvegardable existe déjà.
      final avec = SharePlan(
        conversations: [
          conv('a', ['1']),
        ],
        crossed: const [CrossedShare(userId: 'x', label: 'Sofia')],
      );
      final sans = SharePlan(
        conversations: [
          conv('a', ['1']),
        ],
      );
      expect(avec.televersements, sans.televersements);
      expect(avec.destinataires, sans.destinataires + 1);
    });

    test('un croisé SEUL coûte bien une montée', () {
      const plan = SharePlan(
        crossed: [CrossedShare(userId: 'x', label: 'Sofia')],
      );
      expect(plan.televersements, 1);
    });

    test('🔴 chaque bibliothèque de conversation coûte SA montée', () {
      // `LibraryVibesRepository.addVibe` dépose ses propres octets à chaque
      // appel : deux groupes cochés, c'est deux dépôts. Le total n'est donc
      // PAS borné à quatre, contrairement à ce que j'avais annoncé à Jay.
      final plan = SharePlan(
        story: const StoryShare(),
        library: const LibraryShare(),
        conversations: [
          conv('a', ['1']).copyWith(aussiDansLaBibliotheque: true),
          conv('b', ['2']).copyWith(aussiDansLaBibliotheque: true),
          conv('c', ['3']),
        ],
        crossed: const [CrossedShare(userId: 'x', label: 'Sofia')],
      );
      // story + bibliothèque + 2 bibliothèques de conversation + 1 lot
      expect(plan.televersements, 5);
    });
  });

  group('ce qui empêche de partir', () {
    test('rien de coché : on le dit', () {
      expect(
        const SharePlan().problemes(CardType.standard, importe: false),
        isNotEmpty,
      );
    });

    test('un plan ordinaire ne pose aucun problème', () {
      final plan = SharePlan(
        story: const StoryShare(),
        conversations: [
          conv('a', ['1', '2']),
        ],
      );
      expect(plan.problemes(CardType.standard, importe: false), isEmpty);
    });

    group('la Vibe 1/1 — une règle de produit, pas une limite technique', () {
      test('elle ne se publie pas', () {
        final plan = SharePlan(
          story: const StoryShare(),
          conversations: [
            conv('a', ['1']),
          ],
        );
        expect(
          plan.problemes(CardType.oneOfOne, importe: false),
          contains(contains('ne se publie pas')),
        );
      });

      test('elle n\'a qu\'un destinataire', () {
        final plan = SharePlan(
          conversations: [
            conv('a', ['1', '2']),
          ],
        );
        expect(
          plan.problemes(CardType.oneOfOne, importe: false),
          contains(contains('un seul destinataire')),
        );
      });

      test('à un seul ami, elle passe', () {
        final plan = SharePlan(
          conversations: [
            conv('a', ['1']),
          ],
        );
        expect(plan.problemes(CardType.oneOfOne, importe: false), isEmpty);
      });

      test('elle ne part JAMAIS vers un croisé', () {
        // Un 1/1 est un cadeau : il suppose une relation, pas un inconnu.
        const plan = SharePlan(
          crossed: [CrossedShare(userId: 'x', label: 'Sofia')],
        );
        expect(plan.problemes(CardType.oneOfOne, importe: false), isNotEmpty);
      });
    });

    group('la bibliothèque de conversation garde ses deux refus', () {
      // Règles arrêtées par Jay le 2026-08-10 : de vraies photos ou vidéos,
      // et pas de BeReal.
      test('pas d\'import galerie', () {
        final plan = SharePlan(
          conversations: [
            conv('a', ['1']).copyWith(aussiDansLaBibliotheque: true),
          ],
        );
        expect(
          plan.problemes(CardType.standard, importe: true),
          contains(contains('galerie')),
        );
      });

      test('pas de BeReal', () {
        final plan = SharePlan(
          conversations: [
            conv('a', ['1']).copyWith(aussiDansLaBibliotheque: true),
          ],
        );
        expect(
          plan.problemes(CardType.bereal, importe: false),
          contains(contains('BeReal')),
        );
      });

      test('mais un import SANS bibliothèque de conversation passe', () {
        // 🔴 Le contre-test : le refus doit être attaché à la case cochée, pas
        // à la conversation. Sinon on interdirait d'envoyer une photo de la
        // galerie à un ami, ce que personne n'a jamais décidé.
        final plan = SharePlan(
          conversations: [
            conv('a', ['1']),
          ],
        );
        expect(plan.problemes(CardType.standard, importe: true), isEmpty);
      });
    });
  });

  group('les réglages restent chez leur destination', () {
    test('le palier appartient à la story, et à elle seule', () {
      const plan = SharePlan(story: StoryShare(tier: FriendshipTier.inner));
      expect(plan.story!.tier, FriendshipTier.inner);
      // Il n'existe aucun chemin pour lire un palier ailleurs : la seule
      // manière de le faire fuiter serait de le poser sur le plan lui-même,
      // et le type l'interdit.
      expect(plan.library, isNull);
    });

    test('modifier une conversation ne touche pas les autres', () {
      final plan = SharePlan(
        conversations: [
          conv('a', ['1']),
          conv('b', ['2']),
        ],
      );
      final change = plan.copyWith(
        conversations: [
          plan.conversations.first.copyWith(saveable: true),
          plan.conversations.last,
        ],
      );
      expect(change.conversations.first.saveable, isTrue);
      expect(change.conversations.last.saveable, isFalse);
    });

    test('décocher la story l\'efface vraiment', () {
      // ⚠️ `copyWith(story: null)` ne peut pas effacer — c'est le piège
      // classique de Dart. D'où le drapeau explicite.
      const plan = SharePlan(story: StoryShare());
      expect(plan.copyWith(effacerStory: true).story, isNull);
      expect(plan.copyWith().story, isNotNull);
    });
  });
}
