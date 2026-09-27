import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'nv_api.dart';
import 'supabase_gestes.dart';

/// **Le branchement Supabase** — l'app de tous les jours.
///
/// Il fait EXACTEMENT ce que faisaient les dépôts avant la couche d'accès :
/// les opérations sont les fonctions SQL (`rpc`), les gestes directs sur les
/// tables sont rangés dans `supabase_gestes.dart` (une requête par nom),
/// le direct, les coffres et la connexion sont ceux de Supabase.
///
/// ⚠️ C'est le SEUL fichier de l'app (avec `supabase_gestes.dart`) qui parle
/// à Supabase. Il disparaîtra au déménagement (étape 12).
class SupabaseBackend implements NvBackend {
  SupabaseBackend._();

  static final instance = SupabaseBackend._();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  late final NvApi api = _Api(() => _client);
  @override
  late final NvDirect direct = _Direct(() => _client);
  @override
  late final NvFichiers fichiers = _Fichiers(() => _client);
  @override
  late final NvAuth auth = _Auth(() => _client);
}

class _Api implements NvApi {
  _Api(this._c);

  final SupabaseClient Function() _c;

  @override
  Future<dynamic> op(String nom, [Map<String, dynamic>? args]) async {
    final client = _c();
    final geste = gestesSupabase[nom];
    try {
      if (geste != null) return await geste(client, args ?? const {});
      // Le fil et la carte lisent leurs publications avec ce qu'elles
      // permettent et leurs médias : c'est PostgREST qui les joignait.
      if (nom == 'feed_items' || nom == 'map_vibe_items') {
        return await client.rpc(nom, params: args).select(selectPublication);
      }
      return await client.rpc(nom, params: args);
    } on PostgrestException catch (e) {
      throw NvApiException(e.message, code: e.code);
    }
  }
}

class _Direct implements NvDirect {
  _Direct(this._c);

  final SupabaseClient Function() _c;
  var _suivant = 0;

  @override
  Stream<List<Map<String, dynamic>>> lignes(
    String table, {
    required List<String> cle,
    String? colonne,
    Object? valeur,
    String? ordre,
    bool croissant = true,
  }) {
    final base = _c().from(table).stream(primaryKey: cle);
    final SupabaseStreamBuilder filtre = colonne != null
        ? base.eq(colonne, valeur!)
        : base;
    final rangee = ordre != null
        ? filtre.order(ordre, ascending: croissant)
        : filtre;
    return rangee.map((rows) => rows.toList(growable: false));
  }

  @override
  Stream<NvChangement> insertions(
    String table, {
    String? colonne,
    Object? valeur,
  }) {
    final client = _c();
    late final RealtimeChannel canal;
    late final StreamController<NvChangement> sortie;
    sortie = StreamController<NvChangement>(
      onListen: () {
        canal = client.channel('nv:$table:${valeur ?? '*'}:${_suivant++}')
          ..onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: table,
            filter: colonne == null
                ? null
                : PostgresChangeFilter(
                    type: PostgresChangeFilterType.eq,
                    column: colonne,
                    value: valeur,
                  ),
            callback: (p) => sortie.add(NvChangement('INSERT', p.newRecord)),
          )
          ..subscribe();
      },
      onCancel: () => client.removeChannel(canal),
    );
    return sortie.stream;
  }

  @override
  NvCanal canal(String sujet) => _Canal(_c(), sujet);
}

/// La diffusion Supabase (`broadcast`, événement `typing`).
class _Canal implements NvCanal {
  _Canal(this._client, String sujet) {
    _canal = _client.channel(sujet)
      ..onBroadcast(event: 'typing', callback: _sortie.add)
      ..subscribe();
  }

  final SupabaseClient _client;
  late final RealtimeChannel _canal;
  final _sortie = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get diffusions => _sortie.stream;

  @override
  void diffuser(Map<String, dynamic> contenu) =>
      unawaited(_canal.sendBroadcastMessage(event: 'typing', payload: contenu));

  @override
  Future<void> fermer() async {
    await _canal.unsubscribe();
    await _sortie.close();
  }
}

class _Fichiers implements NvFichiers {
  _Fichiers(this._c);

  final SupabaseClient Function() _c;

  @override
  Future<void> deposer(
    String coffre,
    String chemin,
    File fichier, {
    required String type,
  }) => _c().storage
      .from(coffre)
      .upload(chemin, fichier, fileOptions: FileOptions(contentType: type));

  @override
  Future<void> deposerOctets(
    String coffre,
    String chemin,
    Uint8List octets, {
    required String type,
  }) => _c().storage
      .from(coffre)
      .uploadBinary(
        chemin,
        octets,
        fileOptions: FileOptions(contentType: type),
      );

  @override
  Future<Uint8List> telecharger(String coffre, String chemin) =>
      _c().storage.from(coffre).download(chemin);

  @override
  Future<String> lien(String coffre, String chemin, {int secondes = 3600}) =>
      _c().storage.from(coffre).createSignedUrl(chemin, secondes);

  @override
  Future<void> supprimer(String coffre, List<String> chemins) =>
      _c().storage.from(coffre).remove(chemins);
}

class _Auth implements NvAuth {
  _Auth(this._c) {
    // Le direct de Supabase garde le jeton avec lequel il s'est ouvert : on
    // lui donne chaque nouveau jeton (défaut du 2026-08-17). Une seule
    // écoute, ici — pas une par abonné.
    _auth.onAuthStateChange.listen((s) {
      final jeton = s.session?.accessToken;
      if (jeton != null) _c().realtime.setAuth(jeton);
    });
  }

  final SupabaseClient Function() _c;

  GoTrueClient get _auth => _c().auth;

  @override
  String? get compte => _auth.currentUser?.id;

  @override
  Stream<NvEvenementAuth> get evenements => _auth.onAuthStateChange.map(
    (s) => switch (s.event) {
      AuthChangeEvent.signedOut => NvEvenementAuth.deconnecte,
      AuthChangeEvent.tokenRefreshed => NvEvenementAuth.renouvele,
      AuthChangeEvent.initialSession =>
        s.session == null
            ? NvEvenementAuth.deconnecte
            : NvEvenementAuth.connecte,
      _ => NvEvenementAuth.connecte,
    },
  );

  /// Les refus de la connexion Supabase, dits comme ceux de tout le serveur.
  Future<T> _traduire<T>(Future<T> Function() geste) async {
    try {
      return await geste();
    } on AuthException catch (e) {
      throw NvApiException(e.message, code: e.code);
    }
  }

  @override
  Future<void> connexion({required String email, required String password}) =>
      _traduire(
        () => _auth.signInWithPassword(email: email, password: password),
      );

  @override
  Future<bool> inscription({
    required String email,
    required String password,
    String? empreinte,
  }) => _traduire(() async {
    final res = await _auth.signUp(
      email: email,
      password: password,
      data: {'device_hash': ?empreinte},
    );
    return res.session != null;
  });

  @override
  Future<void> deconnexion() => _auth.signOut();

  @override
  Future<String?> badge() async {
    final session = _auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) {
      final frais = await _auth.refreshSession();
      return frais.session?.accessToken;
    }
    return session.accessToken;
  }
}
