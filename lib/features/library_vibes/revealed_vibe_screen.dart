import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/library_vibe.dart';
import 'library_vibes_repository.dart';
import 'masked_placeholder.dart';

/// Ouverture d'une vibe révélée — **dissipation** du flou vers l'image.
///
/// ─── Le principe, demandé par Jay ──────────────────────────────────────────
///
/// Le défloutage doit s'appliquer à **l'image véritable**, pas se contenter de
/// remplacer un fichier par un autre : un échange donnerait une coupe sèche, et
/// un temps de chargement au pire moment.
///
/// ─── Comment la continuité est obtenue ─────────────────────────────────────
///
/// Trois couches empilées, pilotées par une seule animation :
///
/// 1. Le **placeholder** flouté, affiché tout de suite — exactement ce que
///    montrait la tuile, donc aucune rupture au moment d'ouvrir l'écran ;
/// 2. l'**image réelle**, posée par-dessus avec la même intensité de flou, dont
///    l'opacité monte de 0 à 1. Comme les deux couches sont très floutées à cet
///    instant, elles se ressemblent : **l'échange est invisible** ;
/// 3. puis le flou de l'image réelle tombe à zéro.
///
/// L'ensemble se lit comme un brouillard qui se dissipe, sans saut, sans
/// attente, et jamais sur une mosaïque.
///
/// L'écran est noir par nature (c'est une visionneuse) : il reste sombre quel
/// que soit le thème.
class RevealedVibeScreen extends ConsumerStatefulWidget {
  const RevealedVibeScreen({
    super.key,
    required this.vibe,
    this.sealedBytes,
    this.placeholderBytes,
  });

  final LibraryVibe vibe;

  /// Octets déjà préchargés par la tuile, pour éviter un second téléchargement.
  final Uint8List? sealedBytes;

  /// Placeholder déjà en mémoire : c'est lui qui assure la continuité visuelle
  /// avec la tuile d'où l'on vient.
  final Uint8List? placeholderBytes;

  @override
  ConsumerState<RevealedVibeScreen> createState() => _RevealedVibeScreenState();
}

class _RevealedVibeScreenState extends ConsumerState<RevealedVibeScreen>
    with SingleTickerProviderStateMixin {
  /// Flou de départ, en plein écran. Bien plus élevé que sur une tuile : le
  /// rayon est en pixels logiques, il doit suivre la taille d'affichage.
  static const _startSigma = 44.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  /// L'image réelle apparaît d'abord (sous un flou identique à celui du
  /// placeholder, donc sans transition perceptible), puis le flou se dissipe.
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.28, curve: Curves.easeOut),
  );

  late final Animation<double> _sigma =
      Tween<double>(begin: _startSigma, end: 0).animate(
        CurvedAnimation(
          parent: _controller,
          // Le flou ne commence à tomber qu'une fois l'image réelle en place.
          curve: const Interval(0.22, 1, curve: Curves.easeOutCubic),
        ),
      );

  File? _file;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final isVideo = widget.vibe.frontIsVideo;
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

    final placeholder = widget.placeholderBytes;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Couche 1 — le brouillard de départ. Rien à charger : ces octets sont
        // déjà en mémoire, donc l'écran n'est jamais vide.
        if (placeholder != null)
          MaskedPlaceholder(bytes: placeholder, sigma: _startSigma),

        // Sans placeholder (cas de repli), on ne laisse pas un écran noir muet.
        if (placeholder == null && _file == null)
          const Center(child: CircularProgressIndicator(color: Colors.white24)),

        // Couche 2 et 3 — l'image réelle, qui apparaît puis se dévoile.
        if (_file != null)
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Opacity(
              opacity: _fade.value,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  // `sigma` atteint exactement 0 en fin d'animation ; un filtre
                  // de rayon nul est inutile et coûte une passe de rendu.
                  sigmaX: _sigma.value.clamp(0.001, _startSigma),
                  sigmaY: _sigma.value.clamp(0.001, _startSigma),
                  tileMode: TileMode.decal,
                ),
                child: child,
              ),
            ),
            child: Image.file(_file!, fit: BoxFit.contain),
          ),
      ],
    );
  }
}
