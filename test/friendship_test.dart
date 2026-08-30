import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/palette.dart';
import 'package:neovibe/features/connections/friendship.dart';
import 'package:neovibe/features/proximity/net/presque_delai.dart';

void main() {
  group('Le palier lu depuis la base', () {
    test('une valeur inconnue retombe sur le palier le PLUS BAS', () {
      // ⚠️ Le sens de ce repli est une règle de sécurité, pas une commodité :
      // une valeur ajoutée en base et pas encore connue de l'app ne doit jamais
      // OUVRIR un droit.
      expect(FriendshipTier.fromKey(null), FriendshipTier.friend);
      expect(FriendshipTier.fromKey('inconnu'), FriendshipTier.friend);
      expect(FriendshipTier.fromKey(''), FriendshipTier.friend);
    });

    test('les trois paliers connus se lisent', () {
      expect(FriendshipTier.fromKey('friend'), FriendshipTier.friend);
      expect(FriendshipTier.fromKey('close'), FriendshipTier.close);
      expect(FriendshipTier.fromKey('inner'), FriendshipTier.inner);
    });

    test('l echelle est ordonnee, et « atteint » va dans le bon sens', () {
      expect(FriendshipTier.inner.atteint(FriendshipTier.close), isTrue);
      expect(FriendshipTier.close.atteint(FriendshipTier.close), isTrue);
      expect(FriendshipTier.friend.atteint(FriendshipTier.close), isFalse);
      expect(FriendshipTier.friend.atteint(FriendshipTier.friend), isTrue);
    });

    test('seuls les paliers au-dessus d ami portent un anneau', () {
      // Si tout le monde a un anneau, l'anneau ne distingue plus personne.
      expect(FriendshipTier.friend.porteUnAnneau, isFalse);
      expect(FriendshipTier.close.porteUnAnneau, isTrue);
      expect(FriendshipTier.inner.porteUnAnneau, isTrue);
    });

    test('chaque identite donne un anneau a chaque palier', () {
      // ⚠️ Un anneau qui retomberait sur une couleur écrite en dur serait
      // magenta sur l'identité beige — et personne ne le verrait avant de
      // changer de thème.
      for (final (nom, p) in NeoPalettes.toutes) {
        for (final t in FriendshipTier.values) {
          expect(t.anneau(p).colors, isNotEmpty, reason: '$nom / ${t.name}');
        }
      }
    });
  });

  group('Ce que le serveur publie', () {
    test('une amitie se lit depuis le JSON de la RPC', () {
      final f = Friendship.fromJson({
        'peer_id': 'abc',
        'tier': 'close',
        'tier_days': 7,
        'days_to_next': 8,
        'streak': 4,
      });
      expect(f.tier, FriendshipTier.close);
      expect(f.joursCroises, 7);
      expect(f.joursAvantSuivant, 8);
      expect(f.serie, 4);
    });

    test('au sommet, il n y a plus de palier suivant', () {
      final f = Friendship.fromJson({
        'peer_id': 'abc',
        'tier': 'inner',
        'tier_days': 22,
        'days_to_next': null,
        'streak': 20,
      });
      expect(f.joursAvantSuivant, isNull);
    });

    test('deux amities identiques sont EGALES', () {
      // ⚠️ Sans égalité de valeur, toute vue dérivée est inopérante en silence :
      // elle réveille l'écran à chaque publication, même identique.
      const a = Friendship(
        peerId: 'x',
        tier: FriendshipTier.close,
        joursCroises: 5,
        joursAvantSuivant: 10,
        serie: 3,
      );
      const b = Friendship(
        peerId: 'x',
        tier: FriendshipTier.close,
        joursCroises: 5,
        joursAvantSuivant: 10,
        serie: 3,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('L echelle de serie', () {
    test('on part de l oeuf', () {
      expect(PalierDeSerie.pour(0).emoji, '🥚');
    });

    test('un nombre entre deux paliers garde le palier ATTEINT', () {
      // 4 jours : au-dessus de « 3 », en dessous de « 5 ».
      expect(PalierDeSerie.pour(4).jours, 3);
      expect(PalierDeSerie.pour(13).jours, 10);
    });

    test('le palier suivant est celui qu on montre verrouille', () {
      expect(PalierDeSerie.suivant(0)?.jours, 1);
      expect(PalierDeSerie.suivant(4)?.jours, 5);
      expect(PalierDeSerie.suivant(20)?.jours, 30);
    });

    test('au sommet il n y a plus rien a montrer', () {
      expect(PalierDeSerie.suivant(100), isNull);
      expect(PalierDeSerie.suivant(500), isNull);
      expect(PalierDeSerie.pour(500).jours, 100);
    });

    test('l echelle est strictement croissante', () {
      // Une échelle mal ordonnée rendrait `pour()` faux sans lever d'erreur :
      // elle retournerait le dernier palier franchi dans l'ordre du tableau,
      // pas le plus haut.
      final jours = PalierDeSerie.echelle.map((p) => p.jours).toList();
      for (var i = 1; i < jours.length; i++) {
        expect(jours[i], greaterThan(jours[i - 1]));
      }
    });
  });

  group('Le delai du presque suit le palier', () {
    test('un ami simple attend, un inseparable est prevenu tout de suite', () {
      expect(
        PresqueDelai.pour(rangDuPalier: 0, tempsReelChoisi: false),
        PresqueDelai.ami,
      );
      expect(
        PresqueDelai.pour(rangDuPalier: 1, tempsReelChoisi: false),
        PresqueDelai.proche,
      );
      expect(
        PresqueDelai.pour(rangDuPalier: 2, tempsReelChoisi: false),
        Duration.zero,
      );
    });

    test('le reglage explicite de l utilisateur l emporte sur le palier', () {
      // ⚠️ Un réglage qu'une règle automatique peut annuler n'est plus un
      // réglage. Il a demandé « tout de suite » : il obtient tout de suite,
      // pour tout le monde.
      for (var rang = 0; rang < 3; rang++) {
        expect(
          PresqueDelai.pour(rangDuPalier: rang, tempsReelChoisi: true),
          Duration.zero,
          reason: 'rang $rang',
        );
      }
    });

    test('un rang inattendu ne raccourcit jamais le delai', () {
      // Le repli doit être le délai le plus LONG : un rang qu'on ne comprend
      // pas ne doit pas offrir le privilège.
      expect(
        PresqueDelai.pour(rangDuPalier: -1, tempsReelChoisi: false),
        PresqueDelai.ami,
      );
    });
  });
}
