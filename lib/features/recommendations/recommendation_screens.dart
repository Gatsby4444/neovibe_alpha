import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/recommendation.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import 'recommendations_repository.dart';

/// B demande à A une mise en relation : A est choisi parmi MES connexions,
/// C est décrit en texte libre (B ne voit jamais le cercle de A).
class RequestRecommendationScreen extends ConsumerStatefulWidget {
  const RequestRecommendationScreen({super.key});

  @override
  ConsumerState<RequestRecommendationScreen> createState() =>
      _RequestRecommendationScreenState();
}

class _RequestRecommendationScreenState
    extends ConsumerState<RequestRecommendationScreen> {
  String? _intermediaryId;
  final _hint = TextEditingController();
  var _loading = false;

  @override
  void dispose() {
    _hint.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_intermediaryId == null || _hint.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choisis un ami et décris qui tu cherches.'),
        ),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      await ref
          .read(recommendationsRepositoryProvider)
          .request(_intermediaryId!, _hint.text.trim());
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Demande envoyée. Tu seras notifié si elle aboutit.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mise en relation')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Un ami commun peut te mettre en relation avec quelqu\'un de son cercle. '
            'Décris qui tu cherches : c\'est lui qui choisira de transmettre — ou pas.',
            style: TextStyle(color: context.muted),
          ),
          const SizedBox(height: 20),
          Text(
            'Via quel ami ?',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          RadioGroup<String>(
            groupValue: _intermediaryId,
            onChanged: (v) => setState(() => _intermediaryId = v),
            child: Column(
              children: [
                for (final connection in connections)
                  _IntermediaryTile(peerId: connection.peerIdFor(me)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _hint,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'Qui cherches-tu ?',
              hintText: 'Ex. : "Ton pote guitariste croisé à ta soirée"',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _loading ? null : _send,
            child: const Text('Envoyer la demande'),
          ),
        ],
      ),
    );
  }
}

class _IntermediaryTile extends ConsumerWidget {
  const _IntermediaryTile({required this.peerId});
  final String peerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByIdProvider(peerId)).value;
    return RadioListTile<String>(
      value: peerId,
      title: Text(profile?.displayName ?? '…'),
    );
  }
}

/// A transmet la demande de B vers un C de SON cercle (plafond 10/mois côté
/// serveur). Ignorer = ne rien faire : expiration silencieuse pour B.
class ForwardRecommendationScreen extends ConsumerStatefulWidget {
  const ForwardRecommendationScreen({super.key, required this.recommendation});
  final Recommendation recommendation;

  @override
  ConsumerState<ForwardRecommendationScreen> createState() =>
      _ForwardRecommendationScreenState();
}

class _ForwardRecommendationScreenState
    extends ConsumerState<ForwardRecommendationScreen> {
  String? _targetId;
  var _loading = false;

  Future<void> _forward() async {
    if (_targetId == null) return;
    setState(() => _loading = true);
    try {
      await ref
          .read(recommendationsRepositoryProvider)
          .forward(widget.recommendation.id, _targetId!);
      ref.invalidate(recommendationInboxProvider);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Transmis ✓')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        final message = e.toString().contains('Plafond')
            ? 'Plafond mensuel atteint : 10 mises en relation par mois.'
            : 'Erreur : $e';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final reco = widget.recommendation;
    final candidates = ref
        .watch(fullConnectionsProvider)
        .map((c) => c.peerIdFor(me))
        .where((id) => id != reco.requesterId)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Transmettre')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${reco.requester?.displayName ?? '?'} cherche :\n"${reco.targetHint}"',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Transmettre à…',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          RadioGroup<String>(
            groupValue: _targetId,
            onChanged: (v) => setState(() => _targetId = v),
            child: Column(
              children: [
                for (final id in candidates) _IntermediaryTile(peerId: id),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _loading || _targetId == null ? null : _forward,
            child: const Text('Transmettre'),
          ),
          TextButton(
            onPressed: () async {
              await ref
                  .read(recommendationsRepositoryProvider)
                  .decline(widget.recommendation.id);
              ref.invalidate(recommendationInboxProvider);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Ignorer (silencieux pour le demandeur)'),
          ),
        ],
      ),
    );
  }
}
