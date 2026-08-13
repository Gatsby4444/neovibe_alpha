import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../supabase_providers.dart';
import 'content_face.dart';
import 'content_media_cache.dart';

/// Prépare **d'avance** ce qu'il faut pour afficher un contenu du socle.
///
/// ### Ce qu'il précharge, et pourquoi seulement ça
///
/// | Élément | Préchargé | Motif |
/// |---|---|---|
/// | URL signée | ✅ | un ticket, ne touche aucun compteur |
/// | Premier bloc (256 Ko) | ✅ | des octets chiffrés, inertes |
/// | Clé | ✅ **socle uniquement** | depuis le 2026-08-13, `open_content_media` n'enregistre plus la vue |
///
/// ### ⚠️ Ce qu'il ne fera JAMAIS : les Vibes en DM
///
/// Décision de Jay du 2026-08-13 : « on ne précharge pas les Vibes en
/// messagerie ». Ce n'est pas qu'une consigne, c'est une **impossibilité de
/// conception** : pour une Vibe reçue en conversation, `open_card_media`
/// vérifie, décompte et rend la clé dans **une seule transaction** — c'est ce
/// qui fait de la limite de vues une garantie et non une convention (décision
/// du 2026-08-10). Précharger sa clé **brûlerait une vue** sur un contenu que
/// personne n'a regardé.
///
/// Cette classe ne manipule que des [ContentFace], le type du **socle**
/// (stories, publications). Une Vibe en DM ne passe pas par ce type : elle ne
/// peut donc pas arriver ici **par construction**, et pas seulement par
/// discipline.
class ContentPreloader {
  ContentPreloader(this._ref);

  final Ref _ref;

  static const _channel = MethodChannel('neovibe/player');

  /// Au-delà, les clés les plus anciennes sont oubliées. Une clé n'est qu'un
  /// raccourci : l'oublier coûte un aller-retour, jamais un échec.
  static const _maxKeys = 40;

  /// Clés récupérées d'avance, par identifiant de contenu.
  final _keys = <String, String>{};

  /// Ce qui est déjà préchargé ou en cours — un contenu ne se précharge pas
  /// deux fois, même si plusieurs écrans le demandent.
  final _done = <String>{};

  /// La clé préchargée de [contentId], s'il y en a une.
  ///
  /// Consommée par `contentFaceProvider` : c'est ce qui retire l'aller-retour
  /// de clé du chemin visible.
  String? keyFor(String contentId) => _keys[contentId];

  /// Précharge la face [spec]. Sans effet si déjà fait.
  ///
  /// **N'échoue jamais.** Un préchargement raté n'est pas une panne : c'est
  /// une optimisation qui n'a pas eu lieu, et le contenu s'ouvrira à la vitesse
  /// normale. Lever ici casserait un écran pour une raison invisible à
  /// l'utilisateur.
  Future<void> preload(ContentFace spec) async {
    final id = '${spec.contentId}_${spec.front ? 'f' : 'b'}';
    if (!_done.add(id)) return;

    try {
      final client = _ref.read(supabaseProvider);
      final cache = _ref.read(contentMediaCacheProvider);

      // Les deux appels serveur partent ensemble : ils sont indépendants, et
      // les enchaîner coûterait un aller-retour de plus (leçon du matin).
      final urlFuture = client.storage
          .from(spec.bucket)
          .createSignedUrl(spec.path, 3600);
      final keyFuture = _keys.containsKey(spec.contentId)
          ? Future.value(_keys[spec.contentId]!)
          : client
                .rpc(
                  'open_content_media',
                  params: {'p_content_id': spec.contentId},
                )
                .then((v) => v as String);

      final cachePath = await cache.streamingPath(
        spec.contentId,
        front: spec.front,
      );
      final (url, key) = await (urlFuture, keyFuture).wait;

      _remember(spec.contentId, key);

      // Une photo n'a pas de blocs à amorcer : sa clé suffit à la préparer.
      if (!spec.isVideo) return;

      // Le natif amène l'en-tête et le premier bloc, avec le MÊME code que la
      // lecture — donc dans le même fichier, au même format.
      await _channel.invokeMethod<bool>('prime', {
        'url': url,
        'cachePath': cachePath,
      });
    } catch (_) {
      // Réessayable plus tard : on ne garde pas un échec en mémoire.
      _done.remove(id);
    }
  }

  void _remember(String contentId, String key) {
    _keys[contentId] = key;
    if (_keys.length > _maxKeys) _keys.remove(_keys.keys.first);
  }

  /// Oublie tout. À appeler à la déconnexion — une clé en mémoire n'a plus
  /// aucune raison d'exister une fois la session terminée.
  void clear() {
    _keys.clear();
    _done.clear();
  }
}

final contentPreloaderProvider = Provider<ContentPreloader>(
  ContentPreloader.new,
);
