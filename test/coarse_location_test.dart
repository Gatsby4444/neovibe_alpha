import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/geo/coarse_location.dart';

/// **Ce que ce test protège : qu'on ne s'annonce pas là où l'on n'est plus.**
///
/// Le repli sur le dernier point connu prenait `getLastKnownPosition()` **sans
/// regarder sa date**. Un point vieux de plusieurs heures partait donc comme
/// balise courante.
///
/// ⚠️ **Ce défaut n'a aucune apparence de défaut** : une position périmée a
/// exactement la forme d'une position juste. Le serveur l'accepte, l'écran
/// affiche quelque chose, et ce sont les gens réellement à côté qui manquent —
/// ou de parfaits inconnus qui apparaissent. Une borne de temps est la seule
/// chose qui distingue les deux, donc la seule chose à tester.
void main() {
  final maintenant = DateTime.utc(2026, 8, 28, 12, 0);

  test('un point de quelques secondes est publiable', () {
    expect(
      CoarseLocation.isFreshEnough(
        maintenant.subtract(const Duration(seconds: 30)),
        maintenant,
      ),
      isTrue,
    );
  });

  test('la borne est celle de la balise serveur, pas un chiffre rond', () {
    // `private.ping_beacon_ttl()` vaut 5 minutes : publier comme position
    // COURANTE un point plus vieux que la durée de vie de ce qu'on écrit serait
    // incohérent par construction.
    expect(
      CoarseLocation.maxLastKnownAge,
      const Duration(minutes: 5),
      reason:
          'si cette valeur change, `kPingBeaconTtl` et '
          '`private.ping_beacon_ttl()` doivent changer avec elle',
    );
  });

  test('un point d\'une heure est refusé', () {
    expect(
      CoarseLocation.isFreshEnough(
        maintenant.subtract(const Duration(hours: 1)),
        maintenant,
      ),
      isFalse,
      reason: 'à pied, une heure fait cinq kilomètres — plusieurs carreaux',
    );
  });

  test('la borne exacte est acceptée, un rien au-delà ne l\'est plus', () {
    expect(
      CoarseLocation.isFreshEnough(
        maintenant.subtract(CoarseLocation.maxLastKnownAge),
        maintenant,
      ),
      isTrue,
    );
    expect(
      CoarseLocation.isFreshEnough(
        maintenant.subtract(
          CoarseLocation.maxLastKnownAge + const Duration(seconds: 1),
        ),
        maintenant,
      ),
      isFalse,
    );
  });

  test('un point daté dans le futur reste utilisable', () {
    // Horloge décalée : ce point n'est pas périmé, il est mal daté. Le refuser
    // rendrait muet un téléphone dont la seule faute est de mal lire l'heure.
    expect(
      CoarseLocation.isFreshEnough(
        maintenant.add(const Duration(minutes: 30)),
        maintenant,
      ),
      isTrue,
    );
  });
}
