import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/api/nv_api.dart';
import 'package:neovibe/core/session_providers.dart';

/// Une connexion qui ne fait que ce que promet `NvAuth` : le geste change
/// [compte] et notifie [changements] avant de rendre la main. Aucun
/// événement n'est jamais émis — le compte connecté ne doit pas en dépendre.
class _AuthFausse implements NvAuth {
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
    await Future<void>.delayed(Duration.zero);
    compte = 'compte-$email';
    _changements.value++;
    return true;
  }

  @override
  Future<void> connexion({required String email, required String password}) =>
      inscription(email: email, password: password);

  @override
  Future<void> deconnexion() async {
    compte = null;
    _changements.value++;
  }

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

/// Le compte connecté se lit dès que le geste de connexion rend la main
/// (règle de `NvAuth.changements`) — panne « Pas de session ouverte. » du
/// 2026-09-28, le même contrat pour les deux serveurs.
void main() {
  test(
    'le compte se lit dès la fin du geste, sans attendre d\'événement',
    () async {
      final auth = _AuthFausse();
      final c = ProviderContainer(
        overrides: [nvBackendProvider.overrideWithValue(_Serveur(auth))],
      );
      addTearDown(c.dispose);
      c.listen(currentUserIdProvider, (_, _) {});
      expect(c.read(currentUserIdProvider), isNull);

      await auth.inscription(email: 'a@b.c', password: 'x');
      expect(c.read(currentUserIdProvider), 'compte-a@b.c');

      await auth.deconnexion();
      expect(c.read(currentUserIdProvider), isNull);
    },
  );
}
