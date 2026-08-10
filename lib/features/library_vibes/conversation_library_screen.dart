import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/library_vibe.dart';
import '../../core/theme.dart';
import '../../core/utils/formats.dart';
import 'library_vibes_repository.dart';
import 'revealed_vibe_screen.dart';

/// Bibliothèque éphémère d'une conversation — **albums datés** (consigne Jay
/// 2026-08-10), le plus récent en premier.
///
/// Avant 18h30, les vibes du jour s'affichent en placeholder : l'image réduite
/// à 20 px, ré-agrandie. Il n'y a rien à en tirer, l'information a été détruite
/// à la source. Après le reveal, une tuile s'ouvre sur l'image véritable.
class ConversationLibraryScreen extends ConsumerWidget {
  const ConversationLibraryScreen({
    super.key,
    required this.conversationId,
    required this.title,
  });

  final String conversationId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vibes = ref.watch(conversationLibraryProvider(conversationId));

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: vibes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Empty(
          icon: Icons.error_outline,
          message: 'Impossible de charger la bibliothèque.\n$e',
        ),
        data: (list) {
          if (list.isEmpty) {
            return const _Empty(
              icon: Icons.collections_outlined,
              message:
                  'Rien pour l\'instant.\nAjoute une vibe : elle se révélera '
                  'à 18h30, pour tout le monde en même temps.',
            );
          }

          // Regroupement par album : la date locale du reveal, pas celle de la
          // prise — la journée de collecte va de 18h30 à 18h30.
          final albums = <DateTime, List<LibraryVibe>>{};
          for (final v in list) {
            albums.putIfAbsent(v.albumDay, () => []).add(v);
          }
          final days = albums.keys.toList()..sort((a, b) => b.compareTo(a));

          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 32),
            itemCount: days.length,
            itemBuilder: (context, i) {
              final day = days[i];
              final items = albums[day]!;
              return _Album(
                day: day,
                vibes: items,
                onRefresh: () =>
                    ref.invalidate(conversationLibraryProvider(conversationId)),
              );
            },
          );
        },
      ),
    );
  }
}

class _Album extends StatelessWidget {
  const _Album({
    required this.day,
    required this.vibes,
    required this.onRefresh,
  });

  final DateTime day;
  final List<LibraryVibe> vibes;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final revealed = vibes.first.revealed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  albumDayLabel(day),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!revealed)
                Row(
                  children: [
                    Icon(
                      Icons.lock_clock_outlined,
                      size: 15,
                      color: context.faint,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '18h30',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: context.faint),
                    ),
                  ],
                ),
            ],
          ),
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 9 / 16,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: vibes.length,
          itemBuilder: (_, i) =>
              _VibeTile(vibe: vibes[i], onRefresh: onRefresh),
        ),
      ],
    );
  }
}

class _VibeTile extends ConsumerStatefulWidget {
  const _VibeTile({required this.vibe, required this.onRefresh});
  final LibraryVibe vibe;
  final VoidCallback onRefresh;

  @override
  ConsumerState<_VibeTile> createState() => _VibeTileState();
}

class _VibeTileState extends ConsumerState<_VibeTile> {
  Uint8List? _placeholder;

  /// Octets scellés préchargés. Illisibles sans la clé : les garder en mémoire
  /// n'expose rien, et évite un téléchargement au moment du reveal.
  Uint8List? _sealed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(libraryVibesRepositoryProvider);
    try {
      final bytes = await repo.placeholderBytes(widget.vibe);
      if (mounted) setState(() => _placeholder = bytes);
    } catch (_) {
      // Placeholder indisponible : la tuile reste un cadre neutre.
    }
    // Préchargement dès que le serveur ouvre, soit 5 minutes avant l'heure.
    if (widget.vibe.prefetchable) {
      try {
        final sealed = await repo.prefetchSealed(widget.vibe);
        if (mounted) setState(() => _sealed = sealed);
      } catch (_) {
        // Refus du serveur : on réessaiera à l'ouverture.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vibe = widget.vibe;
    final revealed = vibe.revealed;

    return GestureDetector(
      onTap: revealed
          ? () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      RevealedVibeScreen(vibe: vibe, sealedBytes: _sealed),
                ),
              );
              widget.onRefresh();
            }
          : () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Patience — tout se découvre à 18h30.'),
              ),
            ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: _placeholder == null
                  ? null
                  : Image.memory(
                      _placeholder!,
                      fit: BoxFit.cover,
                      // L'image fait 20 px de large : sans ce filtrage, elle
                      // s'afficherait en gros carrés nets plutôt qu'en dégradé
                      // doux. C'est ce lissage qui donne l'aspect « flouté ».
                      filterQuality: FilterQuality.medium,
                    ),
            ),
            if (!revealed)
              const Center(
                child: Icon(
                  Icons.lock_outline,
                  color: Colors.white70,
                  size: 22,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: context.ghost),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.muted),
            ),
          ],
        ),
      ),
    );
  }
}
