import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/library_vibe.dart';
import '../cards/flippable_card.dart';
import 'library_vibes_repository.dart';
import 'masked_placeholder.dart';

/// Ouverture d'une vibe **en grand**, révélée ou non, avec bascule de face.
///
/// Demande de Jay au test de la v0.9.44 : « pouvoir ouvrir en grand la vibe
/// floutée et switcher de face, même floutée. Comme dans la bibliothèque du
/// profil un peu. »
///
/// L'intérêt n'est pas anecdotique : avant le reveal, la seule chose qu'on
/// puisse faire d'une vibe est la regarder de loin. Pouvoir la retourner rend
/// l'attente vivante — on devine deux ambiances au lieu d'une.
///
/// Avant 18h30 on retourne les **placeholders** ; après, les vraies faces. Le
/// geste est le même dans les deux cas, et c'est le même widget de
/// retournement que dans la bibliothèque du profil ([FlippableCard]).
class VibeFacesScreen extends ConsumerStatefulWidget {
  const VibeFacesScreen({super.key, required this.vibe, this.frontPlaceholder});

  final LibraryVibe vibe;

  /// Déjà en mémoire dans la tuile d'où l'on vient : évite un rechargement et
  /// une rupture visuelle à l'ouverture.
  final Uint8List? frontPlaceholder;

  @override
  ConsumerState<VibeFacesScreen> createState() => _VibeFacesScreenState();
}

class _VibeFacesScreenState extends ConsumerState<VibeFacesScreen> {
  Uint8List? _front;
  Uint8List? _back;

  /// Faces réelles, chargées seulement si la vibe est révélée.
  File? _frontFile;
  File? _backFile;

  String? _error;

  /// Flou en plein écran. Bien plus élevé que sur une tuile : le rayon est en
  /// pixels logiques, il suit la taille d'affichage.
  static const _sigma = 40.0;

  @override
  void initState() {
    super.initState();
    _front = widget.frontPlaceholder;
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(libraryVibesRepositoryProvider);
    final vibe = widget.vibe;

    if (_front == null) {
      try {
        final bytes = await repo.placeholderBytes(vibe);
        if (mounted) setState(() => _front = bytes);
      } catch (_) {
        // Cadre neutre : mieux qu'un écran vide.
      }
    }
    if (vibe.hasBack) {
      try {
        final bytes = await repo.placeholderBytes(vibe, back: true);
        if (mounted) setState(() => _back = bytes);
      } catch (_) {}
    }

    if (!vibe.revealed) return;

    // Révélée : on remplace les placeholders par les vraies faces.
    final isVideo = vibe.card?.frontIsVideo ?? false;
    try {
      final front = await repo.openRevealed(
        vibe,
        extension: isVideo ? 'mp4' : 'jpg',
      );
      if (mounted) setState(() => _frontFile = front);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (vibe.hasBack) {
      final backIsVideo = vibe.card?.backIsVideo ?? false;
      try {
        final back = await repo.openRevealed(
          vibe,
          extension: backIsVideo ? 'mp4' : 'jpg',
          back: true,
        );
        if (mounted) setState(() => _backFile = back);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final vibe = widget.vibe;
    final revealed = vibe.revealed;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          revealed ? vibe.card?.type.tag ?? 'Vibe' : 'Visible à 18h30',
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: _error != null
                ? Text(
                    'Impossible d\'ouvrir cette vibe.\n$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  )
                // Une vibe à face unique n'a rien à retourner : on n'installe
                // pas un geste qui ne mènerait nulle part.
                : vibe.hasBack
                ? FlippableCard(
                    front: _face(front: true),
                    back: _face(front: false),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: _face(front: true),
                  ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12, left: 24, right: 24),
          child: Text(
            vibe.hasBack
                ? (revealed
                      ? 'Swipe pour retourner'
                      : 'Swipe pour retourner — les deux faces restent floutées')
                : (revealed ? '' : 'Tout se découvre à 18h30'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _face({required bool front}) {
    final file = front ? _frontFile : _backFile;
    // Face réelle si la vibe est révélée ET que le déchiffrement a abouti.
    if (file != null) {
      return Image.file(file, fit: BoxFit.cover);
    }
    final bytes = front ? _front : _back;
    if (bytes == null) {
      return const ColoredBox(
        color: Color(0xFF1E1B29),
        child: Center(child: CircularProgressIndicator(color: Colors.white24)),
      );
    }
    return MaskedPlaceholder(bytes: bytes, sigma: _sigma);
  }
}
