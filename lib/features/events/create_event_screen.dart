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
import '../proximity/geo/live_position.dart';
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

  /// Le nom du lieu (2026-09-25) — il figurera sur les Vibes du Drop.
  final _placeName = TextEditingController();
  final _selected = <String>{};
  DateTime? _startsAt;
  CoarseFix? _place;
  var _placeBusy = false;
  var _loading = false;

  /// **Ouverte à tous ceux qui sont là** (2026-09-21) : pas d'invités, on y
  /// entre sur place ; visible de qui passe à portée. Là où je suis, tout de
  /// suite, et une heure de fin.
  var _open = false;
  var _openHours = 4;

  @override
  void dispose() {
    _title.dispose();
    _placeName.dispose();
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

  /// Au-delà, un lieu ne situe pas une soirée : il la place dans le
  /// quartier d'à côté (et les gens sur place ne la trouveraient pas).
  static const _maxPlaceAccuracyM = 100.0;

  /// 🔴 **Créer une soirée exige la position PRÉCISE** (Jay, 2026-09-24 :
  /// *« on peut créer un événement sans la localisation précise ? Ça c'est
  /// non »*). L'« approximative » d'Android brouille exprès à ~2 km : une
  /// soirée posée ainsi est introuvable pour ceux qui sont vraiment là.
  ///
  /// Relit ce qu'Android accorde MAINTENANT (la permission change à chaque
  /// installation, RAPPELS #162) ; sinon la demande, et dit pourquoi.
  Future<bool> _precise() async {
    final position = ref.read(livePositionProvider.notifier);
    await position.relisPrecision();
    if (ref.read(livePositionProvider).precision == LocationPrecision.precise) {
      return true;
    }
    if (!mounted) return false;
    TopBanner.show(
      context,
      'Pour créer une soirée, active la position précise : l\'approximative '
      'la placerait à 2 km.',
      tone: TopBannerTone.already,
    );
    await position.requestPrecise();
    return ref.read(livePositionProvider).precision ==
        LocationPrecision.precise;
  }

  Future<void> _usePlace() async {
    setState(() => _placeBusy = true);
    if (!await _precise()) {
      if (mounted) setState(() => _placeBusy = false);
      return;
    }
    final fix = await ref.read(livePositionProvider.notifier).current();
    if (!mounted) return;
    final tooVague = fix != null && fix.accuracy > _maxPlaceAccuracyM;
    setState(() {
      _placeBusy = false;
      _place = tooVague ? null : fix;
    });
    if (fix == null) {
      TopBanner.show(
        context,
        'Pas de position : active la localisation.',
        tone: TopBannerTone.already,
      );
    } else if (tooVague) {
      TopBanner.show(
        context,
        'Position trop imprécise (± ${fix.accuracy.round()} m). Approche-toi '
        'd\'une fenêtre ou sors, puis réessaie.',
        tone: TopBannerTone.already,
      );
    }
  }

  Future<void> _create() async {
    // La position précise d'abord, pour TOUTE soirée (même sans lieu fixe).
    if (!await _precise() || !mounted) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      TopBanner.show(
        context,
        'Donne un nom à ton événement.',
        tone: TopBannerTone.already,
      );
      return;
    }
    if (_open && _place == null) {
      TopBanner.show(
        context,
        'Une soirée ouverte a un lieu : là où tu es. Relève ta position.',
        tone: TopBannerTone.already,
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final repo = ref.read(eventsRepositoryProvider);
      final id = _open
          ? await repo.createOpen(
              title: title,
              lat: _place!.latitude,
              lon: _place!.longitude,
              accuracy: _place!.accuracy,
              endsAt: DateTime.now().add(Duration(hours: _openHours)),
              placeName: _placeName.text,
            )
          : await repo.createPrivate(
              title: title,
              startsAt: _startsAt,
              lat: _place?.latitude,
              lon: _place?.longitude,
              accuracy: _place?.accuracy,
              memberIds: _selected.toList(),
              placeName: _placeName.text,
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
          TextField(
            controller: _placeName,
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Nom du lieu (facultatif)',
              hintText: "Le Sucre, chez Léa, le parc de la Tête d'Or…",
              helperText: 'Il figurera sur les Vibes du Drop.',
            ),
          ),
          const SizedBox(height: 8),
          // Deux origines, deux règles d'entrée — le choix se fait ICI, et
          // tout le reste de l'écran en découle.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _open,
            onChanged: (v) => setState(() => _open = v),
            title: const Text('Ouverte à tous ceux qui sont là'),
            subtitle: Text(
              _open
                  ? 'Visible de qui passe à portée ; on y entre sur place. '
                        'Pas d\'invités.'
                  : 'Privée : tes amis invités, sur place.',
              style: TextStyle(color: context.muted),
            ),
            activeThumbColor: p.action,
          ),
          if (_open)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Jusqu\'à'),
              subtitle: Text(
                'Dans $_openHours h — '
                '${dayAndTime(DateTime.now().add(Duration(hours: _openHours)))}',
              ),
              trailing: DropdownButton<int>(
                value: _openHours,
                underline: const SizedBox.shrink(),
                items: [
                  for (final h in const [1, 2, 3, 4, 6, 8, 12, 24])
                    DropdownMenuItem(value: h, child: Text('$h h')),
                ],
                onChanged: (v) => setState(() => _openHours = v ?? 4),
              ),
            )
          else
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
                  ? (_open
                        ? 'Là où tu es — relève ta position'
                        : 'Aucun lieu fixe — les présents font le lieu')
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
          if (_open)
            Text(
              'Pas d\'invitations : ceux qui passent la voient et entrent en '
              'étant sur place. Tu pourras la fermer depuis l\'événement.',
              style: TextStyle(color: context.muted),
            ),
          if (!_open) ...[
            Text('Inviter des amis', style: context.sectionTitle),
            Text(
              'Ils pourront à leur tour inviter leurs amis, sauf si tu le '
              'désactives dans les réglages de l\'événement.',
              style: TextStyle(color: context.muted),
            ),
          ],
          const SizedBox(height: 8),
          if (!_open)
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
