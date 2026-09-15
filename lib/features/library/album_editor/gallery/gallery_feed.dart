import 'package:flutter/foundation.dart';

import 'native_gallery.dart';

/// **La cuisine de la galerie** : les pages de médias et les vignettes, sans
/// rien savoir de l'écran qui les montre.
///
/// - [entries] publie la liste connue (une page de plus à chaque [loadMore]) ;
/// - [thumbnail] rend une vignette, depuis un cache borné en mémoire — la
///   grille en redemande sans cesse en défilant, le natif ne doit pas être
///   rappelé pour la même image.
class GalleryFeed extends ChangeNotifier {
  GalleryFeed({this.pageSize = 80});

  final int pageSize;

  final _entries = <GalleryEntry>[];
  var _loading = false;
  var _exhausted = false;
  Object? _error;

  List<GalleryEntry> get entries => List.unmodifiable(_entries);
  bool get isLoading => _loading;
  bool get isExhausted => _exhausted;
  Object? get error => _error;

  Future<void> loadMore() async {
    if (_loading || _exhausted) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final page = await NativeGallery.list(
        offset: _entries.length,
        limit: pageSize,
      );
      if (page.length < pageSize) _exhausted = true;
      _entries.addAll(page);
    } catch (e) {
      _error = e;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Vignettes : un cache LRU en mémoire ────────────────────────────

  /// ~300 vignettes de 300 px en JPEG ≈ 6 Mo : de quoi couvrir plusieurs
  /// écrans de grille sans rappeler le natif.
  static const _maxThumbs = 300;
  final _thumbs = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};

  Uint8List? cachedThumbnail(String uri, int size) => _thumbs['$uri@$size'];

  Future<Uint8List> thumbnail(String uri, {int size = 300}) {
    final key = '$uri@$size';
    final hit = _thumbs.remove(key);
    if (hit != null) {
      _thumbs[key] = hit; // le plus récent en dernier
      return Future.value(hit);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        final bytes = await NativeGallery.thumbnail(uri, size: size);
        _thumbs[key] = bytes;
        while (_thumbs.length > _maxThumbs) {
          _thumbs.remove(_thumbs.keys.first);
        }
        return bytes;
      } finally {
        _pending.remove(key);
      }
    });
  }
}
