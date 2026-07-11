import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cards/card_capture_screen.dart';
import '../connections/connections_screen.dart';
import '../conversations/conversations_screen.dart';
import '../library/profile_screen.dart';
import '../notifications/fomo_listener.dart';
import '../proximity/nearby_screen.dart';

/// Navigation principale : Conversations / Ping / Capture / Cercle / Profil.
/// La capture est au centre — c'est le geste signature (caméra-first).
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  var _index = 0;

  static const _tabs = [
    ConversationsScreen(),
    NearbyScreen(),
    SizedBox.shrink(), // emplacement du bouton capture
    ConnectionsScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // Active l'écouteur FOMO tant que la session est ouverte
    ref.watch(fomoListenerProvider);

    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          if (i == 2) {
            _openCapture();
          } else {
            setState(() => _index = i);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: 'Messages',
          ),
          NavigationDestination(icon: Icon(Icons.radar), label: 'Ping'),
          NavigationDestination(icon: Icon(Icons.photo_camera), label: 'Card'),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Cercle',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
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
