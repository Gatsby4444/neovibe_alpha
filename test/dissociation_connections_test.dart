import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/clock.dart';
import 'package:neovibe/core/models/connection.dart';
import 'package:neovibe/core/models/connection_request.dart';
import 'package:neovibe/core/models/profile.dart';
import 'package:neovibe/core/supabase_providers.dart';
import 'package:neovibe/features/connections/connections_repository.dart';
import 'package:neovibe/features/proximity/proximity_repository.dart';

/// **Ce que ces tests MESURENT : le coût d'un défaut qui n'affiche rien de faux.**
///
/// Checkup demandé par Jay (`RAPPELS.md` #52), à l'aune de la règle de
/// dissociation acquisition / usage. Ces tests ne vérifient pas que l'écran
/// affiche la bonne chose — il l'affiche. Ils comptent les **notifications**,
/// c'est-à-dire les reconstructions d'interface. C'est la seule façon de voir ce
/// défaut : il ne lève aucune erreur, et les tests fonctionnels passent tous.
///
/// ## ⚠️ Réécrit le 2026-08-28, et pourquoi ça compte
///
/// Ce fichier prenait le **lien partiel** pour sujet : c'était le seul objet des
/// connexions qui expirait, donc le seul qui permettait de prouver que
/// l'horloge est une source à part entière. Le lien partiel a été supprimé
/// (décision de Jay : une seule porte vers l'amitié).
///
/// **La règle, elle, n'a pas bougé** — seul son sujet a disparu. Supprimer ces
/// tests avec lui aurait retiré la seule preuve d'une règle impérative de
/// `CLAUDE.md`, sans que personne ne le remarque : un test supprimé ne laisse
/// pas d'échec derrière lui. Ils sont donc **repointés** sur l'objet qui expire
/// encore et dont la structure est identique — la **demande de connexion**, avec
/// sa vue brute (`incomingRequestsProvider`) et sa vue vivante
/// (`liveIncomingRequestsProvider`).
/// ⚠️ **`userLow` vaut « moi », et ce n'est pas un détail de fixture.**
/// `peerIdFor` rend l'AUTRE membre : une paire dont aucun côté n'est le lecteur
/// rendrait `userLow` — un identifiant qui n'est le pair de personne. Le test
/// passerait en mesurant autre chose que ce qu'il annonce.
Connection _conn({required String id, Profile? peer}) => Connection(
  id: id,
  userLow: 'moi',
  userHigh: 'pair-$id',
  status: ConnectionStatus.full,
  peer: peer,
);

ConnectionRequest _req({required String id, required DateTime expire}) =>
    ConnectionRequest(
      id: id,
      senderId: 'sender-$id',
      receiverId: 'moi',
      status: RequestStatus.pending,
      expiresAt: expire,
    );

/// Un container dont les SOURCES sont pilotables à la main, sans réseau.
///
/// ⚠️ **L'abonnement est ouvert DÈS la création**, et c'est indispensable : un
/// provider Riverpod est paresseux, il ne s'abonne à sa source qu'au premier
/// lecteur. Sans ce `listen`, la première émission part **avant** que quiconque
/// écoute et se perd — et les tests comptaient alors des notifications qui
/// n'étaient pas celles qu'ils annonçaient.
({
  ProviderContainer container,
  StreamController<List<Connection>> source,
  StreamController<List<ConnectionRequest>> demandes,
  StreamController<DateTime> horloge,
})
_harnais() {
  final source = StreamController<List<Connection>>.broadcast();
  final demandes = StreamController<List<ConnectionRequest>>.broadcast();
  final horloge = StreamController<DateTime>.broadcast();
  final container = ProviderContainer(
    overrides: [
      currentUserIdProvider.overrideWithValue('moi'),
      connectionsStreamProvider.overrideWith((ref) => source.stream),
      incomingRequestsProvider.overrideWith((ref) => demandes.stream),
      // ⚠️ **Le temps est pilote, jamais attendu.** Un test qui dort pour voir
      // expirer quelque chose mesure la vitesse de la machine autant que le
      // code, et il echoue un jour sur dix sans rien apprendre a personne.
      tickProvider(kExpiryTick).overrideWith((ref) => horloge.stream),
    ],
  );
  // Les sources doivent etre abonnees avant la premiere emission : un flux
  // `broadcast` ne rejoue rien. Oubli fait trois fois de suite pendant ce
  // chantier, chaque fois avec un compteur qui semblait bon.
  container.listen(connectionsStreamProvider, (_, _) {});
  container.listen(incomingRequestsProvider, (_, _) {});
  container.listen(expiryClockProvider, (_, _) {});
  return (
    container: container,
    source: source,
    demandes: demandes,
    horloge: horloge,
  );
}

/// Refuse de conclure si la source n'est pas arrivée.
///
/// ⚠️ Sans ce contrôle, **un compteur à zéro ressemble à une réussite** alors
/// qu'il ne prouve que le silence de l'instrument. Deux versions de ce fichier
/// s'y sont fait prendre.
void _sourceArrivee(ProviderContainer c, int attendu) {
  expect(
    c.read(connectionsStreamProvider).value,
    hasLength(attendu),
    reason:
        'La source n\'a pas traversé : rien de ce qui suit ne prouverait '
        'quoi que ce soit.',
  );
}

void _demandesArrivees(ProviderContainer c, int attendu) {
  expect(
    c.read(incomingRequestsProvider).value,
    hasLength(attendu),
    reason:
        'La source n\'a pas traversé : rien de ce qui suit ne prouverait '
        'quoi que ce soit.',
  );
}

