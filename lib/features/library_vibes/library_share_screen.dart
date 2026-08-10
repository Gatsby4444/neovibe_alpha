import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/card.dart';
import '../../core/theme.dart';
import '../cards/cards_repository.dart';
import 'library_target.dart';
import 'library_vibes_repository.dart';

/// Écran de partage vers une **bibliothèque éphémère** — volontairement pauvre.
///
/// Il remplace le récap habituel, et surtout : **il ne montre pas la prise**.
/// L'auteur ne revoit pas ce qu'il vient de capturer, c'est le cœur du format
/// (consigne Jay 2026-08-10). Voir `docs/bibliotheques-ephemeres.md`.
///
/// Trois réglages seulement, et pas de bouton « sauvegarder en perso » : il
/// entrait en conflit avec « même l'envoyeur ne voit pas ses ajouts » — il
/// aurait suffi de le cocher pour contourner la règle. La sauvegarde se fait
/// dans la bibliothèque, **au reveal**, et vaut pour tous les membres.
class LibraryShareScreen extends ConsumerStatefulWidget {
  const LibraryShareScreen({
    super.key,
    required this.front,
    this.back,
    required this.type,
    required this.target,
    this.frontIsVideo = false,
    this.backIsVideo = false,
  });

  final File front;
  final File? back;
  final CardType type;
  final LibraryTarget target;
  final bool frontIsVideo;
  final bool backIsVideo;

  @override
  ConsumerState<LibraryShareScreen> createState() => _LibraryShareScreenState();
}

class _LibraryShareScreenState extends ConsumerState<LibraryShareScreen> {
  bool _saveableByOthers = false;

  /// Faux = souvenir (la vibe reste dans la bibliothèque). C'est le DÉFAUT
  /// voulu par Jay : le but est une bibliothèque souvenir, l'éphémère est
  /// l'exception qu'on choisit.
  bool _ephemeral = false;

  bool _busy = false;
  String? _error;

  Future<void> _add() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // La vibe est d'abord créée comme n'importe quelle Card : c'est le même
      // objet, seule sa destination change.
      final card = await ref
          .read(cardsRepositoryProvider)
          .create(
            front: widget.front,
            back: widget.back,
            type: widget.type,
            saveable: _saveableByOthers,
            frontIsVideo: widget.frontIsVideo,
            backIsVideo: widget.backIsVideo,
          );

      await ref
          .read(libraryVibesRepositoryProvider)
          .addVibe(
            conversationId: widget.target.conversationId,
            cardId: card.id,
            source: widget.front,
            isVideo: widget.frontIsVideo,
            saveableByOthers: _saveableByOthers,
            ephemeral: _ephemeral,
          );

      ref.invalidate(conversationLibraryProvider(widget.target.conversationId));
      if (!mounted) return;
      // Retour au chat, en fermant capture et partage d'un coup.
      Navigator.of(context).popUntil((route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ajoutée — visible à 18h30 ✓')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    return Scaffold(
      appBar: AppBar(title: const Text('Ajouter à la bibliothèque')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          Icon(
            Icons.lock_clock_outlined,
            size: 44,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text(
            'Personne ne la verra avant 18h30 — toi non plus.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'C\'est pour ça qu\'il n\'y a pas d\'aperçu.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: context.muted),
          ),
          const SizedBox(height: 28),

          FilledButton.icon(
            onPressed: _busy ? null : _add,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_photo_alternate_outlined),
            label: Text(
              // Le nom du GROUPE est porté par le bouton lui-même ; en DM il
              // passe en dessous, en petit (consigne Jay).
              target.isGroup
                  ? 'Ajouter à ${target.label}'
                  : 'Ajouter à la bibliothèque',
            ),
          ),
          if (!target.isGroup) ...[
            const SizedBox(height: 8),
            Text(
              '${target.label} la verra',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.faint),
            ),
          ],

          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],

          const SizedBox(height: 28),
          const Divider(),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sauvegardable par les autres'),
            subtitle: Text(
              'Ils pourront la garder après le reveal. Toi, tu le peux '
              'toujours.',
              style: TextStyle(color: context.muted),
            ),
            value: _saveableByOthers,
            onChanged: _busy
                ? null
                : (v) => setState(() => _saveableByOthers = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Éphémère'),
            subtitle: Text(
              _ephemeral
                  ? 'Elle disparaîtra 24 h après le reveal.'
                  : 'Elle restera dans la bibliothèque souvenir.',
              style: TextStyle(color: context.muted),
            ),
            value: _ephemeral,
            onChanged: _busy ? null : (v) => setState(() => _ephemeral = v),
          ),
        ],
      ),
    );
  }
}
