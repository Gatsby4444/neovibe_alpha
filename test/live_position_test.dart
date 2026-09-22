import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/geo/coarse_location.dart';
import 'package:neovibe/features/proximity/geo/live_position.dart';

/// **Ce que ce test protège : le point affiché sur la carte.**
///
/// Le 2026-09-22, dans le métro, NeoVibe plaçait Jay à deux rues de l'endroit
/// réel avec `± 675 m`, pendant que Google Maps voyait juste. La cause n'était
/// pas la source des données — c'était qu'on prenait **la première réponse** du
/// moteur de position, la plus rapide donc la plus grossière, au lieu de rester
/// abonné et de garder la meilleure.
///
/// `LivePosition.retient` est la règle qui décide, relevé après relevé, lequel
/// garder. ⚠️ **Se tromper ici ne lève aucune erreur.** Trop stricte, la
/// position se fige sur un vieux point et quelqu'un qui marche reste affiché où
/// il était. Trop laxiste, elle saute au gré du bruit. Dans les deux cas
/// l'écran montre un point posé sur une carte, avec le même aplomb.
///
/// C'est pour ça que la règle est une fonction pure, et qu'elle est testée
/// ici plutôt que décrite dans un commentaire.
void main() {
  final maintenant = DateTime.utc(2026, 9, 22, 15, 20);

  CoarseFix fix(double accuracy) => CoarseFix(
    cellLat: 5063,
    cellLon: 306,
    latitude: 50.6365,
    longitude: 3.0635,
    accuracy: accuracy,
    source: FixSource.best,
  );

  bool retient(CoarseFix? garde, Duration? age, CoarseFix venu) =>
      LivePosition.retient(
        garde: garde,
        gardeAt: age == null ? null : maintenant.subtract(age),
        venu: venu,
        now: maintenant,
      );

  test('le tout premier relevé est toujours pris', () {
    expect(retient(null, null, fix(675)), isTrue);
  });

  test('un relevé plus net remplace tout de suite, sans attendre', () {
    // Le cas qui répare le défaut : on reste abonné, la précision tombe de
    // 675 m à 20 m en quelques secondes, et le point doit suivre AUSSITÔT.
    expect(
      retient(fix(675), const Duration(seconds: 2), fix(20)),
      isTrue,
      reason: 'attendre pour afficher un meilleur point n\'aurait aucun sens',
    );
  });

  test('un relevé plus flou ne remplace pas un bon relevé récent', () {
    // 🔴 **C'est exactement le saut que Jay a vu.** Un point de rue à 10 m, puis
    // une estimation d'antenne à 500 m : sans cette ligne, le point saute à
    // deux rues de là alors qu'on n'a pas bougé.
    expect(retient(fix(10), const Duration(seconds: 5), fix(500)), isFalse);
  });

  test('après 30 s, un relevé un peu plus flou reprend la main', () {
    // Sinon un excellent relevé FIGE la position : quelqu'un qui marche reste
    // affiché là où il était, et plus le relevé est bon plus il ment longtemps.
    expect(
      retient(fix(30), const Duration(seconds: 45), fix(50)),
      isTrue,
      reason: 'bouger doit pouvoir déplacer le point',
    );
  });

  test('après 30 s, un relevé DEUX FOIS plus flou est encore accepté', () {
    // La frontière exacte de [LivePosition.degradationMax] : elle sépare
    // « on bouge » de « on a changé de palier de mesure ».
    expect(retient(fix(30), const Duration(seconds: 45), fix(60)), isTrue);
  });

  test('après 30 s, un relevé bien plus flou est REFUSÉ', () {
    // Entrer dans un bâtiment : le GPS lâche, l'antenne prend le relais et
    // l'incertitude est multipliée par cinquante. Mieux vaut garder le dernier
    // bon point quelques minutes que sauter sur un pâté de maisons.
    expect(retient(fix(10), const Duration(seconds: 45), fix(500)), isFalse);
  });

  test('un relevé périmé cède la place à n\'importe quoi', () {
    // Au-delà de la durée de vie de la balise, un bon point d'il y a dix
    // minutes ne décrit plus où l'on est : un mauvais point d'ici vaut mieux.
    expect(
      retient(
        fix(10),
        CoarseLocation.maxLastKnownAge + const Duration(seconds: 1),
        fix(2000),
      ),
      isTrue,
    );
  });

  test('la borne de renouvellement est celle du natif, pas un chiffre rond', () {
    // La même règle est écrite deux fois, en Dart et en Kotlin
    // (`LocationBeat.kt`). Deux valeurs différentes, et le point AFFICHÉ et le
    // point PUBLIÉ divergeraient sans que rien ne le signale.
    expect(
      LivePosition.renouvelle,
      const Duration(seconds: 30),
      reason: 'si ceci change, `LocationBeat.kt` doit changer avec',
    );
  });

  group('LivePositionState', () {
    test(
      'deux états identiques sont égaux — sinon tout écran se redessine',
      () {
        // Le flux publie plusieurs relevés par seconde. Sans égalité de valeur,
        // la carte se reconstruirait à chaque relevé, pour afficher la même
        // chose. Ce défaut ne lève rien : il se compte.
        final a = LivePositionState(fix: fix(20), at: maintenant, received: 3);
        final b = LivePositionState(fix: fix(20), at: maintenant, received: 3);
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      },
    );

    test('un relevé plus net produit bien un état DIFFÉRENT', () {
      // Le contre-test : si l'égalité était trop large, le point se resserrerait
      // sans que la carte ne le montre jamais.
      expect(
        LivePositionState(fix: fix(675), at: maintenant, received: 1),
        isNot(
          equals(LivePositionState(fix: fix(20), at: maintenant, received: 1)),
        ),
      );
    });

    test('sans relevé, rien n\'est frais', () {
      expect(const LivePositionState().isFresh(maintenant), isFalse);
      expect(const LivePositionState().ageAt(maintenant), isNull);
    });

    test('la fraîcheur suit la borne de la balise serveur', () {
      final vieux = LivePositionState(
        fix: fix(20),
        at: maintenant.subtract(
          CoarseLocation.maxLastKnownAge + const Duration(seconds: 1),
        ),
        received: 9,
      );
      expect(vieux.isFresh(maintenant), isFalse);
    });
  });

  group('la finesse accordée par Android', () {
    // 🔴 Diagnostic de Jay du 2026-09-22 (app 0.9.247+5121), lu en base :
    //   finesse       : approximate
    //   carreau       : carreau(5061, 312) ± 2000 m · best
    //   repli haut    : aucun échec
    // Rien n'était en panne : Android brouillait volontairement à ~2 km, et le
    // point tombait à trois kilomètres de l'endroit réel. Ce que l'écran
    // devait dire, il ne le disait que sur l'écran du ping — pas sur la carte.

    test('approximative ⇒ la position est déclarée BROUILLÉE', () {
      const etat = LivePositionState(precision: LocationPrecision.approximate);
      expect(etat.brouillee, isTrue);
    });

    test("précise ⇒ elle ne l'est pas", () {
      const etat = LivePositionState(precision: LocationPrecision.precise);
      expect(etat.brouillee, isFalse);
    });

    test("non encore lue ⇒ on n'accuse PAS Android", () {
      // Un doute ne doit pas se transformer en reproche à l'utilisateur :
      // afficher « tu as bridé la position » avant d'avoir lu la permission
      // enverrait chercher le problème là où il n'est peut-être pas.
      expect(const LivePositionState().brouillee, isFalse);
    });

    test("la finesse fait partie de l'égalité — sinon le bandeau ne disparaît "
        "jamais", () {
      // Si `precision` était hors du `==`, corriger la permission ne
      // changerait pas l'état, l'écran ne se reconstruirait pas, et
      // l'avertissement resterait affiché après avoir été réparé.
      expect(
        const LivePositionState(precision: LocationPrecision.approximate),
        isNot(
          equals(const LivePositionState(precision: LocationPrecision.precise)),
        ),
      );
    });
  });

  group('la rafale et le continu — decision de Jay du 2026-09-22 au soir', () {
    // Jay : « on peut faire en continu app ouverte sur maps comme Google Maps
    // si deux amis veulent se retrouver, et lorsque l'app est eteinte ou en
    // arriere-plan, on demande la position une fois par minute mais on ouvre
    // pendant 10 sec le temps de bien calibrer la position et ensuite on
    // referme, toutes les 60 secondes. »

    test("la fenetre de rafale est celle du natif, pas un chiffre rond", () {
      // La meme regle est ecrite deux fois, en Dart et en Kotlin
      // (LocationBeat.FENETRE_MS). Deux valeurs differentes, et le point
      // mesure app ouverte et le point mesure app fermee n'auraient pas la
      // meme qualite, sans que rien ne le signale.
      expect(
        LivePosition.fenetreRafale,
        const Duration(seconds: 10),
        reason: "si ceci change, LocationBeat.FENETRE_MS doit changer avec",
      );
    });

    test("dix secondes, pas une : une fenetre trop courte rend la premiere "
        "reponse", () {
      // Le coeur du defaut du 2026-09-22 : le moteur repond d'abord de
      // memoire, puis affine. Une fenetre d'une seconde economiserait de la
      // batterie en redonnant exactement le point grossier qu'on voulait
      // fuir — l'economie annulerait la correction.
      expect(
        LivePosition.fenetreRafale.inSeconds,
        greaterThanOrEqualTo(5),
        reason: "sous 5 s, le moteur n'a pas le temps de se resserrer",
      );
    });
  });
}
