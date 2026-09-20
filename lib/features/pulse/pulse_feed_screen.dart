import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/anchor.dart';
import '../../core/models/library_item.dart';
import '../../core/widgets/cover_host.dart';
import '../../core/widgets/reel_route.dart';
import '../../core/widgets/system_bars.dart';
import '../library/feed/flows_reel_screen.dart';
import '../library/feed/publications_feed_screen.dart';
import '../library/feed/vibes_reel_screen.dart';
import 'feed_mode_selector.dart';
import 'pulse_repository.dart';

/// Ouvre **directement le plein écran** de la nature touchée (Jay,
/// 2026-09-20 : *« le seul fil qui doit exister est le plein écran »*) : une
/// Vibe ou un Flow en plein écran façon Reels (une route superposée, qui se
/// rétracte), une publication dans le fil des publications, en couverture
/// de l'onglet — les mêmes écrans que le profil, avec un bandeau en plus :
/// le sélecteur.
void openPulseFeed(
  BuildContext context, {
  required LibraryKind kind,
  required LibraryItem initial,
  required ContentAnchor? at,
}) {
  if (kind == LibraryKind.album) {
    final host = CoverHost.maybeOf(context);
    if (host != null) {
      host.show(
        PulseFeedScreen(
          kind: kind,
          initial: initial,
          at: at,
          onClose: host.hide,
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PulseFeedScreen(kind: kind, initial: initial, at: at),
      ),
    );
    return;
  }
  Navigator.of(context).push(
    ReelRoute(
      builder: (_) => PulseFeedScreen(kind: kind, initial: initial, at: at),
    ),
  );
}

/// **Un des trois fils de Pulse**, en plein écran, avec en haut **le
/// sélecteur** Tout / Amis / Autour de moi — rien d'autre : ni titre, ni
/// nature (Jay, 2026-09-20). Vibes → `VibesReelScreen`, Flows →
/// `FlowsReelScreen`, publications → `PublicationsFeedScreen` : les écrans
/// du profil, à qui on tend un bandeau. Changer de mode recharge le fil.
class PulseFeedScreen extends ConsumerStatefulWidget {
  const PulseFeedScreen({
    super.key,
    required this.kind,
    required this.initial,
    required this.at,
    this.onClose,
  });

  final LibraryKind kind;

  /// La case touchée : le fil s'ouvre dessus (en mode Tout).
  final LibraryItem initial;

  /// Où j'étais à l'ouverture de la galerie ; relu par le bouton.
  final ContentAnchor? at;
  final VoidCallback? onClose;

  @override
  ConsumerState<PulseFeedScreen> createState() => _PulseFeedScreenState();
}

class _PulseFeedScreenState extends ConsumerState<PulseFeedScreen> {
  var _mode = FeedMode.tout;
  late ContentAnchor? _at = widget.at;
  var _locating = false;

  bool get _reel => widget.kind != LibraryKind.album;

  FeedQuery get _query => (kind: widget.kind, mode: _mode, at: _at);

  Future<void> _relocate() async {
    setState(() => _locating = true);
    final a = await ref.read(anchorSourceProvider).current();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (a != null) _at = a;
    });
    ref.invalidate(feedItemsProvider(_query));
  }

  void _setMode(FeedMode m) {
    setState(() => _mode = m);
    if (m == FeedMode.autour && _at == null) unawaited(_relocate());
  }

  /// Le sélecteur, et le bouton de position en mode Autour de moi.
  Widget _selector() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      FeedModeSelector(mode: _mode, onChanged: _setMode, light: _reel),
      if (_mode == FeedMode.autour)
        _locating
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                icon: const Icon(Icons.my_location, size: 20),
                color: _reel ? Colors.white : null,
                tooltip: 'Relire ma position',
                onPressed: _relocate,
              ),
    ],
  );

  String get _vide => switch (_mode) {
    FeedMode.tout => 'Rien pour l\'instant.',
    FeedMode.amis => 'Aucun ami ne t\'a encore rien ajouté.',
    FeedMode.autour =>
      _at == null
          ? 'Position indisponible.'
          : 'Rien de localisé à moins d\'un kilomètre.',
  };

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(feedItemsProvider(_query));
    return items.when(
      loading: () => _Attente(
        reel: _reel,
        selector: _selector(),
        onClose: _close,
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _Attente(
        reel: _reel,
        selector: _selector(),
        onClose: _close,
        child: Center(child: Text('Erreur : $e')),
      ),
      data: (list) {
        if (list.isEmpty) {
          return _Attente(
            reel: _reel,
            selector: _selector(),
            onClose: _close,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _vide,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _reel ? Colors.white70 : null),
                ),
              ),
            ),
          );
        }
        final index = list.indexWhere((i) => i.id == widget.initial.id);
        final start = index < 0 ? 0 : index;
        return switch (widget.kind) {
          LibraryKind.card => VibesReelScreen(
            key: ValueKey(_mode),
            vibes: list,
            initialIndex: start,
            header: _selector(),
          ),
          LibraryKind.flow => FlowsReelScreen(
            key: ValueKey(_mode),
            flows: list,
            initialIndex: start,
            header: _selector(),
          ),
          LibraryKind.album => PublicationsFeedScreen(
            key: ValueKey(_mode),
            items: list,
            initialIndex: start,
            titleWidget: Center(child: _selector()),
            revealAdders: true,
            onClose: _close,
          ),
        };
      },
    );
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).maybePop();
    }
  }
}

/// Le même bandeau, quand il n'y a pas encore de fil à montrer : noir en
/// plein écran, clair dans le fil des publications.
class _Attente extends StatelessWidget {
  const _Attente({
    required this.reel,
    required this.selector,
    required this.onClose,
    required this.child,
  });

  final bool reel;
  final Widget selector;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: reel ? Colors.black : null,
      appBar: AppBar(
        backgroundColor: reel ? Colors.black : null,
        foregroundColor: reel ? Colors.white : null,
        leading: IconButton(
          icon: Icon(reel ? Icons.close : Icons.arrow_back),
          tooltip: 'Fermer',
          onPressed: onClose,
        ),
        centerTitle: true,
        title: selector,
      ),
      body: child,
    );
    return reel ? DarkSystemBars(child: scaffold) : scaffold;
  }
}
