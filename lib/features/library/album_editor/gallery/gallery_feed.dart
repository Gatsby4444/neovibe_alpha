import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_gallery.dart';

/// **La cuisine de la galerie** : les pages de médias et les vignettes, sans
/// rien savoir de l'écran qui les montre.
///
/// - [entries] publie la liste connue (une page de plus à chaque [loadMore]) ;
/// - [thumbnail] rend une vignette, depuis un cache borné en mémoire.
///
/// ### Les visibles d'abord — corrigé le 2026-09-15
///
/// Le premier jet envoyait chaque demande au natif dans l'ordre d'arrivée,
/// sur trois fils. En défilant, les cases **visibles** attendaient derrière
/// des dizaines de cases déjà sorties de l'écran : « ça met énormément de
/// temps à charger » (Jay). Ici, les demandes passent par une **file LIFO** :
/// la dernière demandée — celle qu'on regarde — part la première ; une case
/// qui disparaît **retire** sa demande de la file ([forget]) ; six demandes
/// au plus en cours côté natif.
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

  // ── Vignettes : cache LRU, file LIFO, six en vol ─────────────────────

  /// ~300 vignettes de 256 px en JPEG ≈ 5 Mo : de quoi couvrir plusieurs
  /// écrans de grille sans rappeler le natif.
  static const _maxThumbs = 300;
  static const _concurrency = 6;

  final _thumbs = <String, Uint8List>{};
  final _pending = <String, _Request>{};
  final _queue = <_Request>[];
  var _inFlight = 0;

  static String _key(String uri, int size) => '$uri@$size';

  Uint8List? cachedThumbnail(String uri, int size) => _thumbs[_key(uri, size)];

  /// La vignette de [uri] en [size] pixels. [priority] : devant tout le monde
  /// (le grand aperçu).
  Future<Uint8List> thumbnail(
    String uri, {
    int size = 256,
    bool priority = false,
  }) {
    final key = _key(uri, size);
    final hit = _thumbs.remove(key);
    if (hit != null) {
      _thumbs[key] = hit; // le plus récent en dernier
      return Future.value(hit);
    }
    final pending = _pending[key];
    if (pending != null) {
      // Redemandée : elle repasse devant.
      if (_queue.remove(pending)) _queue.insert(0, pending);
      return pending.completer.future;
    }
    final req = _Request(key, uri, size);
    _pending[key] = req;
    // LIFO : la dernière demandée part la première. Le grand aperçu aussi.
    _queue.insert(0, req);
    _pump();
    return req.completer.future;
  }

  /// Plus personne ne regarde cette vignette : si elle n'est pas partie, elle
  /// ne partira pas.
  void forget(String uri, {int size = 256}) {
    final key = _key(uri, size);
    final req = _pending[key];
    if (req == null || req.started) return;
    _queue.remove(req);
    _pending.remove(key);
    // Personne n'écoute plus : l'erreur ne doit pas remonter comme non gérée.
    req.completer.future.ignore();
    req.completer.completeError(StateError('vignette abandonnée'));
  }

  void _pump() {
    while (_inFlight < _concurrency && _queue.isNotEmpty) {
      final req = _queue.removeAt(0);
      req.started = true;
      _inFlight += 1;
      NativeGallery.thumbnail(req.uri, size: req.size)
          .then((bytes) {
            _thumbs[req.key] = bytes;
            while (_thumbs.length > _maxThumbs) {
              _thumbs.remove(_thumbs.keys.first);
            }
            req.completer.complete(bytes);
          })
          .catchError((Object e) {
            req.completer.completeError(e);
          })
          .whenComplete(() {
            _pending.remove(req.key);
            _inFlight -= 1;
            _pump();
          });
    }
  }
}

class _Request {
  _Request(this.key, this.uri, this.size);
  final String key;
  final String uri;
  final int size;
  final completer = Completer<Uint8List>();
  var started = false;
}
