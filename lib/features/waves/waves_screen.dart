import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/wave.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../connections/connections_repository.dart';

/// Historique des Waves : uniquement les croisements dont l'heure de
/// notification est passée (le différé reste différé), horodatage flou,
/// jamais de position (spec 4.11).
final wavesProvider = FutureProvider<List<Wave>>((ref) async {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return [];
  final rows = await ref
      .watch(supabaseProvider)
      .from('waves')
      .select()
      .eq('user_id', me)
      .lte('notify_after', DateTime.now().toUtc().toIso8601String())
      .order('detected_at', ascending: false)
      .limit(50);
  return rows.map(Wave.fromJson).toList();
});

class WavesScreen extends ConsumerWidget {
  const WavesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waves = ref.watch(wavesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Le presque')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(wavesProvider),
        child: waves.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Erreur : $e')),
          data: (list) => list.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 120),
                    Icon(Icons.waving_hand, size: 56, color: Colors.white24),
                    Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Aucun croisement manqué.\nQuand une de tes connexions passera près de toi, tu le sauras… après coup.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ],
                )
              : ListView(
                  children: [for (final wave in list) _WaveTile(wave: wave)],
                ),
        ),
      ),
    );
  }
}

class _WaveTile extends ConsumerWidget {
  const _WaveTile({required this.wave});
  final Wave wave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peer = ref.watch(profileByIdProvider(wave.peerId)).value;
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: peer?.avatarUrl == null
            ? null
            : NetworkImage(peer!.avatarUrl!),
        child: peer?.avatarUrl == null
            ? Text((peer?.displayName ?? '?').characters.first.toUpperCase())
            : null,
      ),
      title: Text('${peer?.displayName ?? 'Quelqu\'un'} est passé tout près'),
      subtitle: Text(vagueTimeAgo(wave.detectedAt)),
    );
  }
}
