import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/library_vibe.dart';
import '../../core/clock.dart';
import '../../core/theme.dart';
import '../../core/utils/formats.dart';
import 'library_vibes_repository.dart';
import 'masked_placeholder.dart';
import 'vibe_faces_screen.dart';
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

class _Album extends ConsumerWidget {
  const _Album({
    required this.day,
    required this.vibes,
    required this.onRefresh,
  });

  final DateTime day;
  final List<LibraryVibe> vibes;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 🔴 **L'HEURE EST UNE SOURCE — 2026-08-31.**
    //
    // Ce widget lisait `vibes.first.revealed`, qui appelait `DateTime.now()`.
    // Un `build` ne se rejoue que si l'une de ses sources change, et l'heure
    // n'en était pas une : **le reveal ne se produisait pas à l'écran**.
    // Quelqu'un qui attend 18h30 devant sa bibliothèque voyait les vibes
    // rester masquées jusqu'à un événement sans rapport.
    //
    // `expiryClockProvider` bat toutes les 5 s ; il ne reconstruit que ce qui
    // le surveille, et seulement quand son résultat change.
    final revealed = vibes.first.revealedAt(ref.watch(expiryClockProvider));

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
    //
    // Les octets vont désormais sur le DISQUE et non dans l'état de cette
    // tuile : ils survivent donc à la fermeture de l'écran, au retour dans la
    // conversation et au redémarrage de l'app. C'est ce qui rend vraie la
    // formule de Jay — « comme si les cards étaient toujours là mais qu'elles
    // étaient juste bloquées en local ». Tant qu'ils vivaient ici, l'illusion
    // ne tenait que le temps où l'on restait sur la bibliothèque.
    //
    // Les DEUX faces, et sans `setState` : rien à réafficher, le fichier est
    // simplement là pour l'ouverture qui suivra.
    await repo.prefetch(widget.vibe);
  }

  @override
  Widget build(BuildContext context) {
    final vibe = widget.vibe;
    // Même raison que dans [_Album] : sans horloge surveillée, la tuile reste
    // masquée après l'heure du reveal.
    final revealed = vibe.revealedAt(ref.watch(expiryClockProvider));

    return GestureDetector(
      // Ouvrable À TOUT MOMENT depuis le 2026-08-10 (demande de Jay) : avant le
      // reveal on ouvre les faces floutées, qu'on peut retourner. L'écran de
      // dissipation ne sert qu'au tout premier dévoilement.
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => revealed
                ? RevealedVibeScreen(
                    vibe: vibe,
                    // Passé pour que l'écran de reveal démarre sur EXACTEMENT
                    // ce que montrait la tuile : pas de rupture à l'ouverture.
                    placeholderBytes: _placeholder,
                  )
                : VibeFacesScreen(vibe: vibe, frontPlaceholder: _placeholder),
          ),
        );
        widget.onRefresh();
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: _placeholder == null
                  ? null
                  : (revealed
                        ? Image.memory(_placeholder!, fit: BoxFit.cover)
                        : MaskedPlaceholder(bytes: _placeholder!, sigma: 7)),
            ),
            if (!revealed)
              // Le cadenas se pose sur DEUX fonds différents : une photo
              // floutée, ou — quand il n'y a pas encore d'aperçu — une surface
              // du thème, donc claire en thème clair. Le blanc seul y
              // disparaissait. L'ombre lui donne son propre fond et le rend
              // lisible sur les deux, sans avoir à savoir lequel est dessous.
              const Center(
                child: Icon(
                  Icons.lock_outline,
                  color: Colors.white,
                  size: 22,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
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
