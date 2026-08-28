import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/geo/coarse_location.dart';
import 'package:neovibe/features/proximity/net/ping_beacon_service.dart';

/// **Ce que ce test protège : un bandeau ne disparaît pas tout seul.**
///
/// ## 🔴 Le défaut du 2026-08-28
///
/// `copyWith` posait `blocker: blocker` et `lastError: lastError` — sans
/// `?? this.…`. **Tout appel qui ne les passait pas les effaçait.** En
/// particulier `_flushHeard`, qui écrit `confirmed` toutes les 60 secondes :
/// il supprimait le bandeau « Position non autorisée » posé par `_tick`.
/// L'écran cachait donc un blocage encore vrai, sans que rien ne le dise.
///
/// ⚠️ **Un simple `?? this.…` n'aurait pas suffi** : ces deux champs doivent
/// aussi pouvoir être **remis à nul** — un blocage levé, une panne résolue.
/// « Non fourni » et « explicitement nul » sont deux intentions différentes.
void main() {
  const bloque = PingBeaconState(
    blocker: LocationBlocker.denied,
    lastError: 'réseau coupé',
    listening: 3,
  );

  test('un champ non fourni est CONSERVÉ', () {
    final apres = bloque.copyWith(confirmed: 7);

    expect(
      apres.blocker,
      LocationBlocker.denied,
      reason:
          'Le dépôt de jetons ne sait rien de la permission de localisation : '
          "il n'a aucune raison de faire disparaître son bandeau.",
    );
    expect(apres.lastError, 'réseau coupé');
    expect(apres.confirmed, 7);
    expect(apres.listening, 3);
  });

  test('un champ explicitement nul est EFFACÉ', () {
    final apres = bloque.copyWith(blocker: null, lastError: null);

    expect(
      apres.blocker,
      isNull,
      reason:
          'Un tour réussi doit pouvoir lever le bandeau : sans ça, il resterait '
          "affiché après que l'utilisateur a accordé la permission.",
    );
    expect(apres.lastError, isNull);
    expect(apres.listening, 3, reason: 'le reste ne bouge pas');
  });

  test('une panne réseau ne fait pas disparaître un blocage de position', () {
    final apres = bloque.copyWith(lastError: 'timeout');

    expect(apres.blocker, LocationBlocker.denied);
    expect(apres.lastError, 'timeout');
  });
}
