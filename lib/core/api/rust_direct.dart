import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'nv_api.dart';
import 'rust_backend.dart';

/// **Le direct du serveur Rust** (`GET /v1/direct`, nv-server/src/direct.rs).
///
/// UNE connexion pour toute l'app, ouverte au premier abonnement :
/// - elle s'annonce avec le badge (`auth`), puis de nouveau à chaque
///   renouvellement, sans se couper ;
/// - chaque abonnement a une référence (`ref`) ; à la reconnexion, tous sont
///   renvoyés — et les listes suivies relisent leur état (`direct_instantane`)
///   pour ne rien manquer de ce qui s'est passé pendant la coupure ;
/// - la connexion tombe : on se reconnecte, de plus en plus lentement (1 s,
///   2 s, 4 s… 30 s au plus).
class RustDirect implements NvDirect {
  RustDirect(String url, this._session, this._api)
    : _adresse = '${url.replaceFirst('http', 'ws')}/v1/direct' {
    _session.evenements.listen((e) {
      if (e == NvEvenementAuth.renouvele) unawaited(_annoncer());
      if (e == NvEvenementAuth.deconnecte) _fermer();
    });
  }

  final String _adresse;
  final RustSession _session;
  final NvApi _api;

  WebSocket? _ws;
  Future<void>? _ouverture;
  var _pret = false;
  var _suivant = 0;
  var _attente = const Duration(seconds: 1);
  Timer? _reprise;
  final _abonnements = <String, _Abonnement>{};

  // ─── La connexion ─────────────────────────────────────────────────────

  void _envoyer(Map<String, dynamic> m) {
    if (_pret) _ws?.add(jsonEncode(m));
  }

  Future<void> _annoncer() async {
    final badge = await _session.badge();
    if (badge != null) _ws?.add(jsonEncode({'type': 'auth', 'token': badge}));
  }

  Future<void> _assurer() => _ouverture ??= _ouvrir();

  Future<void> _ouvrir() async {
    try {
      final ws = await WebSocket.connect(_adresse);
      ws.pingInterval = const Duration(seconds: 25);
      _ws = ws;
      ws.listen(
        _recevoir,
        onDone: _tombee,
        onError: (_) => _tombee(),
        cancelOnError: true,
      );
      await _annoncer();
    } catch (_) {
      _tombee();
    }
  }

  void _tombee() {
    _ws = null;
    _pret = false;
    _ouverture = null;
    if (_abonnements.isEmpty) return;
    _reprise?.cancel();
    _reprise = Timer(_attente, () => unawaited(_assurer()));
    _attente = Duration(seconds: (_attente.inSeconds * 2).clamp(1, 30));
  }

  void _fermer() {
    _reprise?.cancel();
    _pret = false;
    unawaited(_ws?.close());
    _ws = null;
    _ouverture = null;
  }

  void _recevoir(dynamic brut) {
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(brut as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['type']) {
      case 'pret':
        final premiere = !_pret;
        _pret = true;
        _attente = const Duration(seconds: 1);
        if (premiere) {
          for (final a in _abonnements.values) {
            _envoyer({'type': 'abonner', 'ref': a.ref, 'sujet': a.sujet});
            a.relire?.call();
          }
        }
      case 'expire':
        unawaited(_annoncer());
      case 'changement':
        _abonnements[m['ref']]?.changement?.call(
          NvChangement(
            m['op'] as String,
            Map<String, dynamic>.from(m['ligne'] as Map),
          ),
        );
      case 'diffusion':
        _abonnements[m['ref']]?.diffusion?.call(
          Map<String, dynamic>.from(m['contenu'] as Map),
        );
    }
  }

  String _abonner(_Abonnement a) {
    _abonnements[a.ref] = a;
    if (_pret) {
      _envoyer({'type': 'abonner', 'ref': a.ref, 'sujet': a.sujet});
    } else {
      unawaited(_assurer());
    }
    return a.ref;
  }

  void _desabonner(String ref) {
    _abonnements.remove(ref);
    _envoyer({'type': 'desabonner', 'ref': ref});
  }

