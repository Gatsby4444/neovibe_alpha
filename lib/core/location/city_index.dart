import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **Le nom de la ville d'un point — trouvé SUR le téléphone** (2026-09-25).
///
/// La galerie affiche « où » pour chaque Vibe (Jay : *« pour l'instant la
/// ville, le quartier plus tard avec une vraie carte »*). Demander ce nom à
/// un service de géocodage (Google, via le `Geocoder` d'Android) lui
/// enverrait la position de chaque Vibe — une fuite hors de NeoVibe, pour un
/// nom de ville. La liste des villes est donc DANS l'app :
/// `assets/geo/cities.tsv.gz`, les villes de plus de 5 000 habitants de
/// **GeoNames** (licence CC BY 4.0 — à citer dans « À propos »), ~64 000
/// lignes `nom \t lat \t lon \t pays`, 800 Ko.
///
/// La ville la plus proche, à moins de [maxKm] ; au-delà, rien — un nom de
/// ville à 40 km mentirait plus qu'il n'aiderait.
class CityIndex {
  CityIndex._(this._names, this._lat, this._lon);

  final List<String> _names;
  final Float32List _lat;
  final Float32List _lon;

  static const maxKm = 20.0;

  int get length => _names.length;

  /// Lit la liste compressée. Fait sur un autre fil par [cityIndexProvider] :
  /// ~2 Mo à découper, pas sur le fil qui dessine l'écran.
  static CityIndex parse(Uint8List gz) {
    final text = utf8.decode(gzip.decode(gz));
    final names = <String>[];
    final lats = <double>[];
    final lons = <double>[];
    for (final line in text.split('\n')) {
      final c = line.split('\t');
      if (c.length < 3) continue;
      final la = double.tryParse(c[1]);
      final lo = double.tryParse(c[2]);
      if (la == null || lo == null) continue;
      names.add(c[0]);
      lats.add(la);
      lons.add(lo);
    }
    return CityIndex._(
      names,
      Float32List.fromList(lats),
      Float32List.fromList(lons),
    );
  }

  /// La ville la plus proche de ([lat], [lon]), ou nul au-delà de [maxKm].
  String? nearest(double lat, double lon) {
    // Distance « équirectangulaire » : exacte à mieux que 1 % à ces
    // échelles, et sans trigonométrie dans la boucle.
    final k = math.cos(lat * math.pi / 180);
    var best = -1;
    var bestD = double.infinity;
    for (var i = 0; i < _names.length; i++) {
      final dy = _lat[i] - lat;
      var dx = _lon[i] - lon;
      if (dx > 180) dx -= 360;
      if (dx < -180) dx += 360;
      final d = dy * dy + (dx * k) * (dx * k);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0) return null;
    final km = math.sqrt(bestD) * 111.32;
    return km <= maxKm ? _names[best] : null;
  }
}

/// La citation que la licence CC BY 4.0 exige — enregistrée au démarrage
/// (`main.dart`), affichée dans Réglages › Licences.
void registerGeoNamesLicense() {
  LicenseRegistry.addLicense(
    () => Stream.value(
      const LicenseEntryWithLineBreaks(
        ['GeoNames'],
        'Noms et positions des villes : GeoNames (www.geonames.org), sous '
        'licence Creative Commons Attribution 4.0 '
        '(https://creativecommons.org/licenses/by/4.0/). Liste réduite aux '
        'villes de plus de 5 000 habitants ; arrondissements renommés du nom '
        'de leur ville (tool/build_cities.py).',
      ),
    ),
  );
}

/// Chargée une fois, à la première question.
final cityIndexProvider = FutureProvider<CityIndex>((ref) async {
  final data = await rootBundle.load('assets/geo/cities.tsv.gz');
  return compute(CityIndex.parse, data.buffer.asUint8List());
});
