import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../location/capture_places.dart';
import '../location/city_index.dart';
import '../models/card.dart';
import '../supabase_providers.dart';

/// Préfixe des identifiants de sauvegardes faites **avant** que le contenu
/// n'existe côté serveur (« Enregistrer pour moi » cliqué à l'envoi, 2026-08-14).
///
/// Il vit ici, avec le magasin qui doit le reconnaître, et non dans l'écran qui
/// le produit : c'est [SavedStore.purgeRevoked] qui a besoin de savoir qu'une
/// clé ne désigne aucun contenu serveur, et une constante posée chez celui qui
/// s'en sert ne peut pas dériver de celui qui la fabrique.
const localIdPrefix = 'local-';

/// **Quand, où, et de quelle soirée** — ce que la galerie montre d'une Vibe
/// (Jay, 2026-09-25 : *« des Vibes datées et localisées »*).
///
/// Tout est facultatif : une Vibe reçue d'un ami n'a pas de lieu (le sien ne
/// nous est pas partagé), une sauvegarde d'avant le 2026-09-25 n'a rien.
class SavedPlace {
  const SavedPlace({
    this.takenAt,
    this.lat,
    this.lon,
    this.placeName,
    this.eventId,
    this.eventTitle,
  });

  final DateTime? takenAt;
  final double? lat;
  final double? lon;

  /// Le nom du lieu posé par le créateur d'un événement (« Le Sucre »).
  final String? placeName;
  final String? eventId;
  final String? eventTitle;
}

/// Une sauvegarde : une copie **locale et en clair** d'un contenu.
///
/// Elle ne dépend plus de rien côté serveur. C'est le sens de la décision de
/// Jay (2026-08-11) : « pas d'espace serveur dédié ». Avant, `saved_cards`
/// était en `ON DELETE CASCADE` — si l'auteur supprimait sa Vibe, tous ceux
/// qui l'avaient enregistrée la perdaient, alors qu'« Enregistrer » promet de
/// garder.
class SavedItem {
  const SavedItem({
    required this.contentId,
    required this.cardType,
    required this.frontPath,
    required this.savedAt,
    required this.frontIsVideo,
    this.backPath,
    this.backIsVideo = false,
    this.authorName,
    this.mine = false,
    this.takenAt,
    this.lat,
    this.lon,
    this.city,
    this.placeName,
    this.eventId,
    this.eventTitle,
  });

  /// Content ID — ou identifiant de Card pour une Vibe reçue en chat.
  /// C'est par lui que la révocation retrouve une copie locale.
  final String contentId;
  final CardType cardType;

  /// Chemins **sur l'appareil**, pas dans un bucket.
  final String frontPath;
  final String? backPath;
  final bool frontIsVideo;
  final bool backIsVideo;
  final DateTime savedAt;
  final String? authorName;

  /// Mon propre contenu, par opposition à celui de quelqu'un d'autre.
  final bool mine;

  /// Quand la Vibe a été prise (ou postée, pour celle d'un autre) — nulle
  /// pour une sauvegarde d'avant le 2026-09-25 : on retombe sur [savedAt].
  final DateTime? takenAt;
  final double? lat;
  final double? lon;

  /// La ville, trouvée SUR le téléphone à l'enregistrement (`CityIndex`).
  final String? city;

  /// Le nom du lieu d'un événement (posé par son créateur).
  final String? placeName;
  final String? eventId;
  final String? eventTitle;

  bool get hasBack => backPath != null;

  /// La date que la galerie range et affiche.
  DateTime get when => takenAt ?? savedAt;

  /// Ce que la galerie écrit sous la Vibe : le lieu nommé, sinon la ville.
  String? get where => placeName ?? city;

  bool get fromEvent => eventId != null;

  Map<String, dynamic> toJson() => {
    'cardType': cardType.dbValue,
    'frontPath': frontPath,
    'backPath': backPath,
    'frontIsVideo': frontIsVideo,
    'backIsVideo': backIsVideo,
    'savedAt': savedAt.toIso8601String(),
    'authorName': authorName,
    'mine': mine,
    'takenAt': takenAt?.toIso8601String(),
    'lat': lat,
    'lon': lon,
    'city': city,
    'placeName': placeName,
    'eventId': eventId,
    'eventTitle': eventTitle,
  };