  String _ref() => 'r${_suivant++}';

  static String _sujet(String table, String? colonne, Object? valeur) =>
      colonne == null ? table : '$table:$colonne=$valeur';

  // ─── Les portes ───────────────────────────────────────────────────────

  @override
  Stream<List<Map<String, dynamic>>> lignes(
    String table, {
    required List<String> cle,
    String? colonne,
    Object? valeur,
    String? ordre,
    bool croissant = true,
  }) {
    final sujet = _sujet(table, colonne, valeur);
    final etat = <String, Map<String, dynamic>>{};
    String cleDe(Map<String, dynamic> l) => cle.map((c) => '${l[c]}').join('|');
    late final StreamController<List<Map<String, dynamic>>> sortie;
    String? ref;

    void publier() {
      final liste = etat.values.toList();
      if (ordre != null) {
        liste.sort((a, b) {
          final c = _comparer(a[ordre], b[ordre]);
          return croissant ? c : -c;
        });
      }
      if (!sortie.isClosed) sortie.add(List.unmodifiable(liste));
    }

    Future<void> relire() async {
      try {
        final lignes = await _api.op('direct_instantane', {'sujet': sujet});
        etat.clear();
        for (final l in lignes as List) {
          final ligne = Map<String, dynamic>.from(l as Map);
          etat[cleDe(ligne)] = ligne;
        }
        publier();
      } catch (e) {
        if (!sortie.isClosed) sortie.addError(e);
      }
    }

    sortie = StreamController<List<Map<String, dynamic>>>(
      onListen: () {
        ref = _abonner(
          _Abonnement(
            _ref(),
            sujet,
            changement: (c) {
              final k = cleDe(c.ligne);
              if (c.op == 'DELETE') {
                etat.remove(k);
              } else {
                etat[k] = c.ligne;
              }
              publier();
            },
            relire: relire,
          ),
        );
        unawaited(relire());
      },
      onCancel: () {
        final r = ref;
        if (r != null) _desabonner(r);
      },
    );
    return sortie.stream;
  }

  @override
  Stream<NvChangement> insertions(
    String table, {
    String? colonne,
    Object? valeur,
  }) {
    late final StreamController<NvChangement> sortie;
    String? ref;
    sortie = StreamController<NvChangement>(
      onListen: () {
        ref = _abonner(
          _Abonnement(
            _ref(),
            _sujet(table, colonne, valeur),
            changement: (c) {
              if (c.op == 'INSERT' && !sortie.isClosed) sortie.add(c);
            },
          ),
        );
      },
      onCancel: () {
        final r = ref;
        if (r != null) _desabonner(r);
      },
    );
    return sortie.stream;
  }

  @override
  NvCanal canal(String sujet) => _Canal(this, sujet);
}

/// Deux valeurs d'une colonne (dates ISO, nombres, textes) comparées.
int _comparer(Object? a, Object? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  if (a is num && b is num) return a.compareTo(b);
  return '$a'.compareTo('$b');
}

class _Abonnement {
  _Abonnement(
    this.ref,
    this.sujet, {
    this.changement,
    this.diffusion,
    this.relire,
  });

  final String ref;
  final String sujet;
  final void Function(NvChangement)? changement;
  final void Function(Map<String, dynamic>)? diffusion;
  final Future<void> Function()? relire;
}

class _Canal implements NvCanal {
  _Canal(this._direct, this._sujet) {
    _ref = _direct._abonner(
      _Abonnement(_direct._ref(), _sujet, diffusion: _sortie.add),
    );
  }

  final RustDirect _direct;
  final String _sujet;
  late final String _ref;
  final _sortie = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get diffusions => _sortie.stream;

  @override
  void diffuser(Map<String, dynamic> contenu) => _direct._envoyer({
    'type': 'diffuser',
    'sujet': _sujet,
    'contenu': contenu,
  });

  @override
  Future<void> fermer() async {
    _direct._desabonner(_ref);
    await _sortie.close();
  }
}
