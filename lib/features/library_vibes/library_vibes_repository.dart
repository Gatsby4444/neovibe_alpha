import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/crypto/chunked_seal.dart';
import '../../core/crypto/media_open.dart';
import '../../core/diagnostics/app_log.dart';
import '../../core/media/face_delivery.dart';
import '../../core/models/card.dart';
import '../../core/models/library_vibe.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/ids.dart';
import '../cards/card_media_cache.dart';

/// Bibliothèques éphémères de conversation — couche d'accès.
///
/// Spécification : `docs/bibliotheques-ephemeres.md`.
///
/// Deux pièces sensibles vivent ici :
///
/// 1. **Le placeholder.** L'image est réduite à [_placeholderWidth] pixels de
///    large. C'est la réduction, et elle seule, qui protège : elle **détruit**
///    l'information au lieu de la brouiller, là où un flou gaussien est une
///    convolution partiellement réversible.
///    Le flou visible à l'écran est un pur habillage, appliqué au rendu par
///    `MaskedPlaceholder` — il n'a aucun rôle de sécurité, et flouter une image
///    déjà détruite n'y réinjecte rien.
/// 2. **Le scellé.** Le média original scellé au format PAR BLOCS (`NVC1`),
///    le même que partout ailleurs, avec une clé aléatoire confiée au serveur
///    qui la retient jusqu'au reveal. Depuis le 2026-08-13 : le lecteur natif
///    sait donc le lire, et **plus aucun clair n'est écrit sur le disque**.
///
/// C'est le client qui fait les deux, parce qu'il possède déjà l'original —
/// il vient de le capturer. Le serveur ne traite aucune image ; sa seule
/// fonction de sécurité est de **retenir la clé**.
///
/// ⚠️ Limite assumée, à ne pas oublier en relisant ce fichier : pour l'AUTEUR,
/// « ne pas voir ses propres ajouts » est une promesse d'INTERFACE. L'image est
/// passée par son appareil et c'est son client qui a fabriqué la clé — aucune
/// cryptographie ne peut la lui cacher. Pour tous les autres membres, la
/// barrière est réelle.
class LibraryVibesRepository {
  LibraryVibesRepository(this.ref);
  final Ref ref;

  SupabaseClient get _client => ref.read(supabaseProvider);

  /// Largeur du placeholder. 20 px : assez pour rendre une ambiance de
  /// couleurs, très loin d'un sujet reconnaissable.
  static const _placeholderWidth = 20;

  static const _bucket = 'library_vault';

  // ─── Écriture ───────────────────────────────────────────────────────────

  /// Ajoute une vibe à la bibliothèque d'une conversation.
  ///
  /// [source] est le fichier de la face à masquer — la photo, ou la vidéo. Pour
  /// une vidéo, le placeholder est tiré de son image de couverture : flouter la
  /// vidéo elle-même imposerait un ré-encodage, hors de question sur l'appareil.
  /// ⚠️ Aucune ligne `cards` n'est créée, et **rien ne part dans le bucket
  /// `cards`** — décision de Jay du 2026-08-10. Une vibe de bibliothèque et une
  /// vibe envoyée sont deux objets distincts, avec des règles d'accès
  /// distinctes : l'une par appartenance à la conversation, l'autre par
  /// livraison nominative. En conséquence, **il n'existe nulle part d'original
  /// en clair** pour une vibe de bibliothèque.
  Future<LibraryVibe> addVibe({
    required String conversationId,
    required CardType type,
    required File source,
    required bool isVideo,
    File? back,
    bool backIsVideo = false,
    bool saveableByOthers = false,
    bool ephemeral = false,
  }) async {
    final me = _client.auth.currentUser!.id;
    // L'identifiant est fabriqué ICI : il nomme les fichiers dans le coffre,
    // et il faut donc le connaître avant de les déposer.
    final id = newUuid();

    final placeholderPath = '$me/$id/placeholder.png';
    final sealedPath = '$me/$id/sealed.bin';
    final placeholderBackPath = back == null
        ? null
        : '$me/$id/placeholder_back.png';
    final sealedBackPath = back == null ? null : '$me/$id/sealed_back.bin';

    AppLog.instance.action(
      'Ajout d\'une vibe à la bibliothèque',
      'conversation=$conversationId · vidéo=$isVideo · verso=${back != null} · '
          'sauvegardable=$saveableByOthers · éphémère=$ephemeral',
    );

    final started = DateTime.now();
    final placeholder = await _makePlaceholder(source, isVideo: isVideo);
    // La MÊME clé chiffre les deux faces : chaque bloc tire son propre nonce,
    // donc deux fichiers distincts restent sûrs.
    final key = await ChunkedSeal.newKey();
    final sealed = await _sealToBytes(source, key, isVideo: isVideo);
    final placeholderBack = back == null
        ? null
        : await _makePlaceholder(back, isVideo: backIsVideo);
    final sealedBack = back == null
        ? null
        : await _sealToBytes(back, key, isVideo: backIsVideo);

    AppLog.instance.app(
      'Vibe préparée',
      'placeholder=${placeholder.length} o · scellé=${sealed.length} o · '
          'verso=${sealedBack?.length ?? 0} o · '
          '${DateTime.now().difference(started).inMilliseconds} ms',
    );

    Future<void> put(String path, Uint8List bytes, String type) => _client
        .storage
        .from(_bucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: type));

