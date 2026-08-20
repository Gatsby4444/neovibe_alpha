import 'dart:typed_data';

import '../proximity_identity.dart';
import 'distance_estimate.dart';

/// **Le journal des constats : « j'ai vu le jeton de X au créneau S ».**
///
/// ## Pourquoi ce chemin existe à côté du certificat co-signé
///
/// Un croisement exigeait jusqu'ici que les deux téléphones ouvrent une
/// connexion GATT **vivante** et échangent deux signatures. C'est cher et
/// fragile : il faut que les deux apps soient réveillées au même instant, que la
/// pile Bluetooth soit libre, et que la connexion aboutisse. Dans une salle
/// pleine, elle n'aboutit souvent pas — et le croisement est perdu sans que
/// personne ne le sache.
///
/// Décision de Jay, 2026-08-20 (`RAPPELS.md` #55, option ②) : **chacun constate
/// de son côté**, et c'est le serveur qui ne retient un croisement que si le
/// constat inverse existe. Aucune connexion n'est nécessaire.
///
/// ## ⚠️ La propriété anti-traque est STRUCTURELLE, pas déclarative
///
/// Un constat unilatéral ne produit **rien**. Celui qui écouterait sans jamais
/// s'annoncer n'obtiendrait aucun croisement, aucune notification, aucun
/// historique. On ne peut pas observer sans être observé — ce n'est pas une
/// règle appliquée quelque part, c'est la seule façon dont un croisement peut
/// naître par ce chemin.
///
/// ## ⚠️ Ce que ce journal ne fait pas
///
/// Il ne décide de rien, n'appelle aucun réseau, ne touche à aucun fichier. Il
/// **accumule des constats** et sait dire lesquels méritent de partir. Le
/// stockage appartient au magasin, l'envoi à la synchro. Règle de dissociation
/// de Jay (2026-08-20).
///
/// ## ⚠️ Ce qu'il ne remplace pas
///
/// Le certificat co-signé reste le **plus fort** des deux : il est
/// infalsifiable sans les deux clés privées, alors que deux complices peuvent
/// fabriquer des constats concordants sans s'être rencontrés. Le serveur garde
/// donc les deux niveaux distincts (`encounters.proof`), et un constat mutuel
/// ne rétrograde jamais un certificat.

/// Un constat : qui, quand, et à quelle distance approximative.
class Sighting {
  const Sighting({required this.peerId, required this.slot, this.band});

  final String peerId;

  /// Le créneau de 15 min. **Pas un horodatage** : c'est la seule granularité
  /// sur laquelle deux téléphones peuvent se rejoindre sans se parler — et la
  /// seule qu'on ait envie de confier au serveur.
  final int slot;

  /// Bande de proximité. ⚠️ **Jamais une distance en mètres** : une distance au
  /// mètre près transformerait une app de rencontre en outil de traque
  /// (spec 4.2), et elle serait de toute façon fausse d'un facteur 2 à 4.
  final ProximityBand? band;

  /// Ce qui part au serveur, et rien de plus.
  Map<String, dynamic> toJson() => {
    'peer': peerId,
    'slot': slot,
    if (band != null) 'band': band!.name,
  };

  factory Sighting.fromJson(Map<String, dynamic> json) => Sighting(
    peerId: json['peer'] as String,
    slot: (json['slot'] as num).toInt(),
    band: switch (json['band'] as String?) {
      'contact' => ProximityBand.contact,
      'close' => ProximityBand.close,
      'room' => ProximityBand.room,
      'far' => ProximityBand.far,
      _ => null,
    },
  );

  /// La clé d'unicité : **une personne, un créneau, un constat**.
  String get key => '$peerId@$slot';
}

/// Accumule les constats du moment, sans doublon.
class SightingLog {
  SightingLog({this.maxPending = 500});

  /// Au-delà, on cesse d'accumuler.
  ///
  /// ⚠️ **Une mémoire non bornée dans un objet qui vit des jours est une
  /// fuite**, et elle ne se voit qu'au bout de longtemps. 500 constats couvrent
  /// largement 48 h de croisements réels ; au-delà, c'est qu'ils ne partent
  /// plus, et en accumuler davantage n'y changerait rien.
  final int maxPending;

  final _pending = <String, Sighting>{};

  int get length => _pending.length;

  /// Note un constat. Rend `true` s'il est **nouveau** — c'est ce qui évite de
  /// renvoyer cinquante fois la même chose : à ~10 annonces par seconde, un ami
  /// immobile produirait 9 000 constats identiques par créneau.
  bool note(Sighting sighting) {
    if (_pending.containsKey(sighting.key)) return false;
    if (_pending.length >= maxPending) return false;
    _pending[sighting.key] = sighting;
    return true;
  }

  /// Note ce qu'on vient de voir, à partir du créneau courant.
  bool observe(String peerId, DateTime now, {ProximityBand? band}) => note(
    Sighting(
      peerId: peerId,
      slot: ProximityIdentity.slotIndex(now),
      band: band,
    ),
  );

  /// Rend les constats en attente et **vide** le journal.
  ///
  /// ⚠️ Vider ici et non après l'envoi est délibéré : ce qui part est confié à
  /// la file d'envoi, qui sait retenter. Garder une copie des deux côtés ferait
  /// deux vérités à réconcilier — exactement le défaut que ce chantier a passé
  /// son temps à supprimer.
  List<Sighting> drain() {
    final out = _pending.values.toList();
    _pending.clear();
    return out;
  }

  void clear() => _pending.clear();
}

/// Ce que la couche de reconnaissance sait dire d'un jeton capté.
///
/// Existe pour que le journal n'ait **jamais** à connaître un jeton : il ne
/// manipule que des identifiants d'amis déjà résolus. Un journal qui verrait
/// passer des jetons serait un journal qu'il faudrait protéger.
typedef TokenResolver = String? Function(Uint8List advertId);
