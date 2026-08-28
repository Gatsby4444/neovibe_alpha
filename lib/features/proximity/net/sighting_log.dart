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

  /// Ce qui a **déjà été confié à la file**, avec son créneau.
  ///
  /// ## 🔴 Le défaut que cette table corrige — mesuré le 2026-08-28
  ///
  /// La déduplication ne vivait que dans [_pending], et [drain] le **vide**. Au
  /// tour de balayage suivant — deux secondes plus tard — [note] ne trouvait
  /// plus la clé, déclarait le constat « nouveau », et tout repartait : un
  /// élément de plus dans la file, et une synchronisation complète.
  ///
  /// Le commentaire de `ProximityController._sweepSightings` promettait
  /// pourtant *« un constat par quart d'heure »*. **Relevé sur l'appareil de
  /// Jay : 50 synchronisations pour 92 secondes de présence d'un ami** — soit
  /// ~200 appels serveur, pour **2 lignes** écrites en base (`report_sightings`
  /// déduplique par `(observer, seen, slot)`).
  ///
  /// ⚠️ **Rien ne l'affichait.** L'écran montrait la bonne chose, les tests
  /// passaient, la base était juste. Seule la facture changeait — c'est
  /// exactement la famille de défauts qui ne se voit qu'en **comptant**.
  ///
  /// ⚠️ **Un commentaire qui promet ne tient rien.** Celui-ci décrivait la
  /// bonne règle ; c'est le code qui ne l'appliquait pas. D'où le test
  /// `sighting_log_test.dart` qui la compte.
  final _sent = <String, int>{};

  int get length => _pending.length;

  /// Note un constat. Rend `true` s'il est **nouveau** — c'est ce qui évite de
  /// renvoyer cinquante fois la même chose : à ~10 annonces par seconde, un ami
  /// immobile produirait 9 000 constats identiques par créneau.
  ///
  /// « Nouveau » veut dire : ni en attente, **ni déjà parti**.
  bool note(Sighting sighting) {
    if (_pending.containsKey(sighting.key)) return false;
    if (_sent.containsKey(sighting.key)) return false;
    if (_pending.length >= maxPending) return false;
    _pending[sighting.key] = sighting;
    return true;
  }

  /// Note ce qu'on vient de voir, à partir du créneau courant.
  bool observe(String peerId, DateTime now, {ProximityBand? band}) {
    final slot = ProximityIdentity.slotIndex(now);
    _oublieLesCreneauxPasses(slot);
    return note(Sighting(peerId: peerId, slot: slot, band: band));
  }

  /// Purge le souvenir des créneaux révolus.
  ///
  /// ⚠️ **Un créneau de marge**, comme `slotTolerance` côté radio : deux
  /// téléphones n'ont jamais la même heure, et un constat du créneau précédent
  /// peut encore arriver du natif. Sans marge, il serait renvoyé une fois de
  /// plus — sans conséquence en base, mais c'est précisément le gaspillage
  /// qu'on supprime.
  ///
  /// Borne mémoire : au plus deux créneaux × le nombre d'amis.
  void _oublieLesCreneauxPasses(int slot) =>
      _sent.removeWhere((_, s) => s < slot - 1);

  /// Rend les constats en attente et **vide** la file d'attente.
  ///
  /// ⚠️ Vider ici et non après l'envoi est délibéré : ce qui part est confié à
  /// la file d'envoi, qui sait retenter. Garder une copie des deux côtés ferait
  /// deux vérités à réconcilier — exactement le défaut que ce chantier a passé
  /// son temps à supprimer.
  ///
  /// ⚠️ **Mais on garde la CLÉ**, dans [_sent]. C'est la différence entre
  /// « je ne détiens plus ce constat » (vrai, il est dans la file) et « je ne
  /// l'ai jamais vu » (faux, et c'était le bug).
  List<Sighting> drain() {
    final out = _pending.values.toList();
    for (final constat in out) {
      _sent[constat.key] = constat.slot;
    }
    _pending.clear();
    return out;
  }

  // ⚠️ **`clear()` a été RETIRÉ le 2026-08-28** : aucun appelant, ni dans le
  // code ni dans les tests. `drain()` vide déjà — et lui, il rend ce qu'il
  // vide. Une seconde façon de vider, qui perd le contenu sans le confier à la
  // file d'envoi, était une occasion silencieuse de jeter des croisements.
}

// ⚠️ **`TokenResolver` a été SUPPRIMÉ le 2026-08-28** : ce typedef n'était
// utilisé nulle part, ni dans le code ni dans les tests. Ce qu'il décrivait
// reste vrai — ce journal ne manipule que des identifiants d'amis déjà
// résolus, jamais de jetons — mais un type que rien n'implémente n'impose
// rien : c'est la construction de `Sighting` qui le garantit.