    await put(placeholderPath, placeholder, 'image/png');
    await put(sealedPath, sealed, 'application/octet-stream');
    if (back != null) {
      await put(placeholderBackPath!, placeholderBack!, 'image/png');
      await put(sealedBackPath!, sealedBack!, 'application/octet-stream');
    }

    AppLog.instance.server('Fichiers déposés dans library_vault', 'vibe=$id');

    // C'est cet appel qui calcule le reveal, range la clé hors de portée et
    // poste l'annonce nommée dans le fil.
    //
    // ⚠️ La clé n'est JAMAIS journalisée : le journal est fait pour être
    // copié-collé, y inscrire une clé annulerait tout le mécanisme.
    try {
      final row = await _client.rpc(
        'add_vibe_to_library',
        params: {
          'p_id': id,
          'p_conversation_id': conversationId,
          'p_placeholder_path': placeholderPath,
          'p_sealed_path': sealedPath,
          'p_media_key': key,
          'p_card_type': type.dbValue,
          'p_front_is_video': isVideo,
          'p_back_is_video': backIsVideo,
          'p_saveable_by_others': saveableByOthers,
          'p_ephemeral': ephemeral,
          'p_placeholder_back_path': placeholderBackPath,
          'p_sealed_back_path': sealedBackPath,
        },
      );
      final vibe = LibraryVibe.fromJson(Map<String, dynamic>.from(row as Map));
      AppLog.instance.server(
        'Vibe enregistrée',
        'vibe=${vibe.id} · reveal=${vibe.revealAt.toLocal()}',
      );
      return vibe;
    } catch (e) {
      AppLog.instance.error('add_vibe_to_library a échoué', '$e');
      rethrow;
    }
  }

  // ─── Lecture ────────────────────────────────────────────────────────────

  /// Les vibes d'une conversation, la plus récente d'abord. La ligne est
  /// visible dès l'ajout (qui a déposé, combien, quand ça se révèle) ; c'est le
  /// CONTENU qui ne l'est pas.
  Future<List<LibraryVibe>> vibesOf(String conversationId) async {
    // Plus de jointure sur `cards` : la table porte désormais tout ce dont
    // l'affichage a besoin.
    final rows = await _client
        .from('library_vibes')
        .select()
        .eq('conversation_id', conversationId)
        .order('reveal_at', ascending: false);
    return rows
        .map((r) => LibraryVibe.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  /// Le placeholder d'une face, lisible à tout moment.
  Future<Uint8List> placeholderBytes(LibraryVibe vibe, {bool back = false}) {
    final path = back ? vibe.placeholderBackPath : vibe.placeholderPath;
    if (path == null) throw StateError('Cette vibe n\'a pas de verso');
    return _client.storage.from(_bucket).download(path);
  }

  /// Précharge les octets scellés. À appeler dès [LibraryVibe.prefetchable] :
  /// ils arrivent avant l'heure pour que le reveal ne soit pas un temps de
  /// chargement, et ils restent **illisibles** sans la clé.
  ///
  /// Échoue tant que le serveur n'ouvre pas (politique de storage) : c'est
  /// voulu, l'appelant réessaiera.
  Future<Uint8List> prefetchSealed(LibraryVibe vibe, {bool back = false}) {
    final path = back ? vibe.sealedBackPath : vibe.sealedPath;
    if (path == null) throw StateError('Cette vibe n\'a pas de verso');
    return _client.storage.from(_bucket).download(path);
  }

  /// Ouvre une vibe révélée : réclame la clé, puis rend un [OpenedMedia] prêt
  /// à l'affichage.
  ///
  /// Lève si le reveal n'a pas eu lieu — le refus vient du **serveur**, pas
  /// d'une vérification locale qu'un client modifié pourrait contourner.
  ///
  /// ### Ce qui a changé le 2026-08-13
  ///
  /// Cette méthode déchiffrait en Dart et **écrivait le clair sur le disque**
  /// (`vibe_<id>.<ext>`). Elle passe désormais par [MediaOpen], comme les trois
  /// autres chemins média : une **photo** arrive en mémoire, une **vidéo** est
  /// lue bloc par bloc par le lecteur natif, qui déchiffre sur ses propres
  /// fils. **Plus rien n'est écrit en clair.**
  ///
  /// Effet de bord qui n'en est pas un : une vibe **vidéo** s'affiche
  /// désormais. Les deux écrans faisaient `Image.file` sur un `.mp4` — une
  /// vidéo en bibliothèque de conversation ne pouvait pas s'afficher, et
  /// personne ne l'avait relevé faute de mesure sur ce chemin.
  ///
  /// ⚠️ Ce qui n'a PAS changé : le fichier scellé est toujours téléchargé
  /// **en entier** avant l'ouverture. La lecture par intervalles réclamerait
  /// une URL signée sur `library_vault` et un cache dédié — chantier distinct
  /// (`RAPPELS.md`, décisions #24).
  ///
  /// ⚠️ Ce qui ne changera PAS : la clé vient de `get_library_vibe_key`, qui
  /// porte sa propre règle (le reveal). Le transport se mutualise, **la
  /// politique de clé reste distincte** — règle 2 de `CLAUDE.md`.
  ///
  /// [sealedBytes] : les octets déjà préchargés, pour éviter un second
  /// téléchargement. Ils sont récupérés si absents.
  Future<OpenedMedia> openRevealed(
    LibraryVibe vibe, {
    Uint8List? sealedBytes,
    required bool isVideo,
    bool back = false,
  }) async {
    AppLog.instance.action(
      'Ouverture d\'une vibe révélée',
      'vibe=${vibe.id} · face=${back ? 'verso' : 'recto'}',
    );
    try {
      final key = await _client.rpc(
        'get_library_vibe_key',
        params: {'p_vibe_id': vibe.id},
      );
      AppLog.instance.server(
        'Clé obtenue',
        'vibe=${vibe.id} · préchargé=${sealedBytes != null}',
      );

      final bytes = sealedBytes ?? await prefetchSealed(vibe, back: back);

      // Le SCELLÉ est posé sur le disque — c'est du chiffré, illisible sans la
      // clé — et c'est lui que le lecteur natif ouvrira. Le clair, lui, n'y
      // apparaît jamais.
      final dir = await getTemporaryDirectory();
      final suffix = back ? '_back' : '';
      final sealedFile = File('${dir.path}/vault_${vibe.id}$suffix.bin');
      await sealedFile.writeAsBytes(bytes, flush: true);

      final media = await MediaOpen.open(
        sealedFile,
        key as String,
        isVideo: isVideo,
        cacheId: '${vibe.id}$suffix',
      );
      AppLog.instance.app(
        'Vibe ouverte',
        '${bytes.length} o scellés · ${isVideo ? 'vidéo' : 'photo'}',
      );
      return media;
    } catch (e) {
      // Le refus AVANT l'heure est un fonctionnement NORMAL, pas une panne :
      // il est journalisé comme tel pour ne pas polluer la recherche de bugs.
      final refused = '$e'.contains('reveal');
      if (refused) {
        AppLog.instance.server(
          'Clé refusée — reveal non atteint',
          'vibe=${vibe.id}',
        );
      } else {
        AppLog.instance.error('Ouverture de vibe en échec', '$e');
      }
      rethrow;
    }
  }

  // ─── Placeholder ────────────────────────────────────────────────────────

  /// Réduit l'image à [_placeholderWidth] px de large et l'encode en PNG.
  ///
  /// `instantiateImageCodec` fait le redimensionnement pendant le DÉCODAGE :
  /// l'image pleine résolution n'est jamais montée en mémoire, et le résultat
  /// ne contient physiquement plus l'information d'origine.
  Future<Uint8List> _makePlaceholder(
    File source, {
    required bool isVideo,
  }) async {
    var image = source;
    if (isVideo) {
      // Une vidéo ne se décode pas comme une image : on part de sa couverture,
      // extraite en natif (le même chemin que les vignettes de bibliothèque).
      final cover = await ref.read(cardMediaCacheProvider).videoThumb(source);
      if (cover == null) {
        // Sans couverture, pas de placeholder représentatif : un PNG gris
        // uniforme vaut mieux qu'un échec de l'ajout.
        return _flatPlaceholder();
      }
      image = cover;
    }

    final codec = await ui.instantiateImageCodec(
      await image.readAsBytes(),
      targetWidth: _placeholderWidth,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    if (data == null) return _flatPlaceholder();
    return data.buffer.asUint8List();
  }

  /// Repli : un carré gris uni, encodé en PNG.
  Future<Uint8List> _flatPlaceholder() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 20, 20),
      ui.Paint()..color = const ui.Color(0xFF9E9E9E),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(20, 20);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  }

  // ─── Scellé ─────────────────────────────────────────────────────────────

  /// Scelle un média au format **par blocs** (`NVC1`), le même que partout
  /// ailleurs dans l'app, et rend les octets prêts à téléverser.
  ///
  /// ### Pourquoi ce chemin a changé le 2026-08-13
  ///
  /// Il chiffrait en AES-GCM **d'un seul bloc** (`box.concatenation()`), un
  /// format que le lecteur natif ne sait pas lire. Conséquence en chaîne :
  /// pour afficher une vibe révélée il fallait tout déchiffrer en Dart, puis
  /// **écrire le clair dans un fichier temporaire**. Or « ce qui se passe sur
  /// NeoVibe reste sur NeoVibe » (voie produit du 2026-08-13) : un média
  /// déchiffré posé sur le disque est un manquement à cette promesse, pas un
  /// détail d'implémentation.
  ///
  /// Passer par [FaceDelivery] plutôt que d'appeler `ChunkedSeal` directement
  /// n'est pas cosmétique : c'est lui qui applique aussi `fastStart` sur une
  /// vidéo, et c'est le **passage obligé** dont l'existence même sert à ce
  /// qu'une préparation ne soit pas oubliée à un endroit sur quatre.
  Future<Uint8List> _sealToBytes(
    File source,
    String key, {
    required bool isVideo,
  }) async {
    final dir = await getTemporaryDirectory();
    final target = File('${dir.path}/vault_seal_${newUuid()}.bin');
    try {
      await FaceDelivery.seal(source, target, key, isVideo: isVideo);
      return await target.readAsBytes();
    } finally {
      // Le scellé transite par le disque le temps du téléversement — mais
      // c'est du CHIFFRÉ, et il ne survit pas à l'appel.
      try {
        if (target.existsSync()) await target.delete();
      } catch (_) {}
    }
  }
}

final libraryVibesRepositoryProvider = Provider(LibraryVibesRepository.new);

/// Les vibes d'une conversation. Rafraîchi par `ref.invalidate` après un ajout
/// ou au passage du reveal.
final conversationLibraryProvider =
    FutureProvider.family<List<LibraryVibe>, String>(
      (ref, conversationId) =>
          ref.watch(libraryVibesRepositoryProvider).vibesOf(conversationId),
    );
