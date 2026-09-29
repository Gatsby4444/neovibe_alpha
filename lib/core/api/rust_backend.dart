import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'nv_api.dart';
import 'rust_direct.dart';
import 'serveur.dart';

/// **Le branchement Rust** — l'app d'essai du serveur Rust
/// (`--dart-define=SERVEUR=rust`, docs/serveur-rust.md étape 11).
///
/// - la session : un **badge** d'une heure (`access_token`) et un jeton de
///   **renouvellement** tournant, gardés dans le coffre chiffré du téléphone
///   (`flutter_secure_storage`), jamais en clair ;
/// - les opérations : `POST /v1/rpc/<nom>`, le JSON tel quel ;
/// - les fichiers : des liens signés vers l'entrepôt (dépôt `PUT`, lecture
///   `GET`) — les octets ne passent jamais par le serveur ;
/// - le direct : `GET /v1/direct` (`rust_direct.dart`).
class RustBackend implements NvBackend {
  /// Un branchement vers le serveur à [url] ; la session gardée dans
  /// [coffre] (par défaut, le coffre chiffré du téléphone).
  RustBackend.pour(this.url, {CoffreDeSession? coffre})
    : _session = RustSession(url, coffre ?? CoffreDuTelephone());

  /// Celui de cette construction de l'app (`Serveur.url`).
  static final instance = RustBackend.pour(Serveur.url);

  final String url;
  final RustSession _session;

  /// À appeler au démarrage, avant le premier écran : relit la session
  /// gardée sur le téléphone.
  Future<void> demarrer() => _session.charger();

  @override
  late final NvApi api = _Api(url, _session);
  @override
  late final NvDirect direct = RustDirect(url, _session, api);
  @override
  late final NvFichiers fichiers = _Fichiers(api);
  @override
  late final NvAuth auth = _Auth(_session);
}

/// La réponse d'erreur du serveur (`{code, message}`), en exception.
NvApiException _erreur(http.Response r) {
  Object? corps;
  try {
    corps = jsonDecode(utf8.decode(r.bodyBytes));
  } catch (_) {}
  final m = corps is Map ? corps : const {};
  return NvApiException(
    m['message'] as String? ?? 'Le serveur a répondu ${r.statusCode}.',
    code: m['code'] as String?,
    status: r.statusCode,
  );
}

/// Où la session est gardée.
abstract class CoffreDeSession {
  Future<String?> lire();

  /// `null` efface.
  Future<void> ecrire(String? valeur);
}

/// Le coffre chiffré du téléphone (`flutter_secure_storage`).
class CoffreDuTelephone implements CoffreDeSession {
  static const _cle = 'nv_session';
  final _coffre = const FlutterSecureStorage();

  @override
  Future<String?> lire() => _coffre.read(key: _cle);

  @override
  Future<void> ecrire(String? valeur) => valeur == null
      ? _coffre.delete(key: _cle)
      : _coffre.write(key: _cle, value: valeur);
}

/// Une session qui ne survit pas au programme — pour les essais.
class CoffreEnMemoire implements CoffreDeSession {
  String? _valeur;

  @override
  Future<String?> lire() async => _valeur;

  @override
  Future<void> ecrire(String? valeur) async => _valeur = valeur;
}

/// **La session du serveur Rust.**
class RustSession {
  RustSession(this._url, this._coffre);

  final String _url;
  final CoffreDeSession _coffre;

  Map<String, dynamic>? _jetons;
  Future<bool>? _renouvellement;
  final _evenements = StreamController<NvEvenementAuth>.broadcast();

  /// [NvAuth.changements] : notifié par les deux seuls endroits où la
  /// session change — [charger] et [_ranger] —, avant qu'ils rendent la
  /// main, réussite ou échec.
  final changements = ValueNotifier<int>(0);

  String? get compte => (_jetons?['user'] as Map?)?['id'] as String?;

  Stream<NvEvenementAuth> get evenements => _evenements.stream;

