import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/derived_list.dart';
import 'net/ping_nearby_feed.dart';
import 'presence_feed.dart';

/// **« Qui est à portée ? » — la réponse unique, quelle que soit la source.**
///
/// ## Pourquoi ce fichier existe : le défaut du 2026-08-27
///
/// La présence avait **une** source et **une** réponse : le BLE. Un pair était
/// « à portée » s'il avait été identifié par la radio, et c'était vrai pour tout
/// le monde — amis comme inconnus, puisque les inconnus se révélaient par une
/// poignée de main GATT.
///
/// Ce chemin a été supprimé le 2026-08-27 : l'identité d'un inconnu vient
/// désormais du serveur. **Il y a donc maintenant deux sources**, et l'ancienne
/// vue n'en connaissait qu'une :
///
/// | Qui | D'où vient sa présence |
/// |---|---|
/// | un **ami** | le BLE, reconnu à l'annonce |
/// | un **inconnu** | le serveur, après réciprocité prouvée |
///
/// ⚠️ **Ce que ça produisait, et rien ne le signalait** : un inconnu révélé par
/// le ping n'était jamais « à portée ». La conversation de proximité affichait
/// donc en permanence *« Hors de portée — ce canal se fermera sans échange
/// mutuel »*, même à deux mètres, et l'écran des connexions disait la même chose
/// d'une demande reçue.
///
/// C'est la règle de dissociation, prise à l'envers : **deux acquisitions qui
/// ne battent pas au même rythme** — la radio à chaque annonce, le serveur
/// toutes les dix secondes — et une vue qui n'en lisait qu'une. La corriger en
/// ajoutant le ping dans `presence_feed` aurait mélangé les couches : cette
/// vue-ci n'appartient à aucune des deux, elle est **au-dessus**.
///
/// ## ⚠️ Ce que cette vue ne fait pas
///
/// Elle ne dit pas **à quelle distance**. Seul le BLE le sait, et seulement pour
/// les amis. Une position n'a jamais la finesse nécessaire (voir
/// `geo/coarse_location.dart`) : demander une distance à cette vue serait
/// demander au serveur quelque chose qu'il ne peut pas savoir.

/// Tous ceux qui sont à portée **maintenant**, toutes sources confondues.
///
/// ⚠️ **`DerivedSet`, et ce n'est pas décoratif.** Un `Set` n'a pas d'égalité de
/// valeur en Dart : sans lui, cette vue réveillerait ses lecteurs à chaque tour
/// du ping — toutes les dix secondes — pour un ensemble inchangé.
class NearbyPeople extends Notifier<Set<String>> with DerivedSet<String> {
  @override
  Set<String> build() {
    final parLaRadio = ref.watch(bleNearbyUserIdsProvider);
    final parLeServeur = ref.watch(pingNearbyProvider);
    return {
      ...parLaRadio,
      for (final personne in parLeServeur) personne.userId,
    };
  }
}

final nearbyUserIdsProvider = NotifierProvider<NearbyPeople, Set<String>>(
  NearbyPeople.new,
);

/// Vrai si [userId] est à portée **maintenant**.
///
/// ⚠️ **Le `.select` est ce qui rend cette vue bon marché.** Il réduit un
/// ensemble à un booléen : un lecteur qui suit une seule personne n'est réveillé
/// que quand **cette** personne arrive ou part, pas quand l'ensemble bouge.
final isNearbyProvider = Provider.family<bool, String>((ref, userId) {
  return ref.watch(nearbyUserIdsProvider.select((ids) => ids.contains(userId)));
});
