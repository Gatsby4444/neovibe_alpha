import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/utils/formats.dart';

/// **« Ton compte est suspendu »** — ce que voit un compte suspendu par
/// l'administration (2026-09-21, RAPPELS #156). Rien d'autre n'est
/// accessible : le serveur refuse déjà les portes qui créent du contenu
/// (`private.assert_not_suspended`), cet écran le dit avec des mots.
class SuspendedScreen extends ConsumerWidget {
  const SuspendedScreen({super.key, required this.since, this.reason});

  final DateTime since;
  final String? reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.block, size: 56, color: context.ghost),
              const SizedBox(height: 16),
              Text(
                'Ton compte est suspendu',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Depuis ${dayAndTime(since)}.'
                '${reason == null || reason!.isEmpty ? '' : '\n\n$reason'}',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => ref.read(supabaseProvider).auth.signOut(),
                child: const Text('Se déconnecter'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ma suspension, s'il y en a une — lue au démarrage.
final mySuspensionProvider =
    FutureProvider<({DateTime since, String? reason})?>((ref) async {
      if (ref.watch(currentUserIdProvider) == null) return null;
      final rows =
          await ref.watch(supabaseProvider).rpc('my_suspension') as List;
      if (rows.isEmpty) return null;
      final r = (rows.first as Map).cast<String, dynamic>();
      return (
        since: DateTime.parse(r['suspended_at'] as String),
        reason: r['reason'] as String?,
      );
    });
