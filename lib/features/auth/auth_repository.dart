import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/device_identity.dart';
import '../../core/supabase_providers.dart';

/// Ce que l'inscription a donné.
enum SignUpOutcome {
  /// Compte créé, session ouverte : on entre.
  signedIn,

  /// Compte créé, mais le serveur attend encore la confirmation du mail.
  /// Ne devrait plus arriver depuis le 2026-09-24 (confirmation coupée) ;
  /// gardé pour dire la vérité si le réglage serveur revenait.
  mustConfirmEmail,
}

/// **La connexion et l'inscription — la cuisine de l'écran d'accueil.**
///
/// Sorti de `auth_screen.dart` le 2026-09-24 : l'écran appelait Supabase
/// lui-même (règle « un écran ne parle jamais au réseau »), et l'inscription
/// doit désormais joindre l'empreinte du téléphone.
class AuthRepository {
  AuthRepository(this._ref);

  final Ref _ref;

  GoTrueClient get _auth => _ref.read(supabaseProvider).auth;

  Future<void> signIn({required String email, required String password}) =>
      _auth.signInWithPassword(email: email, password: password);

  /// Crée le compte, **avec l'empreinte du téléphone**.
  ///
  /// C'est le serveur qui compte les comptes créés par ce téléphone et qui
  /// refuse au-delà du plafond (`hook_before_user_created`) : son refus
  /// remonte ici en [AuthException], avec son message.
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
  }) async {
    final device = await _ref.read(deviceIdentityProvider).fingerprint();
    final res = await _auth.signUp(
      email: email,
      password: password,
      data: {'device_hash': ?device},
    );
    return res.session == null
        ? SignUpOutcome.mustConfirmEmail
        : SignUpOutcome.signedIn;
  }
}

final authRepositoryProvider = Provider(AuthRepository.new);
