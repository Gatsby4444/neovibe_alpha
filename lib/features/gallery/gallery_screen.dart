import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/content/saved_store.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/vibe_face.dart';
import '../cards/saved_items_screen.dart';

/// **Ma galerie** — les Vibes, datées et situées (Jay, 2026-09-25).
///
/// > « Le but n'est pas d'afficher à nouveau la porte d'entrée vers le récap
/// > de l'événement, mais uniquement les Vibes datées et localisées. On peut
/// > tout voir directement ; on peut aussi trier pour n'afficher que les
/// > événements, et retrouver une date ou un lieu précis. »
///
/// Ce qu'elle montre, et seulement ça (décisions du même jour) :
/// - **les Vibes que j'ai enregistrées moi-même** (« Enregistrer ») — jamais
///   une Vibe gardée à mon insu (règle du 2026-09-20) ;
/// - **les Vibes des Drops d'événement où j'étais**, sauf les éphémères,
///   gardées à la fermeture par `GalleryKeeper`.
///
/// Tout vient du téléphone ([savedItemsProvider]) : rien n'y dépend du
/// serveur, tout s'ouvre hors ligne. Le récap d'une soirée vit dans
/// l'historique des événements (`EventHistoryScreen`), plus ici.
///
/// Remplace aussi l'ancien écran « Enregistrements » : les mêmes Vibes par
/// deux écrans, c'étaient deux chemins vers une même donnée.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  /// Tout, ou les Vibes des soirées seulement, rangées par soirée.
  var _soirees = false;
  DateTime? _jour;
  String? _lieu;

  static DateTime _jourDe(DateTime d) {
    final l = d.toLocal();
    return DateTime(l.year, l.month, l.day);
  }

  List<SavedItem> _filtrer(List<SavedItem> tout) => [
    for (final s in tout)
      if ((!_soirees || s.fromEvent) &&
          (_jour == null || _jourDe(s.when) == _jour) &&
          (_lieu == null || s.where == _lieu))
        s,
  ]..sort((a, b) => b.when.compareTo(a.when));

  Future<void> _choisirJour(List<SavedItem> tout) async {
    if (tout.isEmpty) return;
    final jours = tout.map((s) => _jourDe(s.when)).toList()..sort();
    final choisi = await showDatePicker(
      context: context,
      initialDate: _jour ?? jours.last,
      firstDate: jours.first,
      lastDate: jours.last,
      helpText: 'Retrouver un jour',
      // Seuls les jours où il y a une Vibe se choisissent.
      selectableDayPredicate: (d) => jours.contains(_jourDe(d)),
    );
    if (choisi != null) setState(() => _jour = _jourDe(choisi));
  }

  Future<void> _choisirLieu(List<SavedItem> tout) async {
    final compte = <String, int>{};
    for (final s in tout) {
      final w = s.where;
      if (w != null) compte[w] = (compte[w] ?? 0) + 1;
    }
    final lieux = compte.keys.toList()
      ..sort((a, b) => compte[b]!.compareTo(compte[a]!));
    final choisi = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: lieux.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(NeoSpace.xl),
                child: Text(
                  'Aucune Vibe n\'a encore de lieu.',
                  style: TextStyle(color: context.muted),
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final l in lieux)
                    ListTile(
                      leading: const Icon(Icons.place_outlined),
                      title: Text(l),
                      trailing: Text(
                        '${compte[l]}',
                        style: TextStyle(color: context.muted),
                      ),
                      onTap: () => Navigator.pop(context, l),
                    ),
                ],
              ),
      ),
    );
    if (choisi != null) setState(() => _lieu = choisi);
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(savedItemsProvider);
    final tout = items.value ?? const <SavedItem>[];
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Ma galerie'),
        actions: [
          IconButton(
            tooltip: 'Retrouver un jour',
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: () => _choisirJour(tout),
          ),
          IconButton(
            tooltip: 'Retrouver un lieu',
            icon: const Icon(Icons.place_outlined),
            onPressed: () => _choisirLieu(tout),
          ),
        ],
      ),
      body: items.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (_) {
          final vues = _filtrer(tout);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _barre()),
              if (vues.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _vide(tout.isEmpty),
                )
              else
                for (final g in _grouper(vues)) ...[
                  SliverToBoxAdapter(child: _EnTete(groupe: g)),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NeoSpace.lg,
                    ),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: kVibeFaceRatio,
                          ),
                      delegate: SliverChildBuilderDelegate(
                        (_, i) => _Tuile(item: g.items[i], soirees: _soirees),
                        childCount: g.items.length,
                      ),
                    ),
                  ),
                ],
              const SliverToBoxAdapter(child: SizedBox(height: NeoSpace.xxl)),
            ],
          );
        },
      ),
    );
  }

  /// Tout · Soirées, et les filtres actifs (qui se retirent d'un appui).
  Widget _barre() => Padding(
    padding: const EdgeInsets.fromLTRB(
      NeoSpace.lg,
      NeoSpace.sm,
      NeoSpace.lg,
      0,
    ),
    child: Wrap(
      spacing: NeoSpace.sm,
      runSpacing: NeoSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Tout')),
            ButtonSegment(value: true, label: Text('Soirées')),
          ],
          selected: {_soirees},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _soirees = s.first),
        ),
        if (_jour != null)
          InputChip(
            avatar: const Icon(Icons.calendar_month_outlined, size: 16),
            label: Text(albumDayLabel(_jour!)),
            onDeleted: () => setState(() => _jour = null),
          ),
        if (_lieu != null)
          InputChip(
            avatar: const Icon(Icons.place_outlined, size: 16),
            label: Text(_lieu!),
            onDeleted: () => setState(() => _lieu = null),
          ),
      ],
    ),
  );

  Widget _vide(bool rienDuTout) => Padding(
    padding: const EdgeInsets.all(32),
    child: Center(
      child: Text(
        rienDuTout
            ? 'Rien encore.\nLes Vibes que tu enregistres, et celles des '
                  'soirées où tu vas, arrivent ici — avec leur date et leur '
                  'lieu.'
            : 'Aucune Vibe pour ce choix.',
        textAlign: TextAlign.center,
        style: TextStyle(color: context.muted),
      ),
    ),
  );

  /// Par jour (Tout), ou par soirée (Soirées) — les groupes dans l'ordre
  /// de leur Vibe la plus récente.
  List<_Groupe> _grouper(List<SavedItem> vues) {
    final groupes = <String, _Groupe>{};
    for (final s in vues) {
      final cle = _soirees ? s.eventId! : _jourDe(s.when).toIso8601String();
      (groupes[cle] ??= _Groupe(
        titre: _soirees
            ? (s.eventTitle ?? 'Soirée')
            : albumDayLabel(_jourDe(s.when)),
        sousTitre: _soirees
            ? [
                if (s.where != null) s.where!,
                albumDayLabel(_jourDe(s.when)),
              ].join(' · ')
            : null,
      )).items.add(s);
    }
    return groupes.values.toList();
  }
}