  factory SavedItem.fromJson(String id, Map<String, dynamic> j) => SavedItem(
    contentId: id,
    cardType: CardType.fromDb(j['cardType'] as String? ?? 'standard'),
    frontPath: j['frontPath'] as String,
    backPath: j['backPath'] as String?,
    frontIsVideo: j['frontIsVideo'] as bool? ?? false,
    backIsVideo: j['backIsVideo'] as bool? ?? false,
    savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime.now(),
    authorName: j['authorName'] as String?,
    mine: j['mine'] as bool? ?? false,
    takenAt: DateTime.tryParse(j['takenAt'] as String? ?? ''),
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    city: j['city'] as String?,
    placeName: j['placeName'] as String?,
    eventId: j['eventId'] as String?,
    eventTitle: j['eventTitle'] as String?,
  );
}

/// Les Enregistrements, **sur l'appareil**.
///
/// ⚠️ Contrairement à tous les autres caches de l'app, les fichiers y sont
/// **en clair**. C'est délibéré et c'est ce qui rend la sauvegarde
/// indépendante du serveur : plus aucune clé à demander pour les afficher.
///
/// Le revers, accepté par Jay en connaissance de cause : la révocation devient
/// **coopérative**. Le serveur demande, l'app obéit — un client modifié peut
/// l'ignorer. On ne promet donc jamais « révocation garantie » sur une
/// sauvegarde, seulement sur un contenu servi par le serveur.
class SavedStore {
  SavedStore(this.ref);
  final Ref ref;

  Directory? _root;
  Map<String, dynamic>? _index;

