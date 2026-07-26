import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/gradient.dart';
import '../cards/card_capture_screen.dart';
import '../circle/circle_screen.dart';
import '../connections/request_popup.dart';
import '../library/profile_screen.dart';
import '../notifications/fomo_listener.dart';

/// Navigation principale : trois sections — Card (capture) | Cercle (hub
/// social : conversations + ping) | Profil.
///
/// **Card à gauche et Cercle au milieu** depuis le 2026-07-26 (consigne Jay) :
/// le Cercle est l'écran où l'on revient, il prend donc la place centrale ; la
/// capture garde sa pastille en dégradé, visible en permanence, mais passe à
/// gauche.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// Onglet ouvert au lancement : le Cercle, désormais au MILIEU (index 1).
  var _index = 1;

  static const _tabs = [
    SizedBox.shrink(), // emplacement du bouton capture
    CircleScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // Active l'écouteur FOMO tant que la session est ouverte
    ref.watch(fomoListenerProvider);
    // Pop-up des demandes de connexion entrantes (consigne Jay)
    listenForConnectionRequestPopups(ref, context);

    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          if (i == 0) {
            _openCapture();
          } else {
            setState(() => _index = i);
          }
        },
        destinations: const [
          // Geste signature : le bouton de capture est une pastille pleine en
          // dégradé, visible en permanence quel que soit l'onglet actif.
          NavigationDestination(
            icon: GradientDot(
              size: 38,
              child: Icon(Icons.photo_camera, color: Colors.white, size: 20),
            ),
            label: 'Card',
          ),
          NavigationDestination(
            icon: Icon(Icons.workspaces_outline),
            // Onglet actif : icône en dégradé de marque (l'indicateur de
            // Material ne sait pas porter un dégradé).
            selectedIcon: GradientIcon(Icons.workspaces),
            label: 'Cercle',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: GradientIcon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
    );
  }

  // La BeReal n'est plus déclenchable manuellement : elle arrive par
  // notification (consigne Jay) — la capture s'ouvre donc directement.
  void _openCapture() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const CardCaptureScreen()));
  }
}
