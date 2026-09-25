import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/top_banner.dart';
import '../proximity/geo/live_position.dart';
import 'event_poster.dart';
import 'event_size_picker.dart';
import 'events_providers.dart';
import 'events_repository.dart';

/// **Les réglages du créateur** — « comme sur WhatsApp » (Jay, 2026-09-12) :
/// les invités sont admin par défaut, et c'est ici que le créateur change
/// les règles initiales. Un gérant d'établissement y règle sa soirée.
///
/// Chaque interrupteur écrit tout de suite : pas de bouton « Enregistrer »,
/// le réglage vaut parce qu'il est posé.
class EventSettingsScreen extends ConsumerStatefulWidget {
  const EventSettingsScreen({super.key, required this.eventId});
  final String eventId;

  @override
  ConsumerState<EventSettingsScreen> createState() =>
      _EventSettingsScreenState();
}

class _EventSettingsScreenState extends ConsumerState<EventSettingsScreen> {
  var _busy = false;

  Future<void> _apply(Future<void> Function(EventsRepository) run) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await run(ref.read(eventsRepositoryProvider));
    } catch (e) {
      if (mounted) {
        TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(NeoEvent event) async {
    final controller = TextEditingController(text: event.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nom de l\'événement'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty || title == event.title) return;
    await _apply((r) => r.updateSettings(event.id, title: title));
  }

  Future<void> _pickEnd(NeoEvent event) async {
    final now = DateTime.now();
    final initial = event.scheduledEndAt ?? now.add(const Duration(hours: 4));
    final day = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    final end = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    await _apply((r) => r.updateSettings(event.id, endsAt: end));
  }

  Future<void> _usePlace(NeoEvent event) async {
    final fix = await ref.read(livePositionProvider.notifier).current();
    if (fix == null) {
      if (mounted) {
        TopBanner.show(
          context,
          'Pas de position : active la localisation.',
          tone: TopBannerTone.already,
        );
      }
      return;
    }
    await _apply(
      (r) => r.updateSettings(event.id, lat: fix.latitude, lon: fix.longitude),
    );
  }

  @override
  Widget build(BuildContext context) {
    final event = ref.watch(eventByIdProvider(widget.eventId));
    if (event == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final prive = event.kind == EventKind.private;
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: const Text('Réglages')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Nom'),
            subtitle: Text(event.title),
            onTap: _busy ? null : () => _rename(event),
          ),
          // L'affiche et la description (2026-09-25) : ce que voient ceux
          // qui passent, dans le radar.
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Affiche et description'),
            subtitle: Text(
              event.posterPath == null && event.description == null
                  ? "Aucune — ajoute-les pour qu'on reconnaisse ta soirée"
                  : (event.description ?? 'Affiche posée'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: _busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EventProfileEditScreen(
                        eventId: event.id,
                        title: event.title,
                        description: event.description,
                        posterPath: event.posterPath,
                      ),
                    ),
                  ),
          ),
          // La taille (2026-09-25) : jusqu'où l'on entre, et d'où l'on sort.
          if (event.hasPlace)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: EventSizePicker(
                value: EventSize.fromRadius(event.radiusM) ?? EventSize.bar,
                onChanged: _busy
                    ? null
                    : (s) => _apply((r) => r.setSize(event.id, s)),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: Text(prive ? 'Fin prévue' : 'Horaire de fermeture'),
            subtitle: Text(
              event.scheduledEndAt == null
                  ? (prive
                        ? 'Aucune — l\'événement se ferme quand 80 % des '
                              'participants sont partis'
                        : 'Aucun')
                  : dayAndTime(event.scheduledEndAt!),
            ),
            onTap: _busy ? null : () => _pickEnd(event),
          ),
          if (prive)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: const Text('Lieu'),
              subtitle: Text(
                event.hasPlace
                    ? 'Un lieu fixe est déclaré'
                    : 'Aucun lieu fixe — les présents font le lieu',
              ),
              trailing: event.hasPlace
                  ? TextButton(
                      onPressed: _busy
                          ? null
                          : () => _apply(
                              (r) =>
                                  r.updateSettings(event.id, clearPlace: true),
                            ),
                      child: const Text('Retirer'),
                    )
                  : TextButton(
                      onPressed: _busy ? null : () => _usePlace(event),
                      child: const Text('Ma position'),
                    ),
            ),
          if (prive) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Les invités', style: context.sectionTitle),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.person_add_alt_1),
              title: const Text('Peuvent inviter leurs amis'),
              subtitle: const Text(
                'Chaque admin peut ajouter ses propres amis.',
              ),
              value: event.membersCanAdd,
              onChanged: _busy
                  ? null
                  : (v) => _apply(
                      (r) => r.updateSettings(event.id, membersCanAdd: v),
                    ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.person_remove_alt_1),
              title: const Text('Peuvent retirer des gens'),
              subtitle: const Text('Chaque admin peut retirer un invité.'),
              value: event.membersCanRemove,
              onChanged: _busy
                  ? null
                  : (v) => _apply(
                      (r) => r.updateSettings(event.id, membersCanRemove: v),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                'Les rôles se règlent personne par personne, depuis la liste '
                'de l\'événement.',
                style: TextStyle(color: context.muted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
