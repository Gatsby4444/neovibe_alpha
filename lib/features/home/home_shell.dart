import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/gradient.dart';
import '../cards/card_capture_screen.dart';
import '../circle/circle_screen.dart';
import '../connections/request_popup.dart';
import '../library/profile_screen.dart';
import '../notifications/fomo_listener.dart';

/// Navigation principale (consigne Jay 2026-07-12) : trois sections —
/// Cercle (hub social : conversations + ping) | Card (capture, geste
/// signature au centre) | Profil.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  var _index = 0;

  static const _tabs = [
    CircleScreen(),
    SizedBox.shrink(), // emplacement du bouton capture
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
          if (i == 1) {
            _openCapture();
          } else {
            setState(() => _index = i);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.workspaces_outline),
            // Onglet actif : icône en dégradé de marque (l'indicateur de
            // Material ne sait pas porter un dégradé).
            selectedIcon: GradientIcon(Icons.workspaces),
            label: 'Cercle',
          ),
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
