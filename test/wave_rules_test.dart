import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/wave_rules.dart';

/// Ce que ces tests défendent : **un presque est un jugement sur une
/// demi-journée, pas sur un instant.**
///
/// Le défaut d'origine, signalé par Jay le 2026-08-30 : *« il peut y avoir plein
/// de cas où deux utilisateurs sont ensemble puis se séparent temporairement…
/// mais ils passent un vrai moment ensemble. Et si on ne prend pas cela en
/// compte, wave devient un spam incessant de proximité. »*
///
/// ⚠️ **Aucun de ces cas n'était couvert par un test avant ce jour**, et aucun
/// ne lève d'erreur quand il est faux : une notification de trop est
/// indiscernable d'une notification légitime, vue du code.
void main() {
  // Une heure de référence, pour que tout se lise en clair.
  final t = DateTime(2026, 8, 30, 15, 0);

  Presence presence(DateTime debut, Duration duree) =>
      Presence(debut: debut, fin: debut.add(duree));

  /// Le croisement type : dix secondes, à l'heure de référence.
  final contact = presence(t, const Duration(seconds: 10));

  group('le presque', () {
    test('un vrai croisement manqué, sans rien autour, passe', () {
      expect(WaveRules.wave(historique: const [], contact: contact), isTrue);
    });

    test('un contact de 20 s ou plus n\'est PAS un presque', () {
      // La borne est stricte : 20 s exactement ne passe pas.
      expect(
        WaveRules.wave(
          historique: const [],
          contact: presence(t, WaveRules.contactBref),
        ),
        isFalse,
      );
      expect(
        WaveRules.wave(
          historique: const [],
          contact: presence(t, const Duration(seconds: 19)),
        ),
        isTrue,
      );
    });

    test(
      'un vrai moment passé ensemble dans les 2 h précédentes le supprime',
      () {
        // 🔴 LE CAS DE JAY : on a déjeuné ensemble, on se recroise dix secondes
        // dans le couloir. Ce n'est pas un croisement manqué.
        final dejeuner = presence(
          t.subtract(const Duration(minutes: 90)),
          const Duration(minutes: 40),
        );
        expect(
          WaveRules.wave(historique: [dejeuner], contact: contact),
          isFalse,
        );
      },
    );

    test('un moment COURT dans les 2 h précédentes ne le supprime pas', () {
      // Quatre minutes : sous le seuil de cinq. Deux personnes qui se ratent
      // deux fois se sont bien ratées deux fois.
      final bref = presence(
        t.subtract(const Duration(minutes: 90)),
        const Duration(minutes: 4),
      );
      expect(WaveRules.wave(historique: [bref], contact: contact), isTrue);
    });

    test('un vrai moment passé ensemble APRÈS le supprime aussi', () {
      // On se croise dix secondes, et on se retrouve vraiment vingt minutes
      // plus tard : on ne s'est pas ratés.
      final retrouvailles = presence(
        t.add(const Duration(minutes: 20)),
        const Duration(minutes: 10),
      );
      expect(
        WaveRules.wave(historique: [retrouvailles], contact: contact),
        isFalse,
      );
    });

    test('l\'asymétrie avant/après est bien celle demandée par Jay', () {
      // ⚠️ 4 minutes AVANT : toléré (seuil 5 min). Les mêmes 4 minutes APRÈS :
      // refusé (seuil 2 min). Confirmé par Jay le 2026-08-30 — ce qui se passe
      // après prouve mieux qu'on ne s'est pas ratés.
      final avant = presence(
        t.subtract(const Duration(minutes: 30)),
        const Duration(minutes: 4),
      );
      final apres = presence(
        t.add(const Duration(minutes: 30)),
        const Duration(minutes: 4),
      );
      expect(WaveRules.wave(historique: [avant], contact: contact), isTrue);
      expect(WaveRules.wave(historique: [apres], contact: contact), isFalse);
    });

    test('au-delà des fenêtres, un long moment ne compte plus', () {
      // Trois heures avant : hors de la fenêtre de deux heures.
      final hier = presence(
        t.subtract(const Duration(hours: 3)),
        const Duration(hours: 1),
      );
      // Deux heures après : hors de la fenêtre d'une heure.
      final plusTard = presence(
        t.add(const Duration(hours: 2)),
        const Duration(hours: 1),
      );
      expect(
        WaveRules.wave(historique: [hier, plusTard], contact: contact),
        isTrue,
      );
    });

    test('une présence À CHEVAL sur la fenêtre compte quand même', () {
      // Elle commence avant la fenêtre et finit dedans : on a bien passé du
      // temps ensemble dans la période, donc ce n'est pas un presque.
      final aCheval = presence(
        t.subtract(const Duration(hours: 3)),
        const Duration(hours: 2, minutes: 30),
      );
      expect(WaveRules.wave(historique: [aCheval], contact: contact), isFalse);
    });
  });

  group('« ton ami est tout près »', () {
    test('personne vu depuis longtemps : la notification part', () {
      expect(
        WaveRules.toutPres(
          historique: const [],
          contact: contact,
          detections: WaveRules.presDetectionsMin,
        ),
        isTrue,
      );
    });

    test('un contact trop peu entendu ne notifie RIEN', () {
      // 🔴 La borne PAR LE BAS. Un seul paquet capté par erreur — la radio
      // hoquette, relevé le 2026-08-29 — ne doit pas notifier.
      expect(
        WaveRules.toutPres(
          historique: const [],
          contact: contact,
          detections: WaveRules.presDetectionsMin - 1,
        ),
        isFalse,
      );
    });

    test('deux minutes ensemble dans la dernière heure la bloquent', () {
      final ensemble = presence(
        t.subtract(const Duration(minutes: 30)),
        const Duration(minutes: 3),
      );
      expect(
        WaveRules.toutPres(
          historique: [ensemble],
          contact: contact,
          detections: 20,
        ),
        isFalse,
      );
    });

    test('la même chose il y a plus d\'une heure ne la bloque plus', () {
      final ensemble = presence(
        t.subtract(const Duration(minutes: 90)),
        const Duration(minutes: 3),
      );
      expect(
        WaveRules.toutPres(
          historique: [ensemble],
          contact: contact,
          detections: 20,
        ),
        isTrue,
      );
    });

    test('un LONG contact notifie quand même — la borne est en bas', () {
      // « Tout près » ne dit pas « vous vous êtes ratés » : rester une heure
      // ensemble n'empêche pas d'avoir été prévenu de son arrivée.
      expect(
        WaveRules.toutPres(
          historique: const [],
          contact: presence(t, const Duration(hours: 1)),
          detections: 500,
        ),
        isTrue,
      );
    });
  });

  group('les deux jugements sont INDÉPENDANTS', () {
    test('le cas exact qui les sépare : presque OUI, tout près NON', () {
      // 🔴 Décision de Jay, 2026-08-30 : « ce sont deux choses différentes,
      // jugements indépendants ». Trois minutes ensemble il y a une
      // demi-heure, puis dix secondes de croisement.
      final troisMinutes = presence(
        t.subtract(const Duration(minutes: 30)),
        const Duration(minutes: 3),
      );
      // « tout près » : bloqué, plus de 2 min dans la dernière heure.
      expect(
        WaveRules.toutPres(
          historique: [troisMinutes],
          contact: contact,
          detections: 20,
        ),
        isFalse,
      );
      // le presque : passe, 3 min reste sous les 5 min sur deux heures.
      expect(
        WaveRules.wave(historique: [troisMinutes], contact: contact),
        isTrue,
      );
    });

    test('et l\'inverse : tout près OUI, presque NON', () {
      // Rien avant, mais on se retrouve vraiment juste après.
      final retrouvailles = presence(
        t.add(const Duration(minutes: 10)),
        const Duration(minutes: 30),
      );
      expect(
        WaveRules.toutPres(
          historique: [retrouvailles],
          contact: contact,
          detections: 20,
        ),
        isTrue,
      );
      expect(
        WaveRules.wave(historique: [retrouvailles], contact: contact),
        isFalse,
      );
    });
  });

  group('le calendrier', () {
    test('le verdict du presque n\'est pas prêt avant une heure', () {
      expect(
        WaveRules.verdictPret(contact, contact.fin),
        isFalse,
        reason: 'à la fin du contact, la fenêtre d\'après est vide',
      );
      expect(
        WaveRules.verdictPret(
          contact,
          contact.fin.add(const Duration(minutes: 59)),
        ),
        isFalse,
      );
      expect(
        WaveRules.verdictPret(contact, contact.fin.add(WaveRules.apresFenetre)),
        isTrue,
      );
    });

    test('la mémoire couvre les DEUX fenêtres', () {
      // Sinon le journal effacerait ce que la règle doit encore lire, et le
      // presque deviendrait faux sans que rien ne lève.
      expect(
        WaveRules.memoire,
        greaterThanOrEqualTo(WaveRules.avantFenetre + WaveRules.apresFenetre),
      );
    });
  });
}
