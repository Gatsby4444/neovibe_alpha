import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/library_vibe.dart';
import 'library_vibes_repository.dart';

/// Ouverture d'une vibe révélée, avec l'**animation de défloutage**.
///
/// L'idée est de Jay et elle est juste : le défloutage doit s'appliquer à
/// **l'image véritable**, déjà déchiffrée et posée à l'écran. Passer du
/// placeholder à l'image nette serait un remplacement de fichier, donc une
/// coupe sèche — et un temps de chargement au pire moment.
///
/// L'écran est donc noir par nature (c'est une visionneuse) : il reste sombre
/// quel que soit le thème.
class RevealedVibeScreen extends ConsumerStatefulWidget {
  const RevealedVibeScreen({super.key, required this.vibe, this.sealedBytes});

  final LibraryVibe vibe;

  /// Octets déjà préchargés par la tuile, pour éviter un second téléchargement.
  final Uint8List? sealedBytes;

  @override
  ConsumerState<RevealedVibeScreen> createState() => _RevealedVibeScreenState();
}

class _RevealedVibeScreenState extends ConsumerState<RevealedVibeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  /// Le flou part de très haut et tombe à zéro. C'est un filtre appliqué à
  /// l'image réelle, pas un échange d'images.
  late final Animation<double> _blur = Tween<double>(
    begin: 36,
    end: 0,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  File? _file;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final card = widget.vibe.card;
      final isVideo = card?.frontIsVideo ?? false;
      final file = await ref
          .read(libraryVibesRepositoryProvider)
          .openRevealed(
            widget.vibe,
            sealedBytes: widget.sealedBytes,
            extension: isVideo ? 'mp4' : 'jpg',
          );
      if (!mounted) return;
      setState(() => _file = file);
      _controller.forward();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(child: _body()),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          _error!.contains('reveal')
              ? 'Le reveal n\'a pas encore eu lieu.'
              : 'Impossible d\'ouvrir cette vibe.\n$_error',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    if (_file == null) {
      return const CircularProgressIndicator(color: Colors.white24);
    }

    // La vidéo n'est pas encore gérée ici : elle demande le lecteur existant.
    // Voir « Reste à faire » dans docs/bibliotheques-ephemeres.md.
    return AnimatedBuilder(
      animation: _blur,
      builder: (context, child) => ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: _blur.value,
          sigmaY: _blur.value,
          tileMode: TileMode.decal,
        ),
        child: child,
      ),
      child: Image.file(_file!, fit: BoxFit.contain),
    );
  }
}
