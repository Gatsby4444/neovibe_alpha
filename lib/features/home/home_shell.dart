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

  void _openCapture() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Nouvelle Card'),
              subtitle: const Text('Recto/verso, à toi de choisir le type'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CardCaptureScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.bolt, color: Color(0xFF9E9E9E)),
              title: const Text('Capturer l\'instant (BeReal)'),
              subtitle: const Text('30 secondes, sans mise en scène'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const CardCaptureScreen(bereal: true),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
