import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'connections_repository.dart';
import 'friendship.dart';

/// **La seule lecture des paliers d'amitié de toute l'app.**
///
/// ## Pourquoi ce dépôt n'est PAS dans `features/proximity/`
///
/// Consigne de Jay, 2026-08-28, redonnée le 2026-08-29 : *« c'est un chantier
/// séparé du ping ; ping ne doit rien avoir à voir avec cela, ou du moins le
/// strict minimum — c'est le principe de dissociation »*.
///
/// **Le ping prouve une RENCONTRE. Il ne décide d'aucun palier, ne les lit pas,
/// ne les affiche pas.** Il écrit un fait — « ces deux-là se sont croisés
/// aujourd'hui » — et s'arrête là. Ce que ce fait vaut socialement se décide
/// ici, du côté de l'usage, et le ping n'a aucun moyen de le savoir.
///
/// ⚠️ Le seul point de contact est en base, dans `report_sightings` : elle
/// écrit `meeting_days`. C'est de l'acquisition, pas une lecture de palier — le
/// ping publie, il ne consulte pas.
///
/// ## Un seul aller-retour, et aucune règle côté app
///
/// La RPC `my_friendships()` rend le palier, les jours comptés, ce qu'il reste
/// à faire et la série. Tout est calculé en base. L'écran reçoit des nombres et
/// n'a **aucun seuil** à connaître — sans quoi la règle vivrait à deux endroits
/// et l'un des deux mentirait un jour.
class FriendshipsRepository {
  FriendshipsRepository(this.ref);

  final Ref ref;

  /// Les amitiés de l'utilisateur connecté, indexées par identifiant d'ami.
  ///
  /// ⚠️ **Une map et pas une liste** : tous les appelants cherchent « quel est
  /// le palier de CETTE personne ». Rendre une liste obligerait chacun à la
  /// parcourir, donc à réécrire la même boucle — et à choisir, chacun de son
  /// côté, quoi faire quand la personne est absente.
  Future<Map<String, Friendship>> all() async {
    final rows = await ref.read(supabaseProvider).rpc('my_friendships') as List;
    return {
      for (final row in rows)
        (row as Map<String, dynamic>)['peer_id'] as String: Friendship.fromJson(
          row,
        ),
    };
  }
}

final friendshipsRepositoryProvider = Provider(FriendshipsRepository.new);

/// Les paliers, tels qu'ils sont en base.
///
/// ## 🔴 Corrigé le 2026-08-30 — constaté par Jay, en direct
///
/// *« Pendant que tu mettais à jour, j'étais sur la sphère et les 150 amis sont
/// arrivés sans que j'aie à recharger. Par contre, pour voir les anneaux et les
/// autres paliers, j'ai dû redémarrer l'app. »*
///
/// **Il a mis le doigt sur un désaccord de rythmes.** La liste d'amis arrive par
/// un flux temps réel ; les paliers, eux, étaient lus **une seule fois** au
/// démarrage. Les nouveaux amis apparaissaient donc sans palier — tous rangés
/// au plus bas, filtres vides, aucun anneau.
///
/// ⚠️ **Et rien ne le signalait** : un palier manquant retombe volontairement
/// sur « Ami » (c'est une règle de sécurité, voir [tierOfProvider]). L'écran
/// était donc cohérent, complet, et faux.
///
/// ➡️ **La correction est une dépendance, pas un rafraîchissement périodique** :
/// on se réabonne à la COMPOSITION de l'ensemble d'amis. Quand elle change, les
/// paliers se relisent. Quand elle ne change pas, on ne demande rien.
///
/// ⚠️ **Ce qui reste vrai, et assumé** : un palier qui monte *pendant* la
/// journée (un croisement de plus) n'apparaît qu'au prochain changement de la
/// liste ou au prochain lancement. C'est acceptable parce qu'un palier ne peut
/// changer **qu'une fois par jour et par ami** — mais c'est une limite, pas une
/// propriété, et elle est écrite ici pour ne pas être redécouverte.
final friendshipsProvider = FutureProvider<Map<String, Friendship>>((ref) {
  ref.watch(friendIdsProvider);
  return ref.read(friendshipsRepositoryProvider).all();
});

/// Le palier d'une personne — ou [FriendshipTier.friend] si on ne sait pas
/// encore.
///
/// ⚠️ **Le repli est le palier le plus BAS**, y compris pendant le chargement.
/// Un repli optimiste ferait clignoter des droits : l'écran montrerait une
/// story réservée le temps d'une requête, puis la retirerait. Le serveur, lui,
/// refuserait de toute façon — mais l'utilisateur aurait vu la porte s'ouvrir.
final tierOfProvider = Provider.family<FriendshipTier, String>((ref, peerId) {
  final amities = ref.watch(friendshipsProvider).value;
  return amities?[peerId]?.tier ?? FriendshipTier.friend;
});
