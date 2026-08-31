import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../supabase_providers.dart';

/// **Supprime pour de bon les octets des contenus qui n'existent plus.**
///
/// ## 🔴 Le défaut que ce fichier ferme — mesuré le 2026-08-31
///
/// La tâche de purge du serveur supprime les **lignes** des stories expirées.
/// Aucune ne supprimait les **fichiers**. Relevé en base de développement :
/// **88 objets orphelins sur 89** dans le coffre `stories` (36,6 Mo), 8 sur 74
/// dans `library`. « Éphémère » n'était vrai que des métadonnées.
///
/// ## ⚠️ Pourquoi ce ménage est fait par le CLIENT
///
/// Un `delete from storage.objects` est refusé par un déclencheur de Supabase.
/// Vérifié le 2026-08-31 en lisant sa définition : ce n'est pas une
/// interdiction absolue — il suffirait de poser un réglage de session — mais
/// **le contourner ne supprimerait que la ligne, pas le fichier**. Le blob
/// resterait dans le coffre, hors de tout inventaire : on remplacerait un
/// orphelin visible par un orphelin invisible.
///
/// La seule voie qui supprime vraiment est l'**API Storage**, donc un client
/// authentifié. Le seul que nous ayons est l'app. Le serveur inscrit donc ce
/// qui est à supprimer (déclencheurs sur `stories`, `library_items`, `cards`,
/// `library_vibes`), et le propriétaire le supprime, avec le droit qu'il a déjà
/// sur ses propres fichiers (`*_delete_own`).
///
/// ## ⚠️ La limite, assumée et écrite
///
/// Si le propriétaire ne rouvre jamais l'app, ses octets restent. C'est la même
/// limite coopérative que la purge des Enregistrements. La lever demande une
/// tâche serveur capable d'appeler l'API Storage — donc `pg_net` ou une
/// fonction déportée, aucune des deux n'existant aujourd'hui.
///
/// ## Ce qu'il ne fait pas
///
/// Il ne décide **rien** : ni quoi supprimer, ni quand. Le serveur le lui dit,
/// avec le délai de grâce de sept jours qu'il a posé (décision de Jay,
/// 2026-08-31). Ce fichier exécute, et déclare ce qu'il a fait.
class StorageSweep {
  StorageSweep(this._ref);

  final Ref _ref;

  /// Balaie ce qui est dû. Rend le nombre de fichiers réellement supprimés.
  ///
  /// **N'échoue jamais.** Un ménage raté n'est pas une panne : il se refera au
  /// prochain démarrage, et rien de ce qu'il touche n'est visible par
  /// l'utilisateur. Lever ici casserait un lancement pour un fichier mort.
  Future<int> run() async {
    try {
      final client = _ref.read(supabaseProvider);
      final rows = await client.rpc('mes_octets_a_supprimer');

      // Le serveur rend une ligne par fichier ; l'API Storage travaille par
      // coffre. On regroupe donc, et on ne fait qu'un appel par coffre.
      final parCoffre = <String, List<String>>{};
      for (final row in (rows as List)) {
        final map = (row as Map).cast<String, dynamic>();
        final coffre = map['bucket_id'] as String;
        (parCoffre[coffre] ??= []).add(map['object_name'] as String);
      }
      if (parCoffre.isEmpty) return 0;

      var supprimes = 0;
      for (final entry in parCoffre.entries) {
        try {
          await client.storage.from(entry.key).remove(entry.value);
          // ⚠️ **On ne raye la liste QUE si la suppression n'a pas levé.**
          //
          // Un fichier déjà absent ne lève pas : le rayer est juste, il n'y a
          // plus rien à supprimer. Mais une panne réseau, elle, doit laisser
          // l'inscription en place — sinon le serveur oublierait un fichier qui
          // existe encore, et **plus rien ne le supprimerait jamais**. Une
          // fonction de ménage qui perd sa liste est pire que pas de ménage.
          await client.rpc(
            'octets_supprimes',
            params: {'p_bucket': entry.key, 'p_names': entry.value},
          );
          supprimes += entry.value.length;
        } catch (_) {
          // Ce coffre repassera au prochain démarrage. Les autres continuent :
          // un coffre en panne ne doit pas bloquer le ménage des autres.
        }
      }
      return supprimes;
    } catch (_) {
      return 0;
    }
  }
}

final storageSweepProvider = Provider(StorageSweep.new);
