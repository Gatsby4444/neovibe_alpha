import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/event.dart';
import 'package:neovibe/features/events/events_screen.dart';
import 'package:neovibe/features/proximity/net/crossed_repository.dart';
import 'package:neovibe/features/proximity/ping_store.dart';
import 'package:neovibe/features/proximity/net/distance_estimate.dart';
import 'package:neovibe/features/proximity/net/peer_session.dart';
import 'package:neovibe/features/proximity/presence_feed.dart';
import 'package:neovibe/features/proximity/proximity_identity.dart';

/// **Les états de relation — le libellé du lien, de bout en bout.**
///
/// `RAPPELS.md` #99 : tout ce qui entrait au carnet de clés était présenté
/// comme un ami. Ces tests tiennent la promesse inverse à chaque étage où
/// une entrée du carnet devient quelque chose que l'utilisateur voit.

final _cle = Uint8List.fromList(List.filled(32, 7));

void main() {
  group('KeyRelation — le carnet dit pourquoi il connaît quelqu\'un', () {
    test('un carnet d\'avant le 2026-09-12 ne contenait que des amis', () {
      final ancien = FriendKeys.fromJson({
        'userId': 'u1',
        'username': 'Alice',
        'x25519Pub': 'BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=',
      });
      expect(ancien.relation, KeyRelation.friend);
      expect(ancien.isFriend, isTrue);
    });

    test('le libellé du serveur traverse le JSON, dans les deux sens', () {
      final pair = FriendKeys(
        userId: 'u2',
        username: 'Bob',
        x25519PublicKey: _cle,
        relation: KeyRelation.event,
      );
      final relu = FriendKeys.fromJson(pair.toJson());
      expect(relu.relation, KeyRelation.event);
      expect(relu.isFriend, isFalse);
    });

    test('changer de relation est un changement — `replace` doit le voir', () {
      final ami = FriendKeys(
        userId: 'u3',
        username: 'Carol',
        x25519PublicKey: _cle,
      );
      final invitee = FriendKeys(
        userId: 'u3',
        username: 'Carol',
        x25519PublicKey: _cle,
        relation: KeyRelation.event,
      );
      expect(
        ami.sameAs(invitee),
        isFalse,
        reason:
            'Sinon une amitié rompue mais une soirée commune laisserait '
            'Carol présentée comme une amie jusqu\'au prochain changement '
            'de clé.',
      );
    });

    test('une valeur inconnue du serveur retombe sur `friend`, jamais sur '
        'un état inventé', () {
      expect(KeyRelation.fromDb('bidule'), KeyRelation.friend);
      expect(KeyRelation.fromDb(null), KeyRelation.friend);
      expect(KeyRelation.fromDb('event'), KeyRelation.event);
    });
  });

  group('PingPeerSnapshot et PeerView — la tuile sait qui elle affiche', () {
    test('le JSON du magasin garde la relation', () {
      const s = PingPeerSnapshot(
        userId: 'u',
        username: 'Dan',
        relation: KeyRelation.event,
      );
      expect(PingPeerSnapshot.fromJson(s.toJson()).relation, KeyRelation.event);
    });

    test(
      'deux vues qui ne diffèrent que par la relation ne sont pas égales',
      () {
        const ami = PingPeerSnapshot(userId: 'u', username: 'Dan');
        const soiree = PingPeerSnapshot(
          userId: 'u',
          username: 'Dan',
          relation: KeyRelation.event,
        );
        PeerView vue(PingPeerSnapshot s) => PeerView(
          address: 'AA:BB',
          stage: PresenceStage.identified,
          band: ProximityBand.close,
          trend: ProximityTrend.stable,
          distanceLabel: '≈ 2 m',
          snapshot: s,
        );
        expect(
          vue(ami) == vue(soiree),
          isFalse,
          reason:
              'L\'égalité de PeerView EST la règle de redessin : si la relation '
              'n\'y entre pas, la tuile garde l\'anneau de palier d\'un ami '
              'pour quelqu\'un qui ne l\'est plus.',
        );
        expect(vue(ami), vue(ami));
      },
    );
  });

  group('CrossedPerson — le croisement dit d\'où il vient', () {
    test('par ping, sans événement', () {
      final c = CrossedPerson.fromJson({
        'user_id': 'u',
        'display_name': 'Eve',
        'crossed_at': '2026-09-12T10:00:00Z',
        'already_requested': false,
        'origin': 'ping',
      });
      expect(c.origin, CrossingOrigin.ping);
      expect(c.provenance, 'Croisé(e)');
    });

    test('à un événement, avec son nom', () {
      final c = CrossedPerson.fromJson({
        'user_id': 'u',
        'display_name': 'Eve',
        'crossed_at': '2026-09-12T10:00:00Z',
        'already_requested': false,
        'origin': 'event',
        'event_title': 'Soirée au Temple',
      });
      expect(c.origin, CrossingOrigin.event);
      expect(c.provenance, 'Croisé(e) à Soirée au Temple');
    });

    test('l\'origine compte dans l\'égalité', () {
      CrossedPerson faire(String origine) => CrossedPerson(
        userId: 'u',
        displayName: 'Eve',
        crossedAt: DateTime.utc(2026, 9, 12),
        alreadyRequested: false,
        origin: CrossingOrigin.fromDb(origine),
      );
      expect(faire('ping') == faire('event'), isFalse);
      expect(faire('ping'), faire('ping'));
    });
  });

  group('NeoEvent — les droits, tels que le serveur les tient', () {
    NeoEvent ev({
      String createdBy = 'moi',
      EventRole? myRole,
      bool membersCanAdd = true,
      bool membersCanRemove = true,
      DateTime? closedAt,
      EventKind kind = EventKind.private,
      bool iManage = false,
    }) => NeoEvent(
      id: 'ev',
      kind: kind,
      title: 'Soirée',
      createdBy: createdBy,
      conversationId: 'conv',
      startsAt: DateTime.utc(2026, 9, 12, 20),
      closedAt: closedAt,
      membersCanAdd: membersCanAdd,
      membersCanRemove: membersCanRemove,
      presentCount: 0,
      guestCount: 1,
      iAmPresent: false,
      myRole: myRole,
      iManage: iManage,
    );

    test(
      'le créateur invite toujours, même si les invités ne peuvent plus',
      () {
        expect(
          ev(
            createdBy: 'moi',
            myRole: EventRole.admin,
            membersCanAdd: false,
          ).canInvite('moi'),
          isTrue,
        );
      },
    );

    test('un admin invite si le créateur l\'a laissé, un membre jamais', () {
      expect(
        ev(createdBy: 'x', myRole: EventRole.admin).canInvite('moi'),
        isTrue,
      );
      expect(
        ev(
          createdBy: 'x',
          myRole: EventRole.admin,
          membersCanAdd: false,
        ).canInvite('moi'),
        isFalse,
      );
      expect(
        ev(createdBy: 'x', myRole: EventRole.member).canInvite('moi'),
        isFalse,
      );
    });

    test('un événement fermé ne s\'invite plus, ne se règle plus', () {
      final ferme = ev(closedAt: DateTime.utc(2026, 9, 13));
      expect(ferme.canInvite('moi'), isFalse);
      expect(ferme.canSettings('moi'), isFalse);
      expect(ferme.canClose('moi'), isFalse);
    });

    test('un établissement se règle par son gérant, pas par son créateur', () {
      expect(
        ev(
          kind: EventKind.venue,
          createdBy: 'moi',
          iManage: false,
        ).canSettings('moi'),
        isFalse,
      );
      expect(
        ev(
          kind: EventKind.venue,
          createdBy: 'x',
          iManage: true,
        ).canSettings('moi'),
        isTrue,
      );
      expect(
        ev(kind: EventKind.venue, iManage: true).canInvite('moi'),
        isFalse,
      );
    });

    test('l\'état en une phrase', () {
      final now = DateTime.utc(2026, 9, 12, 21);
      expect(eventStatusLabel(ev(), now), 'En cours · personne encore');
      expect(
        eventStatusLabel(ev(closedAt: DateTime.utc(2026, 9, 12)), now),
        'Terminé',
      );
    });
  });
}
