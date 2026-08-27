import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/clock.dart';
import 'package:neovibe/core/models/connection_request.dart';
import 'package:neovibe/features/proximity/proximity_repository.dart';

/// **Ce que ces tests protègent : un bouton qui dit où en est la demande.**
///
/// Le défaut d'origine est du 2026-08-17 — Jay clique plusieurs fois sur
/// « demander » et lit « Demande envoyée » à chaque fois, parce que l'app ne
/// garde aucune trace de ce qu'elle vient de faire. La première réponse fut un
/// **journal local**, qui n'avait de sens que tant qu'une demande voyageait
/// d'appareil à appareil. Il est parti avec le transport BLE le 2026-08-27, et
/// le défaut est revenu à l'identique.
///
/// L'état vient donc du serveur. Et **le dernier test de ce fichier est le plus
/// important** : il ne vérifie pas ce qui s'affiche — il **compte les
/// reconstructions**. C'est le seul moyen de voir le défaut que la première
/// version de ce provider aurait eu, et qui n'aurait levé aucune erreur.
ConnectionRequest _demande({
  required String vers,
  RequestStatus status = RequestStatus.pending,
  Duration expireDans = const Duration(days: 7),
  String id = 'r-1',
}) => ConnectionRequest(
  id: id,
  senderId: 'moi',
  receiverId: vers,
  status: status,
  expiresAt: DateTime.now().add(expireDans),
);

/// Un container dont la source ET l'horloge sont pilotables, sans réseau.
///
/// ⚠️ **L'abonnement est ouvert DÈS la création.** Un provider Riverpod est
/// paresseux : sans ce `listen`, la première émission part avant que quiconque
/// écoute et se perd — et le test compte alors le silence de l'instrument.
({
  ProviderContainer container,
  StreamController<List<ConnectionRequest>> source,
  StreamController<DateTime> horloge,
})
_harnais() {
  final source = StreamController<List<ConnectionRequest>>.broadcast();
  final horloge = StreamController<DateTime>.broadcast();
  final container = ProviderContainer(
    overrides: [
      outgoingRequestsProvider.overrideWith((ref) => source.stream),
      // ⚠️ **Le temps est piloté, jamais attendu.** Un test qui dort pour voir
      // expirer quelque chose mesure la vitesse de la machine autant que le
      // code.
      tickProvider(kExpiryTick).overrideWith((ref) => horloge.stream),
    ],
  );
  container.listen(outgoingRequestsProvider, (_, _) {});
  container.listen(expiryClockProvider, (_, _) {});
  return (container: container, source: source, horloge: horloge);
}

Future<void> _pousse(
  StreamController<List<ConnectionRequest>> source,
  List<ConnectionRequest> valeur,
) async {
  source.add(valeur);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('sans demande, le bouton propose de demander', () async {
    final h = _harnais();
    addTearDown(h.container.dispose);

    await _pousse(h.source, const []);

    expect(h.container.read(etatDemandeProvider('u-b')), EtatDemande.aucune);
  });

  test('une demande en attente se VOIT', () async {
    final h = _harnais();
    addTearDown(h.container.dispose);

    await _pousse(h.source, [_demande(vers: 'u-b')]);

    expect(h.container.read(etatDemandeProvider('u-b')), EtatDemande.envoyee);
    expect(
      h.container.read(etatDemandeProvider('u-c')),
      EtatDemande.aucune,
      reason: 'la demande vers u-b ne dit rien de u-c',
    );
  });

  test('un refus se DIT, il ne se cache pas', () async {
    final h = _harnais();
    addTearDown(h.container.dispose);

    await _pousse(h.source, [
      _demande(vers: 'u-b', status: RequestStatus.declined),
    ]);

    // ⚠️ Une demande refusée qui redeviendrait « aucune » serait indiscernable
    // d'une demande jamais envoyée : l'utilisateur ne saurait jamais qu'on lui
    // a dit non, il verrait juste le bouton revenir.
    expect(h.container.read(etatDemandeProvider('u-b')), EtatDemande.declinee);
  });

  test('après un refus, redemander l\'emporte sur l\'ancien refus', () async {
    final h = _harnais();
    addTearDown(h.container.dispose);

    // Le serveur autorise explicitement une nouvelle demande après un refus :
    // `request_connection_from_proximity` ne cherche qu'une demande `pending`.
    // Les deux lignes coexistent donc.
    await _pousse(h.source, [
      _demande(vers: 'u-b', status: RequestStatus.declined, id: 'r-vieille'),
      _demande(vers: 'u-b', id: 'r-neuve'),
    ]);

    expect(h.container.read(etatDemandeProvider('u-b')), EtatDemande.envoyee);
  });

  test('une demande expirée cesse d\'être « envoyée »', () async {
    final h = _harnais();
    addTearDown(h.container.dispose);

    await _pousse(h.source, [
      _demande(vers: 'u-b', expireDans: const Duration(seconds: -1)),
    ]);

    // ⚠️ **Le temps est une SOURCE, pas une commodité.** Sans l'horloge, une
    // demande périmée resterait affichée jusqu'au prochain événement sans
    // rapport — c'est le défaut corrigé le 2026-08-25 (checkup #52).
    expect(h.container.read(etatDemandeProvider('u-b')), EtatDemande.aucune);
  });

  test(
    'le battement de cœur qui réécrit expires_at NE REDESSINE PAS le bouton',
    () async {
      final h = _harnais();
      addTearDown(h.container.dispose);

      var notifications = 0;
      h.container.listen(etatDemandeProvider('u-b'), (_, _) => notifications++);

      await _pousse(h.source, [_demande(vers: 'u-b')]);
      expect(h.container.read(etatDemandeProvider('u-b')), EtatDemande.envoyee);
      final apresLEnvoi = notifications;

      // ⚠️ **Le cas qui coûte, et qui n'affiche jamais rien de faux.**
      //
      // `ProximityRepository` réécrit `expires_at` toutes les 30 secondes tant
      // que la personne est à portée. Si ce provider rendait le
      // `ConnectionRequest`, chacune de ces réécritures changerait sa valeur —
      // donc reconstruirait la tuile, pour un bouton identique au pixel près.
      //
      // C'est la même règle que `PeerView` : *ce qu'on compare doit être ce que
      // l'œil voit*. Un enum à trois valeurs, et rien de plus.
      for (var i = 1; i <= 5; i++) {
        await _pousse(h.source, [
          _demande(
            vers: 'u-b',
            expireDans: Duration(seconds: 90 + i),
          ),
        ]);
      }

      expect(h.container.read(etatDemandeProvider('u-b')), EtatDemande.envoyee);
      expect(
        notifications,
        apresLEnvoi,
        reason:
            'cinq réécritures de expires_at, zéro reconstruction : le bouton '
            'ne dépend que de ce qu\'il affiche',
      );
    },
  );
}
