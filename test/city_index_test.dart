import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/location/city_index.dart';

/// Le nom de ville d'une Vibe se trouve sur le téléphone, dans la liste
/// livrée avec l'app. Ce test la lit telle qu'elle part dans l'APK.
void main() {
  late CityIndex index;
  setUpAll(() {
    index = CityIndex.parse(
      File('assets/geo/cities.tsv.gz').readAsBytesSync(),
    );
  });

  test('la liste est complète', () {
    expect(index.length, greaterThan(60000));
  });

  test('des points connus donnent leur ville', () {
    expect(index.nearest(45.7640, 4.8357), 'Lyon'); // place Bellecour
    expect(index.nearest(48.8584, 2.2945), 'Paris'); // tour Eiffel
    expect(index.nearest(43.2965, 5.3698), 'Marseille'); // Vieux-Port
  });

  test('loin de toute ville : rien, plutôt qu\'un nom qui ment', () {
    expect(index.nearest(0.0, -30.0), isNull); // Atlantique
  });
}