/// Laisse le flux traverser Riverpod.
///
/// ⚠️ `Duration.zero` ne suffit PAS : un `StreamController` passe par la boucle
/// d'événements, et l'`AsyncValue` n'est pas encore à jour au tour suivant. Une
/// première version de ce fichier comptait donc **zéro notification parce que
/// rien n'était arrivé** — un compteur à zéro qui ressemblait à une réussite.
Future<void> _propage() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('Amplification : une connexion qui change en réveille combien ?', () {
    test('deux émissions au contenu identique ne doivent produire qu\'un seul '
        'réveil', () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.source.close);

      h.source.add([_conn(id: 'a')]);
      await _propage();
      _sourceArrivee(h.container, 1);

      var reveils = 0;
      h.container.listen(fullConnectionsProvider, (_, _) => reveils++);

      // Le serveur réémet la même chose — cas courant : une colonne sans
      // rapport change, ou le flux temps réel se réabonne.
      h.source.add([_conn(id: 'a')]);
      h.source.add([_conn(id: 'a')]);
      await _propage();

      expect(
        reveils,
        0,
        reason:
            'Le contenu affiché n\'a pas changé. En Dart, l\'égalité d\'une '
            'List est l\'IDENTITÉ : une nouvelle liste au contenu identique '
            'notifie quand même. C\'est le défaut mesuré ici.',
      );
    });

    test('un ami qui change de pseudo ne réveille pas ceux qui ne lisent que '
        'l\'ENSEMBLE des amis', () async {
      // ⚠️ **Remplace le test « une partielle ne réveille pas les complètes »**,
      // dont le sujet a disparu le 2026-08-28. Il prouve la même chose sur la
      // chaîne qui reste, et sur celle qui coûte le plus cher : les deux
      // bandeaux de stories n'observent que `friendIdsProvider`, précisément
      // pour ne pas se recalculer quand un avatar change.
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.source.close);

      const avant = Profile(id: 'pair-a', displayName: 'Mimi');
      const apres = Profile(id: 'pair-a', displayName: 'mimi ✨');

      h.source.add([_conn(id: 'a', peer: avant)]);
      await _propage();
      _sourceArrivee(h.container, 1);
      expect(h.container.read(friendIdsProvider), {'pair-a'});

      var reveilsIds = 0;
      var reveilsListe = 0;
      h.container.listen(friendIdsProvider, (_, _) => reveilsIds++);
      h.container.listen(fullConnectionsProvider, (_, _) => reveilsListe++);

      h.source.add([_conn(id: 'a', peer: apres)]);
      await _propage();

      expect(
        reveilsListe,
        1,
        reason:
            'La liste des connexions a bel et bien changé : celui qui affiche '
            'le pseudo DOIT être réveillé, sinon il montrerait du périmé.',
      );
      expect(
        reveilsIds,
        0,
        reason:
            'L\'ENSEMBLE des identifiants est inchangé. Chaque notification '
            'ici recalculerait les stories du Cercle ET celles du Ping pour '
            'un pseudo — c\'est l\'amplification que DerivedSet supprime.',
      );
    });
  });

  group('Le temps : une source a part entiere, pilotee', () {
    test('une demande expiree disparait au battement suivant, sans aucun '
        'evenement de la base', () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.demandes.close);
      addTearDown(h.horloge.close);

      final t0 = DateTime.utc(2026, 8, 28, 12);
      h.horloge.add(t0);
      h.demandes.add([
        _req(id: 'r', expire: t0.add(const Duration(seconds: 30))),
      ]);
      await _propage();
      _demandesArrivees(h.container, 1);
      expect(h.container.read(liveIncomingRequestsProvider), hasLength(1));

      var reveils = 0;
      h.container.listen(liveIncomingRequestsProvider, (_, _) => reveils++);

      // Le temps passe, mais pas assez : rien ne doit bouger.
      h.horloge.add(t0.add(const Duration(seconds: 10)));
      await _propage();
      expect(
        reveils,
        0,
        reason:
            "L'horloge a battu et la liste est inchangee. Un battement qui "
            "reveille l'ecran pour rien serait le defaut qu'on remplace, pas "
            "celui qu'on installe.",
      );

      // Le temps passe l'echeance : la, et la seulement, ca bouge.
      h.horloge.add(t0.add(const Duration(seconds: 31)));
      await _propage();

      expect(h.container.read(liveIncomingRequestsProvider), isEmpty);
      expect(
        reveils,
        1,
        reason: 'Exactement un reveil, au moment ou le contenu change.',
      );
    });

    test("la vue BRUTE des demandes ignore l'horloge", () async {
      final h = _harnais();
      addTearDown(h.container.dispose);
      addTearDown(h.demandes.close);
      addTearDown(h.horloge.close);

      final t0 = DateTime.utc(2026, 8, 28, 12);
      h.horloge.add(t0);
      h.demandes.add([
        _req(id: 'r', expire: t0.add(const Duration(seconds: 1))),
      ]);
      await _propage();

      h.horloge.add(t0.add(const Duration(hours: 1)));
      await _propage();

      expect(
        h.container.read(incomingRequestsProvider).value,
        hasLength(1),
        reason:
            "L'acquisition publie ce qui EST en base. La peremption est une "
            "decision d'affichage : elle appartient a la vue qui l'applique, "
            "pas a celle qui lit la table.",
      );
      expect(h.container.read(liveIncomingRequestsProvider), isEmpty);
    });
  });
}
