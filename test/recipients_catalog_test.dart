import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/profile.dart';
import 'package:neovibe/features/cards/send/recipients.dart';
import 'package:neovibe/features/connections/friendship.dart';

/// Ce que ces tests défendent : **l'ordre de la liste « Groupes et amis »,
/// tel que Jay l'a décrit** (2026-09-14). L'ordre EST la fluidité : si les
/// bons ne sont pas en haut, on cherche — et « on cherche » est exactement ce
/// que la refonte devait supprimer.
void main() {
  // Sans `tagName` : `chatName` le préfère au nom, et c'est le nom qu'on
  // veut lire dans les attentes.
  Profile profil(String id, String nom) => Profile(
    id: id,
    displayName: nom,
    libraryVisibility: LibraryVisibility.connections,
  );

  FriendRecipient ami(
    String nom, {
    FriendshipTier tier = FriendshipTier.friend,
    DateTime? activite,
    String? conv,
  }) => FriendRecipient(
    profile: profil('u-$nom', nom),
    tier: tier,
    serie: 0,
    conversationId: conv ?? (activite == null ? null : 'dm-$nom'),
    lastActivityAt: activite,
  );

  GroupRecipient groupe(
    String nom, {
    DateTime? activite,
    DateTime? moi,
    bool event = false,
  }) => GroupRecipient(
    conversationId: 'g-$nom',
    label: nom,
    memberIds: const ['a', 'b'],
    isEvent: event,
    lastActivityAt: activite,
    myLastAt: moi,
  );

  final t0 = DateTime(2026, 9, 14, 10);
  DateTime il(int h) => t0.subtract(Duration(hours: h));

  test('les plus proches : le palier d\'abord, l\'interaction ensuite', () {
    final c = RecipientCatalog.build(
      friends: [
        ami('Zoé', tier: FriendshipTier.friend, activite: il(1)),
        ami('Léa', tier: FriendshipTier.inner, activite: il(48)),
        ami('Max', tier: FriendshipTier.close, activite: il(2)),
        ami('Ana', tier: FriendshipTier.inner, activite: il(3)),
        ami('Bob', tier: FriendshipTier.close),
      ],
      groups: const [],
      crossed: const [],
    );
    expect(c.closest.map((f) => f.profile.displayName).toList(), [
      'Ana', // inséparable, vue il y a 3 h
      'Léa', // inséparable, vue il y a 2 jours
      'Max', // proche, vu il y a 2 h
      'Bob', // proche, jamais
      'Zoé', // ami, vu il y a 1 h — le palier passe avant la date
    ]);
  });

  test('au plus dix dans le tableau', () {
    final c = RecipientCatalog.build(
      friends: [for (var i = 0; i < 14; i++) ami('A$i')],
      groups: const [],
      crossed: const [],
    );
    expect(c.closest.length, RecipientCatalog.closestCount);
    expect(c.everyone.length, 14, reason: 'tout le monde reste complet');
  });

  test('les groupes : MA participation avant l\'activité des autres', () {
    final c = RecipientCatalog.build(
      friends: const [],
      groups: [
        groupe('Bruyant', activite: il(1)), // les autres parlent, pas moi
        groupe('Calme', activite: il(30), moi: il(30)),
        groupe('Hier', activite: il(5), moi: il(20)),
      ],
      crossed: const [],
    );
    expect(c.groups.map((g) => g.label).toList(), [
      'Hier', // j'y ai parlé il y a 20 h
      'Calme', // j'y ai parlé il y a 30 h
      'Bruyant', // jamais parlé : après, même si ça bouge
    ]);
  });

  test('tout le monde : amis et groupes mêlés, par interaction récente', () {
    final c = RecipientCatalog.build(
      friends: [
        ami('Léa', activite: il(2)),
        ami('Sam'),
      ],
      groups: [
        groupe('Foot', activite: il(1)),
        groupe('Vide'),
      ],
      crossed: const [],
    );
    expect(c.everyone.map((r) => r.searchText.split(' ').first).toList(), [
      'Foot',
      'Léa',
      'Sam', // sans date : par nom
      'Vide',
    ]);
  });

  test(
    'l\'événement en cours est retrouvé, et reste aussi dans les groupes',
    () {
      final c = RecipientCatalog.build(
        friends: const [],
        groups: [groupe('Soirée', event: true), groupe('Foot')],
        crossed: const [],
        currentEventConversationId: 'g-Soirée',
      );
      expect(c.currentEvent?.label, 'Soirée');
      expect(c.groups.any((g) => g.label == 'Soirée'), isTrue);
    },
  );

  test('la recherche efface le tableau et filtre le reste', () {
    final c = RecipientCatalog.build(
      friends: [ami('Léa'), ami('Léo'), ami('Max')],
      groups: [groupe('Les Léopards')],
      crossed: const [],
    );
    final f = c.filter('lé');
    expect(f.closest, isEmpty);
    expect(f.groups, isEmpty);
    expect(f.everyone.map((r) => r.searchText.split(' ').first).toList(), [
      'Les',
      'Léa',
      'Léo',
    ]);
    expect(c.filter(''), same(c), reason: 'vide = tout, sans copie');
  });

  test('égalité de valeur : le même catalogue ne réveille personne', () {
    RecipientCatalog fabrique() => RecipientCatalog.build(
      friends: [ami('Léa', tier: FriendshipTier.close, activite: il(1))],
      groups: [groupe('Foot', activite: il(2), moi: il(3))],
      crossed: const [],
    );
    expect(fabrique(), fabrique());
    expect(fabrique().hashCode, fabrique().hashCode);
  });
}