  Future<void> charger() async {
    try {
      final brut = await _coffre.lire();
      if (brut != null) _jetons = jsonDecode(brut) as Map<String, dynamic>;
    } catch (_) {
      _jetons = null;
    } finally {
      changements.value++;
    }
  }

  /// La session change EN MÉMOIRE d'abord : même si le coffre du téléphone
  /// refuse l'écriture (trousseau Android en panne), ceux qui lisent
  /// [compte] sont prévenus — une déconnexion ne doit jamais laisser
  /// l'accueil affiché sur un compte parti.
  Future<void> _ranger(Map<String, dynamic>? jetons, NvEvenementAuth e) async {
    _jetons = jetons;
    try {
      await _coffre.ecrire(jetons == null ? null : jsonEncode(jetons));
    } finally {
      changements.value++;
      _evenements.add(e);
    }
  }

  Uri _adresse(String chemin) => Uri.parse('$_url$chemin');

  Future<void> _ouvrir(String chemin, Map<String, dynamic> corps) async {
    final r = await http.post(
      _adresse(chemin),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(corps),
    );
    if (r.statusCode != 200) throw _erreur(r);
    await _ranger(
      jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>,
      NvEvenementAuth.connecte,
    );
  }

  Future<void> connexion(String email, String password) =>
      _ouvrir('/v1/auth/connexion', {'email': email, 'password': password});

  Future<void> inscription(String email, String password, String? empreinte) =>
      _ouvrir('/v1/auth/inscription', {
        'email': email,
        'password': password,
        'device_hash': ?empreinte,
      });

  Future<void> deconnexion() async {
    final badge = _jetons?['access_token'] as String?;
    if (badge != null) {
      try {
        await http.post(
          _adresse('/v1/auth/deconnexion'),
          headers: {'authorization': 'Bearer $badge'},
        );
      } catch (_) {
        // Hors réseau : la session s'oublie quand même ici ; le serveur la
        // laissera expirer.
      }
    }
    await _ranger(null, NvEvenementAuth.deconnecte);
  }

  /// Le badge en cours — renouvelé s'il expire dans la minute.
  Future<String?> badge() async {
    final j = _jetons;
    if (j == null) return null;
    final expire = DateTime.fromMillisecondsSinceEpoch(
      ((j['expires_at'] as num?) ?? 0).toInt() * 1000,
    );
    if (expire.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return j['access_token'] as String?;
    }
    final frais = await renouveler();
    if (!frais) return null;
    return _jetons?['access_token'] as String?;
  }

  /// Renouvelle la session (un seul renouvellement à la fois) ; faux si elle
  /// n'est plus valable — on est alors déconnecté.
  Future<bool> renouveler() => _renouvellement ??= _renouveler().whenComplete(
    () => _renouvellement = null,
  );

  Future<bool> _renouveler() async {
    final jeton = _jetons?['refresh_token'] as String?;
    if (jeton == null) return false;
    final http.Response r;
    try {
      r = await http.post(
        _adresse('/v1/auth/renouveler'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'refresh_token': jeton}),
      );
    } catch (_) {
      // Pas de réseau : la session reste, on réessaiera.
      return false;
    }
    if (r.statusCode == 200) {
      await _ranger(
        jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>,
        NvEvenementAuth.renouvele,
      );
      return true;
    }
    if (r.statusCode == 401 || r.statusCode == 400) {
      await _ranger(null, NvEvenementAuth.deconnecte);
    }
    return false;
  }
}

class _Api implements NvApi {
  _Api(this._url, this._session);

  final String _url;
  final RustSession _session;

  Future<http.Response> _envoyer(String nom, Map<String, dynamic>? args) async {
    final badge = await _session.badge();
    return http.post(
      Uri.parse('$_url/v1/rpc/$nom'),
      headers: {
        'content-type': 'application/json',
        if (badge != null) 'authorization': 'Bearer $badge',
      },
      body: jsonEncode(args ?? const {}),
    );
  }

