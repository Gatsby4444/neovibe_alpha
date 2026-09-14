import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/top_banner.dart';
import '../proximity/geo/coarse_location.dart';
import 'create_event_screen.dart';
import 'event_screen.dart';
import 'events_providers.dart';
import 'events_repository.dart';

/// **La porte des événements** — on y arrive depuis l'onglet Cercle
/// (décision de Jay, 2026-09-12 : *« c'est la porte d'entrée aussi pour
/// rejoindre un événement et activer le mode événement »*).
///
/// Trois blocs, du plus proche au plus lointain :
///
/// 1. **où je suis** — l'événement en cours, s'il y en a un ;
/// 2. **mes événements** — ceux où je suis invité, ceux où je suis allé,
///    ceux que je gère ;
/// 3. **autour de moi** — les soirées d'établissement ouvertes à portée, avec
///    la distance. C'est le « on passe devant un bar » de la vision.
///
/// ⚠️ Cet écran ne parle à aucun serveur : il lit des vues
/// (`events_providers.dart`) et demande à la cuisine (`events_repository.dart`).
class EventsScreen extends ConsumerWidget {
  const EventsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final events = ref.watch(myEventsProvider);
    final nearby = ref.watch(nearbyVenueEventsProvider);
    final currentId = ref.watch(currentEventIdProvider);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Événements'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Créer un événement',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CreateEventScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myEventsProvider);
          ref.invalidate(nearbyVenueEventsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (currentId != null) _EnCours(eventId: currentId),
            const _Titre('Mes événements'),
            events.when(
              loading: () => const _Chargement(),
              error: (e, _) => _Message(messageServeur(e)),
              data: (list) {
                final miens = [
                  for (final e in list)
                    if (e.id != currentId) e,
                ];
                if (miens.isEmpty) {
                  return const _Message(
                    'Aucun événement pour l\'instant. Crée une soirée avec '
                    'tes amis, ou rejoins un lieu autour de toi.',
                  );
                }
                return Column(
                  children: [
                    for (final e in miens) _TuileEvenement(event: e, me: me),
                  ],
                );
              },
            ),
            const _Titre('Autour de moi'),
            nearby.when(
              loading: () => const _Chargement(),
              error: (e, _) => _Message(
                e is StateError
                    ? 'Active la localisation pour voir les soirées autour '
                          'de toi.'
                    : messageServeur(e),
                action: TextButton(
                  onPressed: () => ref.invalidate(nearbyVenueEventsProvider),
                  child: const Text('Réessayer'),
                ),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return const _Message(
                    'Aucune soirée ouverte à moins de 2 km. Reviens quand tu '
                    'passes devant un lieu partenaire.',
                  );
                }
                return Column(
                  children: [for (final v in list) _TuileAutour(venue: v)],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// L'événement où je suis, en tête — le mode événement à un geste.
class _EnCours extends ConsumerWidget {
  const _EnCours({required this.eventId});
  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final event = ref.watch(eventByIdProvider(eventId));
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Material(
        color: p.action.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(NeoRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(NeoRadius.md),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => EventScreen(eventId: eventId)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(NeoSpace.lg),
            child: Row(
              children: [
                Icon(Icons.celebration, color: p.action),
                const SizedBox(width: NeoSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Tu es à', style: context.sectionMeta),
                      Text(
                        event?.title ?? '…',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (event != null)
                        Text(
                          '${event.presentCount} présent'
                          '${event.presentCount > 1 ? 's' : ''}',
                          style: context.sectionMeta,
                        ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TuileEvenement extends StatelessWidget {
  const _TuileEvenement({required this.event, required this.me});
  final NeoEvent event;
  final String me;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: p.field,
        child: Icon(
          event.kind == EventKind.venue ? Icons.storefront : Icons.group,
          color: p.ink,
        ),
      ),
      title: Text(event.title),
      subtitle: Text(eventStatusLabel(event, DateTime.now())),
      trailing: event.isClosed
          ? Icon(Icons.lock_clock_outlined, color: context.faint)
          : const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => EventScreen(eventId: event.id))),
    );
  }
}

class _TuileAutour extends ConsumerWidget {
  const _TuileAutour({required this.venue});
  final NearbyVenueEvent venue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final presents = venue.presentCount;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: p.field,
        child: Icon(Icons.storefront, color: p.ink),
      ),
      title: Text(venue.title),
      subtitle: Text(
        '${venue.venueName} · à ${venue.distanceM} m · '
        '$presents présent${presents > 1 ? 's' : ''}',
      ),
      trailing: venue.withinReach
          ? FilledButton(
              onPressed: () => rejoindreEvenement(context, ref, venue.id),
              child: const Text('Je suis là'),
            )
          : Text('${venue.distanceM} m', style: context.sectionMeta),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EventScreen(eventId: venue.id, preview: venue),
        ),
      ),
    );
  }
}

/// **Rejoindre EN ÉTANT SUR PLACE** — le geste unique, partagé par tous les
/// écrans. Relève la position, la donne au serveur, et affiche ce qu'il
/// répond : c'est lui qui juge la distance.
Future<bool> rejoindreEvenement(
  BuildContext context,
  WidgetRef ref,
  String eventId,
) async {
  final fix = await ref.read(coarseLocationProvider).current();
  if (fix == null) {
    if (context.mounted) {
      TopBanner.show(
        context,
        'Pas de position : active la localisation pour rejoindre.',
        tone: TopBannerTone.already,
      );
    }
    return false;
  }
  try {
    await ref
        .read(eventsRepositoryProvider)
        .join(
          eventId,
          lat: fix.latitude,
          lon: fix.longitude,
          accuracy: fix.accuracy,
        );
    if (context.mounted) TopBanner.show(context, 'Tu es dans l\'événement.');
    return true;
  } catch (e) {
    if (context.mounted) {
      TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
    }
    return false;
  }
}

/// L'état d'un événement, en une ligne de tous les jours.
String eventStatusLabel(NeoEvent e, DateTime now) {
  if (e.isClosed) {
    final reveal = e.libraryRevealAt;
    if (reveal != null && reveal.isAfter(now)) {
      return 'Terminé · Drop révélé ${dayAndTime(reveal)}';
    }
    return 'Terminé';
  }
  if (e.notStartedAt(now)) {
    return 'Commence ${dayAndTime(e.startsAt)}';
  }
  final n = e.presentCount;
  final presents = n == 0 ? 'personne encore' : '$n présent${n > 1 ? 's' : ''}';
  if (e.kind == EventKind.venue && e.venueName != null) {
    return '${e.venueName} · $presents';
  }
  return 'En cours · $presents';
}

class _Titre extends StatelessWidget {
  const _Titre(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(text, style: context.sectionTitle),
  );
}

class _Chargement extends StatelessWidget {
  const _Chargement();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: TextStyle(color: context.muted)),
        ?action,
      ],
    ),
  );
}
