import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../supabase_providers.dart';
import '../../features/cards/card_media_cache.dart';
import 'content_media_cache.dart';
import 'content_preloader.dart';
import 'own_keys.dart';
import 'saved_store.dart';

/// **À qui appartient ce qui est stocké sur cet appareil.**
///
/// ## 🔴 La fuite que ce fichier ferme — relevée le 2026-08-31
///
/// Les Enregistrements, les clés de mes contenus et les caches de médias sont
/// des fichiers **sans propriétaire inscrit**. `signOut()` ne nettoie que la
/// session serveur. Un compte B ouvert sur le même téléphone héritait donc de
/// tout — et l'écran « Enregistrements » ne filtre sur personne : **B voyait
/// les photos et vidéos que A avait enregistrées, en clair.**
///
/// ⚠️ **C'est exactement la fuite déjà corrigée pour le ping le 2026-08-17**
/// (carnet d'amis, croisements, cooldown des waves), puis pour l'identité de
/// l'appareil le 2026-08-18. Le raisonnement n'avait simplement jamais été
/// appliqué au **contenu**. Une correction qui ne se généralise pas à ses
/// frères laisse la même porte ouverte un étage plus loin.
///
/// ## ⚠️ Pourquoi le compte lié est PERSISTÉ, et pas gardé en mémoire
///
/// `ProximityController` retient le sien dans un champ. Il détecte donc un
/// changement de compte **pendant une session**, et rate celui qui se produit
/// entre deux lancements : je me déconnecte, l'app est fermée, quelqu'un
/// d'autre se connecte au démarrage suivant — le champ repart à `null`, aucune
/// différence n'est constatée, et rien n'est effacé.
///
/// C'est le cas le plus probable des deux : on ne change pas de compte sans
/// fermer l'app. D'où l'écriture dans les préférences.
///
/// ## Ce qu'il n'efface PAS
///
/// Le local du ping : il a son propre effacement, au même moment et pour la
/// même raison (`ProximityController._forgetLocalPing`). Deux magasins, deux
/// responsables — les fusionner ferait dépendre l'effacement du contenu de
/// l'état de la radio.
class LocalContentOwner {
  LocalContentOwner(this._ref);

  final Ref _ref;

  static const _cle = 'nv_local_content_owner';

  /// Lie le stockage local à [me], en effaçant d'abord ce qui appartenait à
  /// quelqu'un d'autre.
  ///
  /// Rend `true` si un effacement a eu lieu — l'appelant en profite pour
  /// rafraîchir ce qui était affiché.
  ///
  /// ⚠️ **Un `null` n'efface rien.** Se déconnecter ne doit pas détruire ses
  /// propres Enregistrements : c'est l'arrivée d'un compte **différent** qui
  /// les rend illégitimes, pas l'absence de compte.
  Future<bool> bind(String? me) async {
    if (me == null) return false;
    final prefs = await SharedPreferences.getInstance();
    final avant = prefs.getString(_cle);
    if (avant == me) return false;

    final aEfface = avant != null;
    if (aEfface) await _oublieTout();
    await prefs.setString(_cle, me);
    return aEfface;
  }

  Future<void> _oublieTout() async {
    // Chaque magasin sait se vider ; aucun n'a besoin de savoir pourquoi.
    // On avale les échecs un par un : un magasin qui refuse ne doit pas
    // empêcher les autres d'être nettoyés — c'est le contraire de ce qu'on veut
    // quand on efface les données de quelqu'un d'autre.
    Future<void> essaie(Future<void> Function() quoi) async {
      try {
        await quoi();
      } catch (_) {}
    }

    await essaie(() => _ref.read(savedStoreProvider).clear());
    await essaie(() => _ref.read(ownKeyStoreProvider).clear());
    await essaie(() => _ref.read(contentMediaCacheProvider).clear());
    await essaie(() => _ref.read(cardMediaCacheProvider).clearOwn());
    await essaie(() => _ref.read(cardMediaCacheProvider).clearOthers());
    _ref.read(contentPreloaderProvider).clear();
  }
}

final localContentOwnerProvider = Provider(LocalContentOwner.new);

/// Le compte lié au stockage local, et ce qu'il a fallu effacer pour l'y lier.
///
/// ⚠️ **Observé par `RootGate`, et il doit l'être avant tout affichage de
/// contenu local** : un écran qui lirait les Enregistrements pendant
/// l'effacement montrerait ceux du compte précédent.
final localContentBoundProvider = FutureProvider<bool>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  return ref.read(localContentOwnerProvider).bind(me);
});