  @override
  Future<dynamic> op(String nom, [Map<String, dynamic>? args]) async {
    var r = await _envoyer(nom, args);
    // Le badge a expiré entre-temps : un renouvellement, un seul essai de
    // plus.
    if (r.statusCode == 401 && await _session.renouveler()) {
      r = await _envoyer(nom, args);
    }
    if (r.statusCode < 200 || r.statusCode >= 300) throw _erreur(r);
    return r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }
}

class _Fichiers implements NvFichiers {
  _Fichiers(this._api);

  final NvApi _api;

  /// Dépose par un lien signé (`PUT`) : les octets vont droit à l'entrepôt.
  Future<void> _deposer(
    String coffre,
    String chemin,
    int taille,
    String type,
    Stream<List<int>> octets,
  ) async {
    final lien =
        await _api.op('files_sign_upload', {
              'bucket': coffre,
              'path': chemin,
              'content_type': type,
              'size': taille,
            })
            as Map<String, dynamic>;
    final req = http.StreamedRequest('PUT', Uri.parse(lien['url'] as String))
      ..contentLength = taille;
    (lien['headers'] as Map?)?.forEach(
      (k, v) => req.headers[k as String] = '$v',
    );
    final reponse = req.send();
    await req.sink.addStream(octets);
    await req.sink.close();
    final r = await reponse;
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw NvApiException(
        'Le dépôt du fichier a échoué (${r.statusCode}).',
        status: r.statusCode,
      );
    }
  }

  @override
  Future<void> deposer(
    String coffre,
    String chemin,
    File fichier, {
    required String type,
  }) async => _deposer(
    coffre,
    chemin,
    await fichier.length(),
    type,
    fichier.openRead(),
  );

  @override
  Future<void> deposerOctets(
    String coffre,
    String chemin,
    Uint8List octets, {
    required String type,
  }) => _deposer(coffre, chemin, octets.length, type, Stream.value(octets));

  @override
  Future<String> lien(
    String coffre,
    String chemin, {
    int secondes = 3600,
  }) async {
    final r =
        await _api.op('files_sign_read', {
              'bucket': coffre,
              'paths': [chemin],
              'expires_in': secondes,
            })
            as List;
    final url = (r.isEmpty ? null : r.first as Map)?['signedUrl'] as String?;
    if (url == null) {
      throw NvApiException('Fichier introuvable ou non autorisé');
    }
    return url;
  }

  @override
  Future<Uint8List> telecharger(String coffre, String chemin) async {
    final r = await http.get(
      Uri.parse(await lien(coffre, chemin, secondes: 120)),
    );
    if (r.statusCode != 200) {
      throw NvApiException(
        'Le téléchargement a échoué (${r.statusCode}).',
        status: r.statusCode,
      );
    }
    return r.bodyBytes;
  }

  @override
  Future<void> supprimer(String coffre, List<String> chemins) =>
      _api.op('files_remove', {'bucket': coffre, 'paths': chemins});
}

class _Auth implements NvAuth {
  _Auth(this._session);

  final RustSession _session;

  @override
  String? get compte => _session.compte;

  @override
  Listenable get changements => _session.changements;

  /// L'état actuel d'abord (comme la session initiale de Supabase), puis
  /// chaque changement.
  @override
  Stream<NvEvenementAuth> get evenements async* {
    yield compte == null
        ? NvEvenementAuth.deconnecte
        : NvEvenementAuth.connecte;
    yield* _session.evenements;
  }

  @override
  Future<void> connexion({required String email, required String password}) =>
      _session.connexion(email, password);

  @override
  Future<bool> inscription({
    required String email,
    required String password,
    String? empreinte,
  }) async {
    await _session.inscription(email, password, empreinte);
    return true;
  }

  @override
  Future<void> deconnexion() => _session.deconnexion();

  @override
  Future<String?> badge() => _session.badge();
}
