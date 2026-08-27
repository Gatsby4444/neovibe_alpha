import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/nearby_user.dart';
import 'net/distance_estimate.dart';
import 'net/peer_session.dart';
import 'ping_store.dart';

/// **Le flux de présence : ce qui est ACQUIS, séparé de ce qui l'UTILISE.**
///
/// ## Pourquoi ce fichier existe — règle de Jay, 2026-08-20
///
/// > « Tu dois totalement dissocier le code qui se charge d'acquérir des données
/// > du code qui utilise ces données. »
///
/// Avant lui, tout passait par un objet unique : le contrôleur reconstruisait
/// **l'état entier** (pairs + demandes reçues + demandes envoyées) à chaque
/// annonce BLE, et l'écran observait cet objet entier. Deux conséquences, toutes
/// deux mesurables :
///
/// 1. **Chaque annonce relisait deux fichiers sur le disque.** Les demandes
///    d'amis n'ont pourtant aucun rapport avec un signal radio qui bouge.
/// 2. **Une seule tuile qui change redessinait toute la page.** L'écran ne
///    pouvait pas s'abonner plus finement : il n'existait qu'une seule chose à
///    observer.
///
/// D'où le compromis d'origine — ne publier que sur changement de
/// `{adresse, stade}` — qui figeait la bande, la tendance et la distance pour
/// un pair identifié et immobile (audit du 2026-08-18, point C).
///
/// Ici, les trois responsabilités sont **trois objets distincts** :
///
/// | Objet | Rôle | Fréquence |
/// |---|---|---|
/// | [presenceProvider] | ce que la radio a constaté, brut et fidèle | à chaque annonce |
/// | [presenceKeysProvider] | qui est dans la liste, et dans quel ordre | rare |
/// | [peerViewProvider] | ce qu'UNE tuile affiche | quand cette tuile change |
///
/// ⚠️ **La conséquence de méthode, et c'est elle qui compte** : la couche
/// d'acquisition ne décide plus si l'interface doit se redessiner. Elle publie
/// ce qu'elle constate ; c'est la couche d'affichage qui compare, avec sa
/// propre définition de « différent ». Le réseau n'a plus à connaître les
/// champs d'une tuile — et une tuile qui gagne un champ ne demande plus de
/// toucher au réseau.

/// Ce qu'**une** tuile affiche, et rien d'autre.
///
/// ⚠️ **L'égalité de cet objet EST la règle de redessin.** Deux `PeerView`
/// égales veulent dire « l'utilisateur verrait exactement la même chose », donc
/// Riverpod ne notifie pas. C'est pour ça que la distance y figure sous forme de
/// **texte déjà formaté** et non de nombre : ce qu'on compare doit être ce que
/// l'œil voit. Un RSSI de -71,3 puis -71,4 dBm donne le même « ≈ 2 m » — aucune
/// raison de reconstruire quoi que ce soit.
class PeerView {
  const PeerView({
    required this.address,
    required this.stage,
    required this.band,
    required this.trend,
    required this.level,
    required this.distanceLabel,
    required this.snapshot,
  });

  final String address;
  final PresenceStage stage;
  final ProximityBand band;
  final ProximityTrend trend;
  final ProximityLevel level;

  /// Déjà formatée : voir la note d'égalité ci-dessus.
  final String distanceLabel;

  final PingPeerSnapshot? snapshot;

  String? get userId => snapshot?.userId;

  factory PeerView.of(PresencePeer peer) => PeerView(
    address: peer.address,
    stage: peer.stage,
    band: peer.band,
    trend: peer.trend,
    level: peer.level,
    distanceLabel: peer.distance.metersLabel,
    snapshot: peer.snapshot,
  );

  @override
  bool operator ==(Object other) =>
      other is PeerView &&
      other.address == address &&
      other.stage == stage &&
      other.band == band &&
      other.trend == trend &&
      other.level == level &&
      other.distanceLabel == distanceLabel &&
      other.snapshot?.userId == snapshot?.userId &&
      other.snapshot?.displayName == snapshot?.displayName &&
      other.snapshot?.verified == snapshot?.verified;

  @override
  int get hashCode => Object.hash(
    address,
    stage,
    band,
    trend,
    level,
    distanceLabel,
    snapshot?.userId,
    snapshot?.displayName,
    snapshot?.verified,
  );
}

