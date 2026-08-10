import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/prefs.dart';
import '../../core/widgets/gradient.dart';
import '../cards/card_capture_screen.dart';
import '../circle/circle_screen.dart';
import '../connections/request_popup.dart';
import '../library/profile_screen.dart';
import '../notifications/fomo_listener.dart';
import '../play/play_screen.dart';
import '../proximity/ping_screen.dart';

/// Navigation principale — **cinq onglets depuis le 2026-08-01** (consigne
/// Jay) : Ping | Cercle | (Card) | Jeux | Profil.
///
/// Pourquoi cinq. À trois onglets, le Ping — la mécanique fondatrice du
/// produit, la présence physique — n'était qu'un bouton flottant à l'intérieur
/// du Cercle, et les deux chantiers décidés le 2026-07-26 (quiz/mini-jeux, feed
/// local) n'avaient aucun emplacement. La barre est donc portée à cinq
/// maintenant, pour ne pas la refaire une deuxième fois.
///
/// La capture reprend la place centrale : c'est le geste au pouce, et la
/// pastille en dégradé reste visible quel que soit l'onglet actif. L'app
/// **s'ouvre toujours sur le Cercle par défaut** (consigne Jay du 2026-07-26,
/// maintenue) — mais l'onglet de démarrage est désormais réglable
/// (Réglages → Démarrage).
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  static const _ping = 0;
  static const _circle = 1;
  static const _capture = 2;
  static const _play = 3;
  static const _profile = 4;

  /// `StartupTab.card` n'a pas d'onglet où se poser : l'app démarre sur le
  /// Cercle et la capture s'ouvre par-dessus (voir `initState`).
  static int _indexOf(StartupTab tab) => switch (tab) {
    StartupTab.ping => _ping,
    StartupTab.circle || StartupTab.card => _circle,
    StartupTab.play => _play,
    StartupTab.profile => _profile,
  };

  /// Onglet ouvert. Part sur le Cercle et bascule sur l'onglet réglé dès que
  /// la préférence est lue (quelques millisecondes) — voir `initState`.
  var _index = _circle;

  /// Onglets déjà ouverts au moins une fois. L'`IndexedStack` ne construit que
  /// ceux-là : le Ping tient un écouteur BLE vivant tant qu'il est monté, il
  /// n'y a aucune raison de le faire tourner tant que Jay n'y est pas allé.
  /// Une fois visité, un onglet reste monté et garde son état.
  final _visited = <int>{_circle};

  /// Vrai dès que l'utilisateur a touché la barre lui-même : la préférence de
  /// démarrage arrive de façon asynchrone et ne doit jamais lui reprendre la
  /// main si elle est en retard.
  var _userMoved = false;

  @override
  void initState() {
    super.initState();
    // Lecture directe des préférences plutôt que `startupTabProvider` : le
    // provider ne connaît sa vraie valeur qu'après un chargement asynchrone,
    // et l'écouter ferait sauter l'app d'onglet au moment où Jay change le
    // réglage. Ici on ne veut la valeur qu'UNE fois, au lancement.
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted || _userMoved) return;
      final tab = StartupTab.fromKey(prefs.getString(StartupTabPref.prefsKey));
      final index = _indexOf(tab);
      if (index != _index) {
        setState(() {
          _index = index;
          _visited.add(index);
        });
      }
      // Démarrage sur la Card : l'app se pose sur le Cercle et ouvre la
      // capture par-dessus. Fermer la capture laisse donc sur le Cercle,
      // au lieu de sortir de l'app sur un écran vide.
      if (tab == StartupTab.card) _openCapture();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Active l'écouteur FOMO tant que la session est ouverte
    ref.watch(fomoListenerProvider);
    // Pop-up des demandes de connexion entrantes (consigne Jay)
    listenForConnectionRequestPopups(ref, context);

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          _lazy(_ping, const PingScreen()),
          _lazy(_circle, const CircleScreen()),
          const SizedBox.shrink(), // emplacement du bouton capture
          _lazy(_play, const PlayScreen()),
          _lazy(_profile, const ProfileScreen()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          _userMoved = true;
          if (i == _capture) {
            _openCapture();
          } else {
            setState(() {
              _index = i;
              _visited.add(i);
            });
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radar_outlined),
            selectedIcon: GradientIcon(Icons.radar),
            label: 'Ping',
          ),
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
            label: 'Vibe',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_esports_outlined),
            selectedIcon: GradientIcon(Icons.sports_esports),
            label: 'Jeux',
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

  /// Un onglet n'est construit qu'après sa première ouverture ; ensuite
  /// l'`IndexedStack` le garde monté, donc son état est conservé.
  Widget _lazy(int index, Widget tab) =>
      _visited.contains(index) ? tab : const SizedBox.shrink();

  // La BeReal n'est plus déclenchable manuellement : elle arrive par
  // notification (consigne Jay) — la capture s'ouvre donc directement.
  void _openCapture() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const CardCaptureScreen()));
  }
}
