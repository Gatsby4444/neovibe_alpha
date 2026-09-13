import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Le cache des vocaux **scellés** reçus — un fichier par message.
///
/// ## Pourquoi un cache à part
///
/// Un vocal n'est ni une Vibe ni un contenu du socle : il n'a pas de Content
/// ID, pas de faces, pas de politique de rétention par contexte. Le ranger dans
/// `ContentMediaCache` aurait forcé un objet à en imiter un autre pour entrer
/// dans son index (règle 2 de `CLAUDE.md` : deux objets aux règles différentes
/// ne partagent pas le même rangement). Sa règle est simple et unique : **il
/// meurt avec son message, 24 h**.
///
/// ## Ce qu'il contient
///
/// Le fichier scellé (`NVC1`), rempli bloc par bloc par le lecteur natif au fil
/// de l'écoute — jamais un octet en clair. Sans la clé (qui ne sort que de
/// `open_voice_message`), c'est du bruit. Un vocal scellé conservé ne trahit
/// donc rien de la promesse « ce qui se passe sur NeoVibe reste sur NeoVibe ».
class VoiceMediaCache {
  VoiceMediaCache();

  /// Même durée que le message : au-delà, le serveur l'a déjà supprimé.
  static const ttl = Duration(hours: 24);

  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/voice');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Le chemin du fichier scellé de ce message — qu'il existe déjà ou non. Le
  /// lecteur natif le crée et le remplit lui-même (`cachePath`).
  Future<String> pathFor(String messageId) async =>
      '${(await _dir()).path}/$messageId.nvc';

  /// Supprime ce qui a plus de [ttl]. Appelé à chaque ouverture : le coût est
  /// une lecture de répertoire, et il n'y a jamais plus de quelques dizaines de
  /// vocaux vivants.
  Future<void> sweep() async {
    final dir = await _dir();
    final limite = DateTime.now().subtract(ttl);
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      // Le fichier scellé et la carte des blocs du lecteur natif
      // (`<fichier>.map`) sont datés ensemble : la même règle les emporte.
      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(limite)) await entity.delete();
      } catch (_) {
        // Un fichier qu'on ne peut pas dater ou supprimer ne bloque pas le
        // reste du balayage.
      }
    }
  }

  Future<void> clear() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

final voiceMediaCacheProvider = Provider((ref) => VoiceMediaCache());
