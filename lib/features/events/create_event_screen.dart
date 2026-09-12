import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/top_banner.dart';
import '../connections/connections_repository.dart';
import '../proximity/geo/coarse_location.dart';
import 'event_screen.dart';
import 'events_repository.dart';

/// **Créer un événement privé** — un groupe d'événement éphémère, construit
/// pour l'occasion (Jay, 2026-09-12 : *« jamais un groupe existant »*).
///
/// Ce qu'on choisit ici, et rien de plus :
///
/// - un **nom** ;
/// - **quand** — maintenant, ou une date ;
/// - **où** — facultatif : ma position actuelle (un voyage n'a pas de lieu) ;
/// - **qui** — mes amis, au sens strict. Le serveur refuse tout autre nom.
///
/// Les invités sont **admin par défaut** ; le créateur règle ensuite depuis
/// l'événement (« comme sur WhatsApp »).
class CreateEventScreen extends ConsumerStatefulWidget {
  const CreateEventScreen({super.key});

  @override
  ConsumerState<CreateEventScreen> createState() => _CreateEventScreenState();
}

class _CreateEventScreenState extends ConsumerState<CreateEventScreen> {
  final _title = TextEditingController();
  final _selected = <String>{};
  DateTime? _startsAt;
  CoarseFix? _place;
  var _placeBusy = false;
  var _loading = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: _startsAt ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startsAt ?? now),
    );
    if (time == null) return;
    setState(() {
      _startsAt = DateTime(
        day.year,
        day.month,
        day.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _usePlace() async {
    setState(() => _placeBusy = true);
    final fix = await ref.read(coarseLocationProvider).current();
    if (!mounted) return;
    setState(() {
      _placeBusy = false;
      _place = fix;
    });
    if (fix == null) {
      TopBanner.show(
        context,
        'Pas de position : active la localisation.',
        tone: TopBannerTone.already,
      );
    }
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      TopBanner.show(
        context,
        'Donne un nom à ton événement.',
        tone: TopBannerTone.already,
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final id = await ref
          .read(eventsRepositoryProvider)
          .createPrivate(
            title: title,
            startsAt: _startsAt,
            lat: _place?.latitude,
            lon: _place?.longitude,
            memberIds: _selected.toList(),
          );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => EventScreen(eventId: id)),
      );
    } catch (e) {
      if (!mounted) return;
      TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendProfilesProvider);
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Nouvel événement'),
        actions: [
          TextButton(
            onPressed: _loading ? null : _create,
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Créer'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nom',
              hintText: 'Soirée chez Léa, week-end à Lisbonne…',
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: const Text('Quand'),
            subtitle: Text(
              _startsAt == null ? 'Maintenant' : dayAndTime(_startsAt!),
            ),
            trailing: _startsAt == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Maintenant',
                    onPressed: () => setState(() => _startsAt = null),
                  ),
            onTap: _pickDate,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined),
            title: const Text('Où'),
            subtitle: Text(
              _place == null
                  ? 'Aucun lieu fixe — les présents font le lieu'
                  : 'Ma position actuelle (± ${_place!.accuracy.round()} m)',
            ),
            trailing: _placeBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _place == null
                ? TextButton(
                    onPressed: _usePlace,
                    child: const Text('Ma position'),
                  )
                : IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Retirer le lieu',
                    onPressed: () => setState(() => _place = null),
                  ),
          ),
          const SizedBox(height: 8),
          Text('Inviter des amis', style: context.sectionTitle),
          Text(
            'Ils pourront à leur tour inviter leurs amis, sauf si tu le '
            'désactives dans les réglages de l\'événement.',
            style: TextStyle(color: context.muted),
          ),
          const SizedBox(height: 8),
          friends.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text(messageServeur(e)),
            data: (map) {
              final list = map.values.toList()
                ..sort((a, b) => a.chatName.compareTo(b.chatName));
              if (list.isEmpty) {
                return Text(
                  'Pas encore d\'amis à inviter.',
                  style: TextStyle(color: context.muted),
                );
              }
              return Column(
                children: [
                  for (final Profile f in list)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _selected.contains(f.id),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(f.id);
                        } else {
                          _selected.remove(f.id);
                        }
                      }),
                      secondary: Avatar(
                        stored: f.avatarUrl,
                        radius: 20,
                        fallback: Text(
                          f.chatName.characters.first.toUpperCase(),
                        ),
                      ),
                      title: Text(f.chatName),
                      activeColor: p.action,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
