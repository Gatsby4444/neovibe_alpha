import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/motion.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/top_banner.dart';
import '../cards/card_capture_screen.dart';
import '../connections/connections_repository.dart';
import '../library_vibes/library_target.dart';
import 'events_providers.dart';
import 'events_repository.dart';

/// **Les défis d'un événement** — le premier « jeu » du mode événement
/// (Jay, 2026-09-21 ; la vision depuis le 2026-09-11 : *des défis, à filmer
/// et à publier*).
///
/// Un présent pose un défi en une phrase (« Selfie avec quelqu'un que tu ne
/// connaissais pas ») ; les autres y répondent **par une Vibe dans la
/// bibliothèque de l'événement**, marquée du défi. Rien d'autre : pas de
/// points, pas de classement — le défi produit du contenu vécu, c'est sa
/// seule règle. Il faut être **sur place** pour poser ou répondre (le
/// serveur vérifie pour poser ; répondre passe par la bibliothèque, ouverte
/// aux membres de la conversation).
class EventChallengesScreen extends ConsumerWidget {
  const EventChallengesScreen({super.key, required this.eventId});

  final String eventId;

  Future<void> _poser(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final texte = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Un défi pour tout le monde'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 140,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Selfie avec quelqu\'un que tu ne connaissais pas…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (texte == null || texte.length < 3 || !context.mounted) return;
    try {
      await ref.read(eventsRepositoryProvider).postChallenge(eventId, texte);
    } catch (e) {
      if (context.mounted) {
        TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
      }
    }
  }

  void _repondre(BuildContext context, NeoEvent event, EventChallenge c) {
    Navigator.of(context).push(
      NeoFadeRoute(
        builder: (_) => CardCaptureScreen(
          libraryTarget: LibraryTarget(
            conversationId: event.conversationId,
            label: event.title,
            isGroup: true,
            isEvent: true,
            challengeId: c.id,
            challengeText: c.text,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final event = ref.watch(eventByIdProvider(eventId));
    final challenges = ref.watch(eventChallengesProvider(eventId));
    final me = ref.watch(currentUserIdProvider);
    final present = event?.iAmPresent ?? false;
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: const Text('Défis')),
      floatingActionButton: event != null && event.isOpen && present
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.flag_outlined),
              label: const Text('Lancer un défi'),
              onPressed: () => _poser(context, ref),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(eventChallengesProvider(eventId));
          await ref.read(eventChallengesProvider(eventId).future);
        },
        child: challenges.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(messageServeur(e))),
          data: (list) => list.isEmpty
              ? ListView(
                  padding: const EdgeInsets.all(32),
                  children: [
                    Text(
                      present
                          ? 'Aucun défi pour l\'instant. Lance le premier : '
                                'une phrase, et les autres y répondent par une '
                                'Vibe dans le Drop.'
                          : 'Aucun défi pour l\'instant. Il faut être sur '
                                'place pour en lancer un.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.muted),
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final c = list[i];
                    final author = ref
                        .watch(profileByIdProvider(c.authorId))
                        .value;
                    return _Defi(
                      challenge: c,
                      authorName: c.authorId == me
                          ? 'Toi'
                          : (author?.displayName ?? '…'),
                      canAnswer: event != null && event.isOpen && present,
                      onAnswer: event == null
                          ? null
                          : () => _repondre(context, event, c),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _Defi extends StatelessWidget {
  const _Defi({
    required this.challenge,
    required this.authorName,
    required this.canAnswer,
    required this.onAnswer,
  });

  final EventChallenge challenge;
  final String authorName;
  final bool canAnswer;
  final VoidCallback? onAnswer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(NeoRadius.md),
        border: Border.all(color: p.line),
      ),
      padding: const EdgeInsets.all(NeoSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            challenge.text,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '$authorName · ${timeAgo(challenge.createdAt)}',
            style: TextStyle(color: context.muted, fontSize: 12),
          ),
          if (canAnswer) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.photo_camera_outlined, size: 18),
              label: const Text('Répondre par une Vibe'),
              onPressed: onAnswer,
            ),
          ],
        ],
      ),
    );
  }
}