/// La composition de la liste : qui est affiché, et dans quel ordre.
///
/// Séparée du contenu des tuiles **parce qu'elle change beaucoup plus rarement**.
/// Sans elle, l'écran devrait observer la liste complète des pairs — donc se
/// reconstruire à chaque annonce, ce qu'on cherche précisément à éviter.
/// ⚠️ **`pending` a été retiré le 2026-08-27.**
///
/// Il comptait les pairs détectés mais pas encore identifiés, pour le bandeau
/// « N appareils détectés » — supprimé le 2026-08-27 avec la poignée de main
/// GATT, parce qu'il ne pouvait plus tomber à zéro.
///
/// ⚠️ **Le garder n'était pas neutre** : il entrait dans l'égalité de cet objet,
/// donc l'apparition d'un inconnu que **rien n'affiche** reconstruisait la liste
/// de l'écran Ping. Un champ que personne ne lit mais qui décide des redessins
/// est le pire des deux mondes.
class PresenceKeys {
  const PresenceKeys({required this.identified, required this.userIds});

  /// Adresses des pairs identifiés, dans l'ordre d'affichage.
  final List<String> identified;

  /// Les mêmes pairs, vus comme des personnes.
  ///
  /// ⚠️ **Ils vivent ici et pas dans un provider à part.** Un `Set` n'a pas
  /// d'égalité de valeur en Dart : un provider qui en construit un neuf à chaque
  /// annonce notifierait à chaque annonce, et tout le bénéfice serait perdu —
  /// silencieusement, puisque l'écran afficherait quand même la bonne chose.
  final List<String> userIds;

  @override
  bool operator ==(Object other) =>
      other is PresenceKeys &&
      _same(other.identified, identified) &&
      _same(other.userIds, userIds);

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(identified), Object.hashAll(userIds));
}

/// **L'acquisition.** Ce que la radio a constaté, publié tel quel.
///
/// ⚠️ **Aucun accès disque, aucune décision produit ici.** C'est ce qui permet
/// de le rafraîchir à la fréquence des annonces sans que ça coûte quoi que ce
/// soit. Tout ce qui est cher (magasin local, demandes d'amis) vit ailleurs et
/// se rafraîchit à son propre rythme.
class PresenceFeed extends Notifier<List<PresencePeer>> {
  @override
  List<PresencePeer> build() => const [];

  void publish(List<PresencePeer> peers) => state = peers;

  void clear() => state = const [];
}

final presenceProvider = NotifierProvider<PresenceFeed, List<PresencePeer>>(
  PresenceFeed.new,
);

/// Qui est dans la liste. Ne notifie que si la composition change.
final presenceKeysProvider = Provider<PresenceKeys>((ref) {
  final peers = ref.watch(presenceProvider);
  final identified = <String>[];
  final userIds = <String>[];
  for (final p in peers) {
    if (p.stage != PresenceStage.identified) continue;
    identified.add(p.address);
    final id = p.userId;
    if (id != null) userIds.add(id);
  }
  return PresenceKeys(identified: identified, userIds: userIds);
});

/// Ce qu'affiche la tuile de ce pair. Ne notifie que si CETTE tuile change.
final peerViewProvider = Provider.family<PeerView?, String>((ref, address) {
  return ref.watch(
    presenceProvider.select((peers) {
      for (final p in peers) {
        if (p.address == address) return PeerView.of(p);
      }
      return null;
    }),
  );
});

/// Les identifiants des pairs que **LA RADIO** a identifiés.
///
/// ⚠️ **Ce n'est plus la présence du produit, seulement une de ses deux
/// sources** — d'où le préfixe, posé le 2026-08-27. Depuis que l'identité d'un
/// inconnu vient du serveur, cette vue ne voit plus que les **amis** : eux seuls
/// sont reconnus à l'annonce.
///
/// La question « qui est à portée ? » se pose à `nearby_people.dart`, qui
/// combine les deux sources. La poser ici rendrait une réponse partielle — et
/// c'est exactement ce qui affichait « Hors de portée » à deux mètres.
final bleNearbyUserIdsProvider = Provider<Set<String>>((ref) {
  // Dérivé des CLÉS, pas de la présence brute : il ne se recalcule donc que
  // quand la composition change, et pas à chaque annonce.
  return ref.watch(presenceKeysProvider).userIds.toSet();
});

// ⚠️ `isNearbyProvider` a DÉMÉNAGÉ dans `nearby_people.dart` le 2026-08-27.
// Il vivait ici tant que la radio était la seule source de la présence. Le
// laisser aurait laissé deux réponses possibles à une même question, dont une
// fausse pour les inconnus — le motif que ce projet traque partout.
