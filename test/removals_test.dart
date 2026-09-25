import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/clock.dart';
import 'package:neovibe/core/content/removals.dart';
import 'package:neovibe/core/models/message.dart';
import 'package:neovibe/features/conversations/conversations_repository.dart';

/// **Une suppression se voit tout de suite** (Jay, 2026-09-25).
///
/// Le temps réel ne dit pas au chat qu'une ligne de `messages` a disparu :
/// le message reste dans ce que publie `messagesStreamProvider`. C'est
/// l'annonce de `removals` qui doit le retirer de l'écran — ce test tient
/// exactement ce trou : la source des messages NE BOUGE PAS, seule l'annonce
/// arrive.
void main() {
  final maintenant = DateTime(2026, 9, 25, 12);

  Message msg(String id) => Message(
    id: id,
    conversationId: 'c',
    senderId: 'u',
    kind: MessageKind.card,
    createdAt: maintenant,
    expiresAt: maintenant.add(const Duration(hours: 20)),
  );

  test(
    'un container annoncé disparu quitte le chat, les autres restent',
    () async {
      final annonces = StreamController<Set<String>>();
      addTearDown(annonces.close);
      final container = ProviderContainer(
        overrides: [
          expiryClockProvider.overrideWithValue(maintenant),
          messagesStreamProvider(
            'c',
          ).overrideWith((ref) => Stream.value([msg('a'), msg('b')])),
          removalsProvider('c').overrideWith((ref) => annonces.stream),
        ],
      );
      addTearDown(container.dispose);
      final ids = <List<String>>[];
      container.listen(
        visibleMessagesProvider('c'),
        (_, v) => ids.add([for (final m in v) m.id]),
        fireImmediately: true,
      );

      // La source des messages ET l'annonce doivent être ARRIVÉES avant de
      // juger — sinon une liste vide passe pour un résultat.
      await container.read(messagesStreamProvider('c').future);
      annonces.add(const {});
      await container.read(removalsProvider('c').future);
      await Future<void>.delayed(Duration.zero);
      expect(ids.last, ['a', 'b']);

      annonces.add(const {'b'});
      // Riverpod propage à l'écouteur au tour suivant : deux tours.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        ids.last,
        ['a'],
        reason:
            'la source n\'a pas bougé : seule '
            'l\'annonce peut le retirer',
      );
    },
  );
}
