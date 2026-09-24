import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/top_banner.dart';
import '../proximity/geo/live_position.dart';
import 'create_event_screen.dart';
import 'event_finder_screen.dart';
import 'event_screen.dart';
import 'events_map_screen.dart';
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
/// 3. **autour de moi** — les soirées à portée, d'établissement ou ouvertes
///    par quelqu'un (2026-09-21), avec la distance et **« N personnes
///    connectées ici »**. C'est le « je me balade dans la rue » de Jay.
///
/// ⚠️ Cet écran ne parle à aucun serveur : il lit des vues
/// (`events_providers.dart`) et demande à la cuisine (`events_repository.dart`).
class EventsScreen extends ConsumerWidget {
  const EventsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final events = ref.watch(myEventsProvider);
    final nearby = ref.watch(nearbyEventsProvider);
    final currentId = ref.watch(currentEventIdProvider);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Événements'),
        actions: [
          // La carte (2026-09-21) : les soirées à portée, posées sur un plan.
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Carte',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const EventsMapScreen())),
          ),
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
          ref.invalidate(nearbyEventsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (currentId != null) _EnCours(eventId: currentId),
            // Le radar de l'arrivée en soirée (2026-09-24) : l'entrée
            // principale quand on n'est dans aucune soirée.
            if (currentId == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: FilledButton.icon(
                  icon: const Icon(Icons.radar_rounded),
                  label: const Text('Trouver ma soirée'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const EventFinderScreen(),
                    ),
                  ),
                ),
              ),
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
                  onPressed: () => ref.invalidate(nearbyEventsProvider),
                  child: const Text('Réessayer'),
                ),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return const _Message(
                    'Aucune soirée à moins de 2 km. Ouvre la tienne là où tu '
                    'es (« + »), ou reviens quand tu passes devant un lieu '
                    'partenaire.',
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
        child: Icon(switch (event.kind) {
          EventKind.venue => Icons.storefront,
          EventKind.open => Icons.celebration,
          EventKind.private =>
            event.autoCreated ? Icons.auto_awesome : Icons.group,
        }, color: p.ink),
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
  final NearbyEvent venue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final presents = venue.presentCount;
    final ouvert = venue.kind == EventKind.open;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: p.field,
        child: Icon(
          ouvert ? Icons.celebration : Icons.storefront,
          color: p.ink,
        ),
      ),
      title: Text(venue.title),
      // « Tel événement, N personnes connectées ici » (Jay, 2026-09-21) —
      // vérifié par le serveur à chaque relevé de présence.
      subtitle: Text(
        '${venue.venueName ?? 'Soirée ouverte'} · à ${venue.distanceM} m · '
        '$presents connecté${presents > 1 ? 's' : ''} ici',
      ),
      // ⚠️ **Plus de bouton « Je suis là » ici (2026-09-24).** Un bouton plein
      // réclame toute la largeur (`Size.fromHeight` du thème) : posé en
      // `trailing`, il écrasait le titre jusqu'à une lettre par ligne. Toucher
      // la tuile ouvre « Tu es au … » (`VenueFoundView`), qui a SON bouton
      // « Rejoindre la soirée » — un seul chemin pour entrer, validé par Jay.
      trailing: venue.withinReach
          ? Icon(Icons.chevron_right_rounded, color: p.action)
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
  final fix = await ref.read(livePositionProvider.notifier).current();
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
