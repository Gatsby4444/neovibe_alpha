import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/models/card.dart';
import '../../core/models/library_vibe.dart';
import '../../core/supabase_providers.dart';
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
/// 2. **Le scellé.** Le média original chiffré en AES-GCM avec une clé
///    aléatoire, confiée au serveur qui la retient jusqu'au reveal.
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

  final _algorithm = AesGcm.with256bits();

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
    final id = _uuid();

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
    // La MÊME clé chiffre les deux faces : AES-GCM tire un nonce aléatoire à
    // chaque appel, donc deux fichiers distincts restent sûrs.
    final secretKey = await _algorithm.newSecretKey();
    final sealed = await _seal(source, secretKey);
    final placeholderBack = back == null
        ? null
        : await _makePlaceholder(back, isVideo: backIsVideo);
    final sealedBack = back == null ? null : await _seal(back, secretKey);

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
          'p_media_key': base64Encode(await secretKey.extractBytes()),
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

  /// Ouvre une vibe révélée : réclame la clé, déchiffre, écrit le résultat dans
  /// un fichier temporaire utilisable par un lecteur d'image ou de vidéo.
  ///
  /// Lève si le reveal n'a pas eu lieu — le refus vient du **serveur**, pas
  /// d'une vérification locale qu'un client modifié pourrait contourner.
  ///
  /// [sealedBytes] : les octets déjà préchargés, pour éviter un second
  /// téléchargement. Ils sont récupérés si absents.
  Future<File> openRevealed(
    LibraryVibe vibe, {
    Uint8List? sealedBytes,
    required String extension,
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
      final clear = await _unseal(bytes, key as String);

      final dir = await getTemporaryDirectory();
      final suffix = back ? '_back' : '';
      final file = File('${dir.path}/vibe_${vibe.id}$suffix.$extension');
      await file.writeAsBytes(clear, flush: true);
      AppLog.instance.app('Vibe déchiffrée', '${clear.length} o · $extension');
      return file;
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

  /// Chiffre un média en AES-256-GCM.
  ///
  /// Le nonce et le MAC voyagent avec le chiffré (`concatenation`) : c'est la
  /// clé, et elle seule, qui est retenue par le serveur. La clé est fournie par
  /// l'appelant pour que les deux faces d'une même vibe la partagent.
  Future<Uint8List> _seal(File source, SecretKey secretKey) async {
    final box = await _algorithm.encrypt(
      await source.readAsBytes(),
      secretKey: secretKey,
    );
    return Uint8List.fromList(box.concatenation());
  }

  Future<List<int>> _unseal(Uint8List sealed, String keyBase64) async {
    final box = SecretBox.fromConcatenation(
      sealed,
      nonceLength: 12,
      macLength: 16,
    );
    return _algorithm.decrypt(
      box,
      secretKey: SecretKey(base64Decode(keyBase64)),
    );
  }

  // ─── Divers ─────────────────────────────────────────────────────────────

  /// UUID v4, sans dépendance supplémentaire (le paquet `uuid` n'est pas au
  /// pubspec, et un seul appel ne justifie pas de l'ajouter).
  String _uuid() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int from, int to) => bytes
        .sublist(from, to)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
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
