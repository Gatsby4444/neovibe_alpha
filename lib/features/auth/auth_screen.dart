import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';
import '../../core/theme.dart';
import '../../core/widgets/gradient.dart';

/// **Se connecter à un compte existant.**
///
/// Depuis le 2026-09-24, l'INSCRIPTION n'est plus ici : elle passe par
/// l'arrivée en soirée (`ArrivalScreen`, mode réel — prénom, selfie
/// obligatoire, compte, autorisations). Cet écran s'ouvre par « J'ai déjà un
/// compte » et se referme de lui-même une fois connecté : `RootGate` prend
/// alors la suite (l'accueil, ou le parcours si le compte n'a pas de profil).
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _loading = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.length < 6) {
      _showError('Email valide et mot de passe de 6 caractères minimum.');
      return;
    }
    setState(() => _loading = true);
    final auth = ref.read(authRepositoryProvider);
    try {
      await auth.signIn(email: email, password: password);
      // Connecté : cet écran était poussé par-dessus le parcours d'arrivée,
      // que `RootGate` vient de remplacer. On le referme.
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } on AuthException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('Erreur inattendue : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Poussé par « J'ai déjà un compte » : le retour ramène à l'arrivée.
      appBar: AppBar(),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Nom de l'app en dégradé de marque
                GradientText(
                  'NeoVibe',
                  textAlign: TextAlign.center,
                  gradient: context.palette.signature,
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Le réseau de ceux qui se croisent vraiment.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 40),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Mot de passe'),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Se connecter'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
