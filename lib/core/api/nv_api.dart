import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rust_backend.dart';

/// # La couche d'accès au serveur (RAPPELS #12, docs/serveur-rust.md §11)
///
/// **Le seul endroit de l'app qui sait à quel serveur elle parle.** Les
/// dépôts demandent une opération par son NOM (`add_to_feed`, `card_get`…),
/// avec des arguments JSON, et reçoivent une réponse JSON du serveur
/// NeoVibe (Rust). (Ses guichets ont repris le nom et le JSON des fonctions
/// de l'ancien serveur, Supabase — retiré de l'app le 2026-09-29.)
///
/// Quatre portes, séparées :
/// - [NvApi] : les opérations ;
/// - [NvDirect] : le direct (lignes suivies, changements, diffusions) ;
/// - [NvFichiers] : les coffres de fichiers ;
/// - [NvAuth] : la connexion.

/// Une demande refusée (ou une panne), telle que le serveur l'a dite.
///
/// ⚠️ Sa forme écrite (« message: …, code: … ») est celle que lit
/// `messageServeur` (`core/utils/erreur_serveur.dart`) : les écrans
/// affichent la même phrase quel que soit le serveur.
class NvApiException implements Exception {
  NvApiException(this.message, {this.code, this.status});

  final String message;
  final String? code;

  /// Le statut HTTP (serveur Rust), s'il y en a un.
  final int? status;

  /// Le badge n'est plus bon : il faut se reconnecter.
  bool get nonConnecte => status == 401 || code == 'unauthenticated';

  @override
  String toString() => 'NvApiException(message: $message, code: $code)';
}

/// **Les opérations** : un nom, des arguments, une réponse JSON.
abstract class NvApi {
  Future<dynamic> op(String nom, [Map<String, dynamic>? args]);
}

/// Un changement d'une ligne suivie en direct.
class NvChangement {
  const NvChangement(this.op, this.ligne);

  /// `INSERT`, `UPDATE` ou `DELETE`.
  final String op;
  final Map<String, dynamic> ligne;
}

/// Une diffusion éphémère entre les membres d'une conversation (« en train
/// d'écrire »). Rien n'est gardé.
abstract class NvCanal {
  Stream<Map<String, dynamic>> get diffusions;
  void diffuser(Map<String, dynamic> contenu);
  Future<void> fermer();
}

/// **Le direct.**
abstract class NvDirect {
  /// Les lignes d'une table qui passent le filtre `colonne = valeur`, tenues
  /// à jour : l'état COMPLET à chaque changement (comme `.stream()`), rangé
  /// par `ordre` s'il est donné.
  Stream<List<Map<String, dynamic>>> lignes(
    String table, {
    required List<String> cle,
    String? colonne,
    Object? valeur,
    String? ordre,
    bool croissant = true,
  });

  /// Les INSERTIONS dans une table (filtrées par `colonne = valeur`), une à
  /// une.
  Stream<NvChangement> insertions(
    String table, {
    String? colonne,
    Object? valeur,
  });

  /// Un canal de diffusion (`typing:<conversation>`).
  NvCanal canal(String sujet);
}

/// **Les coffres de fichiers.**
abstract class NvFichiers {
  Future<void> deposer(
    String coffre,
    String chemin,
    File fichier, {
    required String type,
  });

  Future<void> deposerOctets(
    String coffre,
    String chemin,
    Uint8List octets, {
    required String type,
  });

  Future<Uint8List> telecharger(String coffre, String chemin);

  /// Un lien de lecture, valable [secondes].
  Future<String> lien(String coffre, String chemin, {int secondes = 3600});

  Future<void> supprimer(String coffre, List<String> chemins);
}

/// Ce que la connexion annonce.
enum NvEvenementAuth { connecte, deconnecte, renouvele }

/// **La connexion.**
abstract class NvAuth {
  /// Le compte connecté, ou nul. **La** source : rien d'autre ne le garde.
  String? get compte;

  /// Notifié **sur-le-champ** chaque fois que [compte] peut avoir changé.
  ///
  /// La règle, énoncée positivement : quand [connexion], [inscription] ou
  /// [deconnexion] rendent la main, [changements] a DÉJÀ été notifié —
  /// c'est le geste d'écriture qui prévient, jamais un messager qui passe
  /// « plus tard ». (Sans elle, le parcours d'arrivée lisait « personne »
  /// juste après l'inscription : « Pas de session ouverte. », Jay,
  /// 2026-09-28 ; reproduit le 2026-09-29,
  /// test/serveur_rust_bout_en_bout_test.dart.) Qui veut [compte] le relit
  /// à chaque notification : `currentUserIdProvider`.
  Listenable get changements;

  /// Connexion, déconnexion, badge renouvelé.
  Stream<NvEvenementAuth> get evenements;

  Future<void> connexion({required String email, required String password});

  /// Crée le compte (avec l'empreinte du téléphone) ; vrai si la session est
  /// ouverte (faux : le mail est à confirmer).
  Future<bool> inscription({
    required String email,
    required String password,
    String? empreinte,
  });

  Future<void> deconnexion();

  /// Le badge en cours (renouvelé s'il allait expirer), pour le natif.
  Future<String?> badge();
}

/// Les quatre portes d'un serveur.
abstract class NvBackend {
  NvApi get api;
  NvDirect get direct;
  NvFichiers get fichiers;
  NvAuth get auth;
}

/// Le serveur de l'app — pour le code qui vit hors des providers (le
/// démarrage, les services).
NvBackend get nvBackendCourant => RustBackend.instance;

/// Le serveur de l'app.
final nvBackendProvider = Provider<NvBackend>((ref) => nvBackendCourant);

final nvApiProvider = Provider<NvApi>(
  (ref) => ref.watch(nvBackendProvider).api,
);

final nvDirectProvider = Provider<NvDirect>(
  (ref) => ref.watch(nvBackendProvider).direct,
);

final nvFichiersProvider = Provider<NvFichiers>(
  (ref) => ref.watch(nvBackendProvider).fichiers,
);

final nvAuthProvider = Provider<NvAuth>(
  (ref) => ref.watch(nvBackendProvider).auth,
);
