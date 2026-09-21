import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/gallery/moment_store.dart';

/// **La galerie sur le téléphone** (2026-09-21) : ce qui est écrit se relit
/// tel quel, et un moment figé (`kept`) ne se réécrit plus.
void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('gallery');
  });
  tearDown(() => root.delete(recursive: true));

  Moment moment({bool kept = false, DateTime? closedAt}) => Moment(
    id: 'ev-1',
    title: 'Soirée au Temple',
    autoCreated: false,
    kind: 'open',
    startedAt: DateTime(2026, 9, 21, 21),
    closedAt: closedAt,
    lat: 50.63,
    lon: 3.06,
    venueName: 'Le Temple',
    friends: const ['a', 'b'],
    presentCount: 27,
    vibeCount: 43,
    metCount: 4,
    newFriendCount: 2,
    keptVibeIds: const ['v1', 'v2'],
    kept: kept,
  );

  test('un moment fait le va-et-vient JSON sans rien perdre', () {
    final m = moment(kept: true, closedAt: DateTime(2026, 9, 22, 2));
    final back = Moment.fromJson(m.toJson());
    expect(back, m);
    expect(back.venueName, 'Le Temple');
    expect(back.friends, ['a', 'b']);
    expect(back.keptVibeIds, ['v1', 'v2']);
    expect(back.closedAt, DateTime(2026, 9, 22, 2));
    expect(back.isOpen, isFalse);
  });

  test('écrit, relu depuis le disque, le plus récent d\'abord', () async {
    var changes = 0;
    final store = MomentStore(root: root, onChanged: () => changes++);
    await store.upsert(moment());
    await store.upsert(
      Moment(
        id: 'ev-2',
        title: 'Moment du 22/09',
        autoCreated: true,
        kind: 'private',
        startedAt: DateTime(2026, 9, 22, 19),
      ),
    );
    expect(changes, 2);
    // Un autre magasin sur le même dossier : c'est le disque qui compte.
    final again = MomentStore(root: root);
    final list = await again.all();
    expect(list.map((m) => m.id), ['ev-2', 'ev-1']);
    expect(list.last.presentCount, 27);
    expect(File('${root.path}/moments.json.tmp').existsSync(), isFalse);
  });

  test('réécrire le même moment n\'écrit pas', () async {
    var changes = 0;
    final store = MomentStore(root: root, onChanged: () => changes++);
    await store.upsert(moment());
    await store.upsert(moment());
    expect(changes, 1, reason: 'égal champ à champ : rien à faire');
    await store.upsert(moment().copyWith(vibeCount: 44));
    expect(changes, 2);
  });

  test('retirer un moment', () async {
    final store = MomentStore(root: root);
    await store.upsert(moment());
    await store.remove('ev-1');
    expect(await store.all(), isEmpty);
    expect(await store.get('ev-1'), isNull);
  });
}
