import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/api/nv_api.dart';
import 'package:neovibe/core/device_identity.dart';
import 'package:neovibe/features/arrival/arrival_flow.dart';
import 'package:neovibe/features/profile/profile_repository.dart';

/// Une connexion qui compte les inscriptions et refuse la deuxième, comme le
/// serveur (« Un compte existe déjà avec cette adresse. »).
class _Auth implements NvAuth {
  int inscriptions = 0;

  @override
  String? compte;

  final _changements = ValueNotifier<int>(0);

  @override
  Listenable get changements => _changements;

  @override
  Stream<NvEvenementAuth> get evenements => const Stream.empty();

  @override
  Future<bool> inscription({
    required String email,
    required String password,
    String? empreinte,
  }) async {
    inscriptions++;
    if (inscriptions > 1) {
      throw NvApiException('Un compte existe déjà avec cette adresse.');
    }
    compte = 'moi';
    _changements.value++;
    return true;
  }

  int connexions = 0;

  @override
  Future<void> connexion({
    required String email,
    required String password,
  }) async {
    connexions++;
    compte = 'moi';
    _changements.value++;
  }

  /// La session tombe (badge expiré, déconnexion venue d'ailleurs).
  void perdre() {
    compte = null;
    _changements.value++;
  }

  @override
  Future<void> deconnexion() async {}

  @override
  Future<String?> badge() async => null;
}

class _Serveur implements NvBackend {
  _Serveur(this.auth);

  @override
  final NvAuth auth;

  @override
  NvApi get api => throw UnimplementedError();

  @override
  NvDirect get direct => throw UnimplementedError();

  @override
  NvFichiers get fichiers => throw UnimplementedError();
}

/// Le profil échoue la première fois (réseau coupé), réussit ensuite.
class _Profils extends ProfileRepository {
  _Profils(super.ref);

  int essais = 0;

  @override
  Future<void> create({
    required String userId,
    required String displayName,
    String? tagName,
  }) async {
    essais++;
    if (essais == 1) throw Exception('réseau coupé');
  }
}

class _Empreinte extends DeviceIdentity {
  const _Empreinte();

  @override
  Future<String?> fingerprint() async => 'empreinte';
}

/// « Créer mon compte » après un profil raté : le compte existe déjà, on
/// reprend au profil — jamais une seconde inscription (panne vue par Jay le
/// 2026-09-29 : « Un compte existe déjà avec cette adresse. »).
void main() {
  test(
    'réappuyer après un profil raté reprend au profil, sans réinscrire',
    () async {
      final auth = _Auth();
      late _Profils profils;
      final c = ProviderContainer(
        overrides: [
          nvBackendProvider.overrideWithValue(_Serveur(auth)),
          deviceIdentityProvider.overrideWithValue(const _Empreinte()),
          profileRepositoryProvider.overrideWith(
            (ref) => profils = _Profils(ref),
          ),
        ],
      );
      addTearDown(c.dispose);
      final flow = c.read(arrivalFlowProvider(ArrivalMode.real).notifier);
      flow.begin(hasAccount: false);
      flow.setPseudo('Essai');

      await flow.createAccount(email: 'a@b.c', password: 'secret123');
      expect(c.read(arrivalFlowProvider(ArrivalMode.real)).error, isNotNull);
      expect(auth.inscriptions, 1);

      await flow.createAccount(email: 'a@b.c', password: 'secret123');
      expect(c.read(arrivalFlowProvider(ArrivalMode.real)).error, isNull);
      expect(auth.inscriptions, 1);
      expect(profils.essais, 2);
    },
  );

  test(
    'compte créé mais session tombée : on se reconnecte, on ne réinscrit pas',
    () async {
      final auth = _Auth();
      late _Profils profils;
      final c = ProviderContainer(
        overrides: [
          nvBackendProvider.overrideWithValue(_Serveur(auth)),
          deviceIdentityProvider.overrideWithValue(const _Empreinte()),
          profileRepositoryProvider.overrideWith(
            (ref) => profils = _Profils(ref),
          ),
        ],
      );
      addTearDown(c.dispose);
      final flow = c.read(arrivalFlowProvider(ArrivalMode.real).notifier);
      flow.begin(hasAccount: false);
      flow.setPseudo('Essai');

      await flow.createAccount(email: 'a@b.c', password: 'secret123');
      expect(auth.inscriptions, 1);
      auth.perdre();

      await flow.createAccount(email: 'a@b.c', password: 'secret123');
      expect(c.read(arrivalFlowProvider(ArrivalMode.real)).error, isNull);
      expect(auth.inscriptions, 1);
      expect(auth.connexions, 1);
      expect(profils.essais, 2);
    },
  );
}
