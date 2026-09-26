import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'live_position.dart';

/// **Tant que cet écran est regardé, la position est suivie en continu.**
///
/// La règle de Jay (2026-09-22 au soir) : *en continu quand on regarde la
/// carte, une rafale par minute le reste du temps* — étendue le 2026-09-26 à
/// la recherche de soirées, pour une distance en temps réel.
///
/// Écrite une fois ici au lieu d'être recopiée par chaque écran (elle vivait
/// dans la carte) : un écran qui l'oublierait en partie — par exemple le
/// relâchement en arrière-plan — garderait la radio allumée derrière une
/// autre app, sans que rien ne le signale.
///
/// - tient la position à l'ouverture, la relâche à la fermeture ;
/// - la relâche **dès qu'on quitte l'app**, la reprend au retour ;
/// - relit au retour la finesse accordée (elle a pu changer dans les
///   réglages système, et rien ne nous prévient).
class LivePositionKeeper extends ConsumerStatefulWidget {
  const LivePositionKeeper({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LivePositionKeeper> createState() => _LivePositionKeeperState();
}

class _LivePositionKeeperState extends ConsumerState<LivePositionKeeper>
    with WidgetsBindingObserver {
  /// Retenu dès [initState] : lire un fournisseur pendant `dispose` n'est
  /// pas garanti.
  late final LivePosition _position;

  /// Tient-on la position **pour cet écran** en ce moment ?
  bool _tenu = false;

  @override
  void initState() {
    super.initState();
    _position = ref.read(livePositionProvider.notifier);
    _tenir();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lacher();
    super.dispose();
  }

  void _tenir() {
    if (_tenu) return;
    _tenu = true;
    _position.acquire();
  }

  /// ⚠️ **Une seule fois** : le compteur d'abonnés passerait sous zéro et
  /// couperait le flux sous les pieds d'un autre lecteur.
  void _lacher() {
    if (!_tenu) return;
    _tenu = false;
    _position.release();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _tenir();
      unawaited(_position.relisPrecision());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _lacher();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
