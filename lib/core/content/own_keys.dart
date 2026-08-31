import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Les clés de MES propres contenus, gardées sur l'appareil.
///
/// C'est le volet 2 de Jay : « si un utilisateur souhaite regarder sa propre
/// bibliothèque ou sa propre story, la source n'est pas le serveur mais le
/// téléphone en local ».
///
/// Sans ce magasin, la promesse n'était tenue qu'à moitié : les octets étaient
/// bien sur l'appareil (cache `own/`), mais **la clé venait du serveur** — donc
/// rouvrir ma propre story demandait quand même le réseau, et échouait hors
/// ligne.
///
/// ### Pourquoi c'est sans conséquence sur la sécurité
///
/// Cette clé, c'est **mon appareil qui l'a fabriquée**, au moment de publier.
/// Je possède déjà l'original du média — je viens de le capturer. La garder ne
/// m'accorde donc aucun accès que je n'avais pas ; elle m'évite seulement un
/// aller-retour serveur pour quelque chose qui m'appartient.
///
/// Ce qui reste vrai : la clé du contenu **d'autrui** ne s'obtient jamais que
/// du serveur, à chaque ouverture. C'est là qu'est la garantie, et elle n'est
/// pas touchée.
///
/// ### Révocation — ce que ce magasin NE fait PAS
///
/// ⚠️ **Le paragraphe qui vivait ici était faux, et il l'a été vingt jours.**
/// Il annonçait : *« Un de mes contenus révoqué doit devenir illisible pour moi
/// aussi. La clé locale est donc effacée par le même balayage que les
/// sauvegardes. »* Ce balayage n'existait pas : `SavedStore.purgeRevoked` ne
/// touche que les Enregistrements, et [remove] n'avait alors aucun appelant.
/// Un commentaire qui décrit un mécanisme absent est pire qu'un silence — il
/// dispense d'aller voir.
///
/// **Décision de Jay, 2026-08-31 : c'est le commentaire qui était en trop, pas
/// le code.** Un contenu que j'ai produit et qui est déjà sur mon téléphone
/// m'appartient, même révoqué. La révocation coupe ce que le **serveur** sert —
/// à tout le monde, moi compris. Elle ne va pas reprendre ce qui est déjà là.
///
/// Ce qui efface donc une clé, et rien d'autre :
///
/// - je supprime le contenu moi-même ([remove], appelée par
///   `StoriesRepository.remove` et `LibraryRepository.removeItem`) ;
/// - je change de compte ([clear], appelée par `LocalContentOwner`).
///
/// ⚠️ **Ce qui reste vrai et n'est pas touché** : la clé du contenu d'AUTRUI ne
/// s'obtient jamais que du serveur, à chaque ouverture. La garantie est là, et
/// elle ne dépend pas de ce fichier.
class OwnKeyStore {
  OwnKeyStore();

  Directory? _root;
  Map<String, dynamic>? _keys;

  Future<File> _file() async {
    _root ??= await getApplicationSupportDirectory();
    final dir = Directory(
      '${_root!.path}${Platform.pathSeparator}content_media',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}own_keys.json');
  }

  Future<Map<String, dynamic>> _load() async {
    if (_keys != null) return _keys!;
    try {
      final f = await _file();
      _keys = await f.exists()
          ? jsonDecode(await f.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      _keys = <String, dynamic>{};
    }
    return _keys!;
  }

  Future<void> _flush() async {
    if (_keys == null) return;
    try {
      await (await _file()).writeAsString(jsonEncode(_keys));
    } catch (_) {}
  }

  /// Retenue à la publication, quand la clé vient d'être fabriquée ici.
  Future<void> put(String contentId, String key) async {
    (await _load())[contentId] = key;
    await _flush();
  }

  Future<String?> get(String contentId) async =>
      (await _load())[contentId] as String?;

  Future<void> remove(String contentId) async {
    if ((await _load()).remove(contentId) != null) await _flush();
  }

  // ⚠️ **`ids()` a été SUPPRIMÉE le 2026-08-31** : aucun appelant, ni dans le
  // code ni dans les tests.
  //
  // Elle n'existait que pour un balayage de révocation qui n'a jamais été
  // écrit — et dont la documentation de cette classe promettait pourtant
  // l'existence. La décision de Jay du 2026-08-31 est de ne pas l'écrire :
  // rendre la liste des identifiants n'a donc plus aucun usage, et une méthode
  // publique sans appelant finit toujours par en trouver un qui la comprend de
  // travers.

  Future<void> clear() async {
    _keys = <String, dynamic>{};
    await _flush();
  }
}

final ownKeyStoreProvider = Provider((ref) => OwnKeyStore());
