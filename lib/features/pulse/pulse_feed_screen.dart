import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/anchor.dart';
import '../../core/models/library_item.dart';
import '../../core/widgets/cover_host.dart';
import '../../core/widgets/kind_colors.dart';
import '../library/feed/publications_feed_screen.dart';
import 'pulse_repository.dart';

/// Ouvre le fil d'une nature depuis la galerie, posé sur [initial] — en
/// couverture de l'onglet (comme le fil du profil), sinon en page.
void openPulseFeed(
  BuildContext context, {
  required LibraryKind kind,
  required LibraryItem initial,
  required ContentAnchor? at,
}) {
  final host = CoverHost.maybeOf(context);
  if (host != null) {
    host.show(
      PulseFeedScreen(kind: kind, initial: initial, at: at, onClose: host.hide),
    );
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PulseFeedScreen(kind: kind, initial: initial, at: at),
    ),
  );
}

/// **Un des trois fils de Pulse** — rien que des Vibes, rien que des Flows,
/// ou rien que des publications (Jay, 2026-09-20). En haut, à la place du
/// titre, **le sélecteur** : Tout / Amis / Autour de moi, un menu qui se
/// déroule sous le titre (comme le choix d'album de la galerie, mais sans
/// panneau du bas). En mode « Autour de moi », un bouton relit ma position.
///
/// Le fil lui-même est celui du profil ([PublicationsFeedScreen]) : mêmes
/// cellules, mêmes gestes. Ce qui change, c'est d'où viennent les contenus.
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

  Future<void> _choisir(BuildContext anchorContext) async {
    // Le menu se déroule SOUS le titre, là où on a appuyé.
    final box = anchorContext.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset(0, box.size.height));
    final choix = await showMenu<FeedMode>(
      context: context,
      position: RelativeRect.fromLTRB(origin.dx, origin.dy, origin.dx, 0),
      items: [
        for (final m in FeedMode.values)
          PopupMenuItem(
            value: m,
            child: Row(
              children: [
                Icon(
                  m == _mode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(m.label),
              ],
            ),
          ),
      ],
    );
    if (choix == null || !mounted || choix == _mode) return;
    setState(() => _mode = choix);
    if (choix == FeedMode.autour && _at == null) unawaited(_relocate());
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(feedItemsProvider(_query));
    final titre = Builder(
      builder: (ctx) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _choisir(ctx),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: KindColors.of(widget.kind),
                    width: 2,
                  ),
                ),
              ),
              Text(
                '${KindColors.label(widget.kind)}s · ${_mode.label}',
                style:
                    Theme.of(context).appBarTheme.titleTextStyle ??
                    Theme.of(context).textTheme.titleLarge,
              ),
              const Icon(Icons.expand_more, size: 20),
            ],
          ),
        ),
      ),
    );
    final actions = <Widget>[
      if (_mode == FeedMode.autour)
        _locating
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                icon: const Icon(Icons.my_location),
                tooltip: 'Relire ma position',
                onPressed: _relocate,
              ),
    ];

    return items.when(
      loading: () => _Cadre(
        titre: titre,
        actions: actions,
        onClose: _close,
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _Cadre(
        titre: titre,
        actions: actions,
        onClose: _close,
        child: Center(child: Text('Erreur : $e')),
      ),
      data: (list) {
        if (list.isEmpty) {
          return _Cadre(
            titre: titre,
            actions: actions,
            onClose: _close,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(switch (_mode) {
                  FeedMode.tout => 'Rien pour l\'instant.',
                  FeedMode.amis => 'Aucun ami ne t\'a encore rien ajouté.',
                  FeedMode.autour =>
                    _at == null
                        ? 'Position indisponible.'
                        : 'Rien de localisé à moins d\'un kilomètre.',
                }, textAlign: TextAlign.center),
              ),
            ),
          );
        }
        final index = list.indexWhere((i) => i.id == widget.initial.id);
        return PublicationsFeedScreen(
          // Un autre mode = un autre fil, reposé sur son début.
          key: ValueKey(_mode),
          items: list,
          initialIndex: index < 0 ? 0 : index,
          titleWidget: titre,
          actions: actions,
          revealAdders: true,
          onClose: _close,
        );
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

/// Le même bandeau que le fil, quand il n'y a pas encore de fil à montrer.
class _Cadre extends StatelessWidget {
  const _Cadre({
    required this.titre,
    required this.actions,
    required this.onClose,
    required this.child,
  });

  final Widget titre;
  final List<Widget> actions;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: 'Retour',
        onPressed: onClose,
      ),
      title: titre,
      actions: actions,
    ),
    body: child,
  );
}
