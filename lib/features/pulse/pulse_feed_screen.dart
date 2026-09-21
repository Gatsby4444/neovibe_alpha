import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/anchor.dart';
import '../../core/models/library_item.dart';
import '../../core/widgets/reel_route.dart';
import '../../core/widgets/system_bars.dart';
import '../library/feed/vibes_reel_screen.dart';
import 'feed_mode_selector.dart';
import 'pulse_repository.dart';

/// Ouvre **directement le plein écran** de la Vibe touchée (Jay,
/// 2026-09-20 : *« le seul fil qui doit exister est le plein écran »*) : une
/// route superposée, qui se rétracte — le même écran que le profil, avec le
/// sélecteur en plus.
void openPulseFeed(
  BuildContext context, {
  required LibraryItem initial,
  required ContentAnchor? at,
}) {
  Navigator.of(context).push(
    ReelRoute(
      builder: (_) => PulseFeedScreen(initial: initial, at: at),
    ),
  );
}

/// **Le fil de Pulse**, en plein écran, avec en haut **le sélecteur** Tout /
/// Amis / Autour de moi — rien d'autre : ni titre, ni nature (Jay,
/// 2026-09-20). C'est `VibesReelScreen`, l'écran du profil, à qui on tend
/// le sélecteur ; changer de mode recharge le fil.
///
/// Du 2026-09-20 au 2026-09-21, il y avait un fil par nature (Vibes, Flows,
/// publications). Il ne reste que des Vibes (Jay, 2026-09-21).
class PulseFeedScreen extends ConsumerStatefulWidget {
  const PulseFeedScreen({super.key, required this.initial, required this.at});

  /// La case touchée : le fil s'ouvre dessus (en mode Tout).
  final LibraryItem initial;

  /// Où j'étais à l'ouverture de la galerie ; relu par le bouton.
  final ContentAnchor? at;

  @override
  ConsumerState<PulseFeedScreen> createState() => _PulseFeedScreenState();
}

class _PulseFeedScreenState extends ConsumerState<PulseFeedScreen> {
  var _mode = FeedMode.tout;
  late ContentAnchor? _at = widget.at;
  var _locating = false;

  FeedQuery get _query => (mode: _mode, at: _at);

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
      FeedModeSelector(mode: _mode, onChanged: _setMode, light: true),
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
                color: Colors.white,
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
        selector: _selector(),
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _Attente(
        selector: _selector(),
        child: Center(child: Text('Erreur : $e')),
      ),
      data: (list) {
        if (list.isEmpty) {
          return _Attente(
            selector: _selector(),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _vide,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
          );
        }
        final index = list.indexWhere((i) => i.id == widget.initial.id);
        return VibesReelScreen(
          key: ValueKey(_mode),
          vibes: list,
          initialIndex: index < 0 ? 0 : index,
          header: _selector(),
          revealAdders: true,
        );
      },
    );
  }
}

/// La même ligne du haut, quand il n'y a pas encore de fil à montrer : en
/// plein écran, noir, le sélecteur à gauche de la croix (comme sur le fil).
class _Attente extends StatelessWidget {
  const _Attente({required this.selector, required this.child});

  final Widget selector;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DarkSystemBars(
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          automaticallyImplyLeading: false,
          actions: [
            selector,
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Fermer',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        body: child,
      ),
    );
  }
}
