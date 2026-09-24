import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/crypto/chunked_seal.dart';
import '../../core/crypto/media_open.dart';
import '../../core/diagnostics/app_log.dart';
import '../../core/media/face_delivery.dart';
import '../../core/models/card.dart';
import '../../core/models/library_vibe.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/ids.dart';
import '../conversations/conversations_repository.dart';
import '../cards/card_media_cache.dart';
import 'library_vault_cache.dart';
import '../../core/work_dir.dart';

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
    String? challengeId,
    String? title,
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
          'p_challenge_id': challengeId,
          // Rogné et borné par le serveur, qui est seul juge.
          'p_title': title,
        },
      );
      final vibe = LibraryVibe.fromJson(Map<String, dynamic>.from(row as Map));
      AppLog.instance.server(
        'Vibe enregistrée',
        'vibe=${vibe.id} · reveal=${vibe.revealAt.toLocal()}',
      );
      // Le serveur a posé l'annonce « X a ajouté une vibe » dans le fil :
      // c'est une participation, les lecteurs de l'activité relisent.
      noteConversationActivity(ref);
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

  // ─── Les clés en lot, et la vignette nette (option A, 2026-09-24) ─────
  //
  // Jay : des vignettes nettes et une Vibe qui s'ouvre sans attendre, SANS
  // renoncer au chiffrement. Le temps perdu était l'aller-retour « une clé par
  // Vibe », pas le déchiffrement (~2 ms pour une photo, en natif).
  //
  // ⚠️ **Rien n'est écrit en clair.** Les clés vivent en MÉMOIRE, le temps de
  // la session et de ce compte (le dépôt est recréé à chaque changement de
  // compte) ; les photos déchiffrées aussi, dans un petit cache borné. Le
  // disque ne porte que le scellé (`LibraryVaultCache`).

  /// Les clés déjà obtenues, par Vibe.
  final _keys = <String, String>{};

  /// Un seul lot en vol par Drop : vingt tuiles qui demandent en même temps
  /// posent UNE question au serveur.
  final _batches = <String, Future<void>>{};

  /// Les photos déchiffrées récemment (vignettes et ouverture), bornées.
  final _photos = <String, Uint8List>{};
  static const _photoCacheMax = 48;

  /// Toutes les clés lisibles d'un Drop, en un appel (`drop_keys` : même
  /// règle que `get_library_vibe_key` — membre, et révélée).
  Future<void> _loadDropKeys(String conversationId) =>
      _batches[conversationId] ??= () async {
        try {
          final rows =
              await _client.rpc(
                    'drop_keys',
                    params: {'p_conversation_id': conversationId},
                  )
                  as List;
          for (final r in rows) {
            final m = r as Map;
            _keys[m['vibe_id'] as String] = m['media_key'] as String;
          }
        } finally {
          // Le lot suivant (une Vibe arrivée depuis) repartira.
          unawaited(Future(() => _batches.remove(conversationId)));
        }
      }();

  /// La clé d'une Vibe : en mémoire, sinon par le lot de son Drop, sinon à
  /// l'unité (qui porte le refus « pas encore révélée »).
  Future<String> _keyFor(LibraryVibe vibe) async {
    final known = _keys[vibe.id];
    if (known != null) return known;
    try {
      await _loadDropKeys(vibe.conversationId);
    } catch (_) {
      // Le lot a échoué : l'appel à l'unité dira pourquoi.
    }
    final batched = _keys[vibe.id];
    if (batched != null) return batched;
    final single =
        await _client.rpc(
              'get_library_vibe_key',
              params: {'p_vibe_id': vibe.id},
            )
            as String;
    return _keys[vibe.id] = single;
  }

  /// **La vignette nette** d'une Vibe révélée : sa photo, déchiffrée en
  /// mémoire à partir du scellé déjà téléchargé. `null` pour une vidéo (pas
  /// d'image à extraire sans la lire) ou une Vibe pas encore révélée — la
  /// tuile garde alors son aperçu flouté.
  Future<Uint8List?> sharpPhoto(LibraryVibe vibe) async {
    if (vibe.frontIsVideo || !vibe.revealedMaintenant) return null;
    final hit = _photos.remove(vibe.id);
    if (hit != null) return _photos[vibe.id] = hit;
    try {
      final (key, sealed) = await (_keyFor(vibe), cacheFace(vibe)).wait;
      final media = await MediaOpen.open(
        sealed,
        key,
        isVideo: false,
        cacheId: vibe.id,
      );
      final bytes = media.photoBytes;
      if (bytes == null) return null;
      _photos[vibe.id] = bytes;
      while (_photos.length > _photoCacheMax) {
        _photos.remove(_photos.keys.first);
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Le placeholder d'une face, lisible à tout moment.
  Future<Uint8List> placeholderBytes(LibraryVibe vibe, {bool back = false}) {
    final path = back ? vibe.placeholderBackPath : vibe.placeholderPath;
    if (path == null) throw StateError('Cette vibe n\'a pas de verso');
    return _client.storage.from(_bucket).download(path);
  }

  /// Amène le scellé d'une face **sur l'appareil**, et rend le fichier.
  ///
  /// Sans effet s'il y est déjà — c'est ce qui rend l'appel répétable sans
  /// précaution depuis n'importe quel écran.
  ///
  /// À appeler dès [LibraryVibe.prefetchable]. Les octets arrivent avant
  /// l'heure et restent **illisibles** sans la clé, que seul le serveur rendra
  /// au reveal.
  ///
  /// Lève tant que le serveur n'ouvre pas : la politique du coffre exige
  /// `now() >= reveal_at - 5 min`. C'est voulu, et l'appelant réessaiera.
  Future<File> cacheFace(LibraryVibe vibe, {bool back = false}) async {
    final path = back ? vibe.sealedBackPath : vibe.sealedPath;
    if (path == null) throw StateError('Cette vibe n\'a pas de verso');
    final cache = ref.read(libraryVaultCacheProvider);

    final cached = await cache.tryFace(vibe.id, front: !back);
    if (cached != null) return cached;

    final bytes = await _client.storage.from(_bucket).download(path);
    return cache.store(vibe.id, bytes, front: !back);
  }

  /// Précharge les **deux** faces, sans jamais lever.
  ///
  /// ⚠️ Le verso comptait autant que le recto et n'était pourtant pas
  /// préchargé jusqu'au 2026-08-13 : le retournement, juste après le reveal,
  /// déclenchait donc un téléchargement complet en pleine lecture — le seul
  /// moment où l'utilisateur regarde vraiment.
  ///
  /// N'échoue jamais : un préchargement raté n'est pas une panne, c'est une
  /// préparation qui n'a pas eu lieu, et l'ouverture retombera sur le
  /// téléchargement direct.
  Future<void> prefetch(LibraryVibe vibe) async {
    if (!vibe.prefetchableMaintenant) return;
    try {
      await cacheFace(vibe);
      if (vibe.hasBack) await cacheFace(vibe, back: true);
    } catch (_) {
      // Réessayé au prochain affichage de la tuile.
    }
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
  /// ### Le scellé vient du cache local, pas du réseau
  ///
  /// [cacheFace] l'a normalement amené dans les 5 minutes qui précèdent le
  /// reveal. L'ouverture ne fait alors que **lire un fichier déjà là** — c'est
  /// la conception voulue par Jay : « comme si les cards étaient toujours là
  /// mais qu'elles étaient juste bloquées en local ».
  ///
  /// Le téléchargement reste le **repli** — première ouverture d'une vibe que
  /// l'écran n'a jamais affichée, cache évincé, préchargement échoué.
  ///
  /// ⚠️ Ce qui ne changera PAS : la clé vient de `get_library_vibe_key`, qui
  /// porte sa propre règle (le reveal). Le transport se mutualise, **la
  /// politique de clé reste distincte** — règle 2 de `CLAUDE.md`.
  Future<OpenedMedia> openRevealed(
    LibraryVibe vibe, {
    required bool isVideo,
    bool back = false,
  }) async {
    AppLog.instance.action(
      'Ouverture d\'une vibe révélée',
      'vibe=${vibe.id} · face=${back ? 'verso' : 'recto'}',
    );
    try {
      // Les deux partent ENSEMBLE : la clé vient du serveur, le scellé du
      // disque (ou du réseau en repli). Rien ne les lie, et les enchaîner
      // ajouterait un aller-retour à chaque ouverture — leçon du chantier
      // livraison, 2026-08-13.
      final cachedBefore =
          await ref
              .read(libraryVaultCacheProvider)
              .tryFace(vibe.id, front: !back) !=
          null;
      // La clé vient de la mémoire (lot du Drop) quand elle y est : plus
      // d'aller-retour à l'ouverture (option A, 2026-09-24).
      final (key, sealedFile) = await (
        _keyFor(vibe),
        cacheFace(vibe, back: back),
      ).wait;

      AppLog.instance.server(
        'Clé obtenue',
        'vibe=${vibe.id} · scellé déjà local=$cachedBefore',
      );

      // Le fichier ouvert est le SCELLÉ — du chiffré, illisible sans la clé.
      // Le clair, lui, n'apparaît nulle part sur le disque.
      final media = await MediaOpen.open(
        sealedFile,
        key,
        isVideo: isVideo,
        cacheId: '${vibe.id}${back ? '_back' : ''}',
      );
      AppLog.instance.app(
        'Vibe ouverte',
        '${await sealedFile.length()} o scellés · '
            '${isVideo ? 'vidéo' : 'photo'}',
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
    final dir = await WorkDir.named('seal');
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

/// Recréé à chaque changement de compte : les clés et les photos en mémoire
/// appartiennent au compte qui les a obtenues.
final libraryVibesRepositoryProvider = Provider((ref) {
  ref.watch(currentUserIdProvider);
  return LibraryVibesRepository(ref);
});

/// Les vibes d'une conversation. Rafraîchi par `ref.invalidate` après un ajout
/// ou au passage du reveal.
final conversationLibraryProvider =
    FutureProvider.family<List<LibraryVibe>, String>(
      (ref, conversationId) =>
          ref.watch(libraryVibesRepositoryProvider).vibesOf(conversationId),
    );

/// **Le Drop en direct** (2026-09-24) : tant que quelqu'un l'observe, une
/// Vibe ajoutée par N'IMPORTE QUI relit le Drop — sans tirer pour rafraîchir.
///
/// ⚠️ **On écoute les messages, pas `library_vibes`.** Chaque ajout pose un
/// message `library_add` dans la conversation (`add_vibe_to_library`) ; la
/// table des messages est déjà diffusée, et sa politique ne la livre qu'aux
/// membres. Diffuser aussi `library_vibes` donnerait deux signaux pour un même
/// fait.
///
/// C'est une ACQUISITION : elle constate « le Drop a changé » et relit ; elle
/// ne dessine rien. `autoDispose` : l'écoute s'arrête quand plus aucun écran
/// ne regarde ce Drop.
final conversationLibraryLiveProvider = Provider.autoDispose
    .family<void, String>((ref, conversationId) {
      ref.watch(realtimeEpochProvider);
      final client = ref.watch(supabaseProvider);
      final channel = client.channel('drop:$conversationId')
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (payload) {
            if (payload.newRecord['kind'] == 'library_add') {
              ref.invalidate(conversationLibraryProvider(conversationId));
            }
          },
        )
        ..subscribe();
      ref.onDispose(() => client.removeChannel(channel));
    });
