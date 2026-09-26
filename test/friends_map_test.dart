import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/map/friends_map.dart';

/// La position des amis sur la carte (2026-09-26) : de quand date une
/// position, dit en clair, et la lecture de ce que rend le serveur.
void main() {
  final t = DateTime(2026, 9, 26, 18);

  test('« il y a … » : minute, heure, jour', () {
    expect(ilYa(t.subtract(const Duration(seconds: 20)), t), "à l'instant");
    expect(ilYa(t.subtract(const Duration(minutes: 45)), t), 'il y a 45 min');
    expect(ilYa(t.subtract(const Duration(hours: 3)), t), 'il y a 3 h');
    expect(ilYa(t.subtract(const Duration(days: 2)), t), 'il y a 2 j');
  });

  test('un ami se lit tel que le serveur le rend', () {
    final a = FriendOnMap.fromJson({
      'user_id': 'u1',
      'lat': 50.6,
      'lon': 3.07,
      'at': '2026-09-26T16:00:00Z',
      'display_name': 'Inès Martin',
      'avatar_url': null,
    });
    expect(a.userId, 'u1');
    expect(a.displayName, 'Inès Martin');
    expect(a.at.isUtc, isFalse, reason: "affichée à l'heure locale");
    // Égalité de valeur : sans elle, la carte redessinerait à chaque relecture.
    expect(
      a,
      FriendOnMap.fromJson({
        'user_id': 'u1',
        'lat': 50.6,
        'lon': 3.07,
        'at': '2026-09-26T16:00:00Z',
        'display_name': 'Inès Martin',
      }),
    );
  });
}