class _Groupe {
  _Groupe({required this.titre, this.sousTitre});
  final String titre;
  final String? sousTitre;
  final items = <SavedItem>[];
}

class _EnTete extends StatelessWidget {
  const _EnTete({required this.groupe});
  final _Groupe groupe;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NeoSpace.lg,
      NeoSpace.lg,
      NeoSpace.lg,
      NeoSpace.sm,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(groupe.titre, style: context.sectionTitle),
        if (groupe.sousTitre != null && groupe.sousTitre!.isNotEmpty)
          Text(
            groupe.sousTitre!,
            style: TextStyle(color: context.muted, fontSize: 12),
          ),
      ],
    ),
  );
}

/// Une Vibe de la galerie : sa vignette, et en bas son lieu (et sa soirée
/// quand on regarde « Tout »).
class _Tuile extends StatelessWidget {
  const _Tuile({required this.item, required this.soirees});
  final SavedItem item;
  final bool soirees;

  @override
  Widget build(BuildContext context) {
    final legende = [
      if (!soirees && item.eventTitle != null) item.eventTitle!,
      if (!soirees && item.where != null) item.where!,
      if (soirees) shortTime(item.when.toLocal()),
    ].join(' · ');
    return Stack(
      fit: StackFit.expand,
      children: [
        SavedTile(item: item),
        if (legende.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.fromLTRB(6, 14, 6, 5),
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(12),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Text(
                  legende,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 10.5),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