  Future<Directory> _dir() async {
    _root ??= await getApplicationSupportDirectory();
    final dir = Directory('${_root!.path}${Platform.pathSeparator}saved');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _indexFile() async =>
      File('${(await _dir()).path}${Platform.pathSeparator}index.json');

  Future<Map<String, dynamic>> _load() async {
    if (_index != null) return _index!;
    try {
      final f = await _indexFile();
      _index = await f.exists()
          ? jsonDecode(await f.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      _index = <String, dynamic>{};
    }
    return _index!;
  }

  /// Écrit l'index — et **le dit**. L'invalidation appartient à l'écriture
  /// (2026-08-25) : tout lecteur voit une sauvegarde dès qu'elle existe, quel
  /// que soit le bouton ou l'écran qui l'a demandée. Avant le 2026-09-18,
  /// chaque appelant invalidait lui-même, et l'un d'eux l'oubliait forcément.
  Future<void> _save() async {
    if (_index == null) return;
    try {
      await (await _indexFile()).writeAsString(jsonEncode(_index));
    } catch (_) {}
    ref.read(savedIndexVersionProvider.notifier).bump();
  }

  Future<List<SavedItem>> all() async {
    final index = await _load();
    final list = index.entries
        .map(
          (e) => SavedItem.fromJson(
            e.key,
            (e.value as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
    // Le plus récemment PRIS d'abord (2026-09-25) ; à défaut, enregistré.
    list.sort((a, b) => b.when.compareTo(a.when));
    return list;
  }

  /// **Le seul endroit qui date et situe une sauvegarde** (2026-09-25).
  ///
  /// Ce que l'appelant sait, sinon — pour MA Vibe — son lieu de prise dans
  /// le journal privé (`capture_places`) ; la ville se trouve sur le
  /// téléphone. Ne lève jamais : une sauvegarde sans lieu reste une
  /// sauvegarde.
  Future<({SavedPlace? place, String? city})> _resoudre(
    String contentId,
    bool mine,
    SavedPlace? place,
  ) async {
    var p = place;
    try {
      if (p == null && mine && !contentId.startsWith(localIdPrefix)) {
        final stamp = await ref.read(capturePlacesProvider).of(contentId);
        if (stamp != null) {
          p = SavedPlace(
            takenAt: stamp.takenAt,
            lat: stamp.anchor?.lat,
            lon: stamp.anchor?.lng,
          );
        }
      }
      final lat = p?.lat;
      final lon = p?.lon;
      final city = lat == null || lon == null
          ? null
          : (await ref.read(cityIndexProvider.future)).nearest(lat, lon);
      return (place: p, city: city);
    } catch (_) {
      return (place: p, city: null);
    }
  }

  /// Complète la date, le lieu et la soirée d'une sauvegarde qui n'en a pas
  /// — les Vibes de soirée gardées avant le 2026-09-25. Ne touche à rien de
  /// ce qui est déjà là.
  Future<void> annotate(String contentId, SavedPlace place) async {
    final index = await _load();
    final raw = (index[contentId] as Map?)?.cast<String, dynamic>();
    if (raw == null || raw['eventId'] != null) return;
    final lieu = await _resoudre(contentId, false, place);
    raw
      ..['takenAt'] ??= place.takenAt?.toIso8601String()
      ..['lat'] ??= place.lat
      ..['lon'] ??= place.lon
      ..['city'] ??= lieu.city
      ..['placeName'] ??= place.placeName
      ..['eventId'] = place.eventId
      ..['eventTitle'] ??= place.eventTitle;
    index[contentId] = raw;
    await _save();
  }

  Future<bool> isSaved(String contentId) async =>
      (await _load()).containsKey(contentId);

  /// Écrit les faces en clair dans l'espace des Enregistrements.
  ///
  /// L'appelant fournit de quoi ÉCRIRE, pas un fichier déjà en clair : depuis
  /// le format par blocs, l'affichage ne produit plus de clair sur le disque.
  /// Le clair est donc régénéré ici, en flux — une vidéo de 28 Mo n'est jamais
  /// montée en mémoire. Aucun téléchargement, aucune clé à redemander : les
  /// octets scellés sont déjà sur l'appareil.
  Future<void> add({
    required String contentId,
    required CardType cardType,
    required Future<void> Function(File target) writeFront,
    Future<void> Function(File target)? writeBack,
    bool frontIsVideo = false,
    bool backIsVideo = false,
    String? authorName,
    bool mine = false,
    SavedPlace? place,
  }) async {
    // Le bouton se remplit à l'appui, pas à la fin de l'écriture : c'est ici
    // que « en cours » commence, et c'est le magasin qui le dit — pas chaque
    // bouton pour lui-même, sinon celui du fil et celui du plein écran
    // pourraient se contredire sur le même contenu.
    ref.read(savingIdsProvider.notifier).start(contentId);
    try {
      final dir = await _dir();
      String ext(bool v) => v ? 'mp4' : 'jpg';
      final frontPath =
          '${dir.path}${Platform.pathSeparator}${contentId}_front.${ext(frontIsVideo)}';
      await writeFront(File(frontPath));
      String? backPath;
      if (writeBack != null) {
        backPath =
            '${dir.path}${Platform.pathSeparator}${contentId}_back.${ext(backIsVideo)}';
        await writeBack(File(backPath));
      }

      final lieu = await _resoudre(contentId, mine, place);
      final index = await _load();
      index[contentId] = SavedItem(
        contentId: contentId,
        cardType: cardType,
        frontPath: frontPath,
        backPath: backPath,
        frontIsVideo: frontIsVideo,
        backIsVideo: backIsVideo,
        savedAt: DateTime.now(),
        authorName: authorName,
        mine: mine,
        takenAt: lieu.place?.takenAt,
        lat: lieu.place?.lat,
        lon: lieu.place?.lon,
        city: lieu.city,
        placeName: lieu.place?.placeName,
        eventId: lieu.place?.eventId,
        eventTitle: lieu.place?.eventTitle,
      ).toJson();
      await _save();
    } finally {
      ref.read(savingIdsProvider.notifier).end(contentId);
    }
  }

  /// Rebaptise une sauvegarde faite AVANT que le contenu n'existe côté serveur.
  ///
  /// « Enregistrer pour moi » est un bouton qui agit tout de suite (consigne
  /// Jay 2026-08-14) : la copie est écrite sous un identifiant local, bien
  /// avant l'envoi. Une fois le contenu créé, il faut lui rendre son vrai
  /// Content ID — c'est par lui, et seulement par lui, que [purgeRevoked]
  /// retrouve une copie révoquée par la modération. Sans ce recollage, une
  /// sauvegarde anticipée deviendrait **injoignable** pour la révocation.
  ///
  /// Les fichiers ne bougent pas : l'index porte des chemins absolus, pas des
  /// noms déduits de la clé. Renommer sur disque n'apporterait rien et
  /// ouvrirait une fenêtre où l'index désigne un fichier qui n'existe plus.
  Future<void> rekey(String localId, String contentId) async {
    if (localId == contentId) return;
    final index = await _load();
    final meta = index.remove(localId);
    if (meta == null) return;
    index[contentId] = meta;
    await _save();
  }

  Future<void> remove(String contentId) async {
    final index = await _load();
    final meta = index.remove(contentId);
    if (meta == null) return;
    for (final key in const ['frontPath', 'backPath']) {
      final path = (meta as Map)[key] as String?;
      if (path == null) continue;
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await _save();
  }

  /// Demande au serveur lesquels de mes contenus sauvegardés ont été
  /// **révoqués**, et supprime ceux-là.
  ///
  /// ⚠️ La RPC ne renvoie QUE les contenus révoqués — jamais ceux qui ont
  /// simplement disparu. C'est toute la différence avec l'ancien
  /// `ON DELETE CASCADE` : l'auteur qui supprime son contenu ne reprend pas ce
  /// que d'autres ont gardé. Seule la modération le peut.
  ///
  /// ⚠️ **Les sauvegardes encore locales sont écartées de la question.** Depuis
  /// que « Enregistrer pour moi » agit avant l'envoi (2026-08-14), l'index peut
  /// contenir des clés `local-…` qui ne désignent aucun contenu serveur. Les
  /// envoyer telles quelles ferait échouer le cast en `uuid[]` de la RPC — et
  /// comme l'échec est avalé plus bas, **une seule** clé locale suffirait à
  /// suspendre la purge de TOUTES les autres, en silence.
  Future<int> purgeRevoked() async {
    try {
      final index = await _load();
      final known = index.keys
          .where((id) => !id.startsWith(localIdPrefix))
          .toList();
      if (known.isEmpty) return 0;
      final rows = await ref
          .read(supabaseProvider)
          .rpc('revoked_contents', params: {'p_ids': known});
      var n = 0;
      for (final id in (rows as List)) {
        await remove(id as String);
        n++;
      }
      return n;
    } catch (_) {
      // Hors ligne : on réessaiera au prochain démarrage. Une sauvegarde reste
      // lisible entre-temps — c'est le prix assumé du « local d'abord ».
      return 0;
    }
  }

  Future<int> usedBytes() async {
    var total = 0;
    await for (final e in (await _dir()).list()) {
      if (e is File) total += (await e.stat()).size;
    }
    return total;
  }

  Future<void> clear() async {
    await for (final e in (await _dir()).list()) {
      try {
        await e.delete();
      } catch (_) {}
    }
    _index = <String, dynamic>{};
  }
}

final savedStoreProvider = Provider(SavedStore.new);

/// **La version de l'index** : un compteur que le magasin incrémente à chaque
/// écriture. Les lecteurs ci-dessous l'observent — c'est par lui, et par lui
/// seul, qu'ils apprennent qu'une sauvegarde est apparue ou a disparu.
///
/// Pourquoi pas `ref.invalidate` depuis le magasin ? Parce que ces lecteurs
/// dépendent du magasin : un magasin qui invalide ce qui dépend de lui est
/// une dépendance circulaire, et Riverpod la refuse. Le magasin ne connaît
/// donc pas ses lecteurs — il publie, ils écoutent.
class SavedIndexVersion extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final savedIndexVersionProvider = NotifierProvider<SavedIndexVersion, int>(
  SavedIndexVersion.new,
);

/// Les Enregistrements, pour l'écran qui les liste.
final savedItemsProvider = FutureProvider<List<SavedItem>>((ref) {
  ref.watch(savedIndexVersionProvider);
  return ref.watch(savedStoreProvider).all();
});

/// Ce contenu est-il déjà dans mes Enregistrements ?
final isSavedProvider = FutureProvider.family<bool, String>((ref, id) {
  ref.watch(savedIndexVersionProvider);
  return ref.watch(savedStoreProvider).isSaved(id);
});

/// Les contenus dont la sauvegarde est **en cours** — entre l'appui et la fin
/// de l'écriture du clair.
///
/// C'est ce qui rend le bouton instantané : il se remplit dès l'appui, sans
/// attendre que le fichier soit écrit (une vidéo de 36 Mo se déchiffre en
/// plusieurs secondes même au natif). Jay, 2026-09-18 : *« l'état du bouton
/// enregistrer attend de savoir si le contenu est vraiment enregistré […]
/// donc la sensation n'est pas instantanée »*.
class SavingIds extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void start(String id) => state = {...state, id};

  void end(String id) => state = {...state}..remove(id);
}

final savingIdsProvider = NotifierProvider<SavingIds, Set<String>>(
  SavingIds.new,
);

/// Les octets d'une photo enregistrée, lus **une fois**.
///
/// ⚠️ **Ajouté le 2026-08-25** (checkup `RAPPELS.md` #52). L'écran des
/// enregistrements faisait `FutureBuilder(future: File(path).readAsBytes())`
/// — la lecture était donc créée **dans `build()`**, et repartait à zéro à
/// chaque reconstruction du widget : une lecture disque par reconstruction, et
/// un retour visible au rond de chargement à chaque fois.
///
/// Rien n'affichait quoi que ce soit de faux, et c'est bien le problème : le
/// coût ne se voyait qu'en comptant les lectures.
///
/// Ici l'acquisition est nommée, mise en cache par Riverpod, et partagée par
/// tous les widgets qui montrent le même fichier.
final savedPhotoBytesProvider = FutureProvider.family<Uint8List, String>(
  (ref, path) => File(path).readAsBytes(),
);
