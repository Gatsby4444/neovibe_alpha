import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/motion.dart';
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
  // Ordre de la barre, changé le 2026-08-14 sur consigne de Jay : « déplacer
  // la section Vibe sur la gauche du menu de navigation ». Elle était au
  // centre depuis le passage à cinq onglets (2026-08-01).
  //
  // ⚠️ Ces constantes sont l'ORDRE D'AFFICHAGE : elles indexent à la fois les
  // enfants de l'`IndexedStack` et les `destinations` de la `NavigationBar`.
  // Les deux listes doivent rester dans cet ordre-là, sinon un onglet affiche
  // l'écran d'un autre — sans qu'aucune erreur ne soit levée.
  //
  // Rien n'est stocké par indice : la préférence de démarrage est enregistrée
  // par NOM (`StartupTab`), précisément pour survivre à ce genre de
  // réorganisation. Aucun appareil déjà installé n'ouvrira le mauvais onglet.
  static const _capture = 0;
  static const _ping = 1;
  static const _circle = 2;
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
      // Navigation au SWIPE entre sections (test demandé par Jay, 2026-08-15).
      //
      // ### Pourquoi un simple `GestureDetector` suffit à donner la priorité
      // ### aux swipes internes, sans définir aucune « zone »
      //
      // Jay demandait de bien délimiter les zones pour qu'un swipe de mini-card
      // reste prioritaire. **Il n'y a rien à délimiter** : l'arène de gestes de
      // Flutter tranche déjà dans le bon sens. Les candidats sont ajoutés du
      // plus interne vers le plus externe, et le balayage retient le PREMIER —
      // donc l'enfant. Un `PageView`, un `ListView` horizontal ou un
      // `GestureDetector` de carte gagnent tous contre ce détecteur-ci, y
      // compris arrivés en bout de course (un `Scrollable` ne rend pas la main).
      //
      // Une zone codée en dur, elle, aurait été fausse le jour où un écran
      // change de mise en page — et fausse en silence.
      //
      // Inventaire des concurrents relevé le 2026-08-15 : le bandeau de stories
      // du Cercle (`circle_screen.dart`, liste horizontale) et le deck de
      // mini-cards (`library_deck_screen.dart`, `PageView`) — ce dernier vit
      // dans une route poussée, donc hors de ce détecteur de toute façon.
      //
      // ⚠️ Un glissement VERTICAL n'entre pas en concurrence : un
      // `HorizontalDragGestureRecognizer` ne se déclare que si le mouvement est
      // à dominante horizontale. Les listes verticales ne sont pas touchées.
      body: GestureDetector(
        onHorizontalDragEnd: _onSectionSwipe,
        child: IndexedStack(
          index: _index,
          // Même ordre que les `destinations` ci-dessous — voir le commentaire
          // des constantes.
          children: [
            const SizedBox.shrink(), // emplacement du bouton capture
            _lazy(_ping, const PingScreen()),
            _lazy(_circle, const CircleScreen()),
            _lazy(_play, const PlayScreen()),
            _lazy(_profile, const ProfileScreen()),
          ],
        ),
      ),
      // La barre revient APRÈS le contenu quand on ferme un écran poussé
      // par-dessus (consigne de Jay, 2026-08-15). Le décalage n'est plus porté
      // par la barre entière mais par CHAQUE icône : c'est ce qui permet la
      // vague, et ce qui évite qu'une enveloppe globale n'écrase l'échelonnement
      // en multipliant deux opacités.
      bottomNavigationBar: NavigationBar(
        // Libelles retires (consigne de Jay, 2026-08-15) : « les icones
        // suffisent, pas besoin de preciser dans la barre de navigation ».
        //
        // Effet de bord bienvenu : le desaccord signale a la version
        // precedente disparait par construction. Une `NavigationBar` ne laisse
        // animer que l'icone, jamais son libelle — plus de libelle, plus
        // d'ecart possible entre les deux.
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
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
        // La VAGUE (demande de Jay, 2026-08-15) : chaque icône entre un cran
        // après sa voisine de gauche.
        //
        // ⚠️ Seules les **icônes** ondulent, pas les libellés : une
        // `NavigationBar` construit elle-même la colonne icône + libellé, et
        // n'expose que le widget de l'icône. Les libellés arrivent donc avec
        // la barre. Le pas est petit exprès (~23 ms) pour que l'écart entre
        // un libellé et son icône reste sous le seuil où il se lirait comme
        // un défaut plutôt que comme un mouvement.
        destinations: [
          // Geste signature : le bouton de capture est une pastille pleine en
          // dégradé, visible en permanence quel que soit l'onglet actif.
          //
          // À GAUCHE depuis le 2026-08-14 (consigne de Jay). Ce n'est pas un
          // onglet où l'app se pose : il ouvre la capture par-dessus, et
          // `selectedIndex` ne vaut donc jamais 0.
          NavigationDestination(
            icon: NeoStagger.wave(
              index: 0,
              child: const GradientDot(
                size: 38,
                child: Icon(Icons.photo_camera, color: Colors.white, size: 20),
              ),
            ),
            label: 'Vibe',
          ),
          NavigationDestination(
            icon: NeoStagger.wave(
              index: 1,
              child: const Icon(Icons.radar_outlined),
            ),
            selectedIcon: NeoStagger.wave(
              index: 1,
              child: const GradientIcon(Icons.radar),
            ),
            label: 'Ping',
          ),
          NavigationDestination(
            icon: NeoStagger.wave(
              index: 2,
              child: const Icon(Icons.workspaces_outline),
            ),
            // Onglet actif : icône en dégradé de marque (l'indicateur de
            // Material ne sait pas porter un dégradé).
            selectedIcon: NeoStagger.wave(
              index: 2,
              child: const GradientIcon(Icons.workspaces),
            ),
            label: 'Cercle',
          ),
          NavigationDestination(
            icon: NeoStagger.wave(
              index: 3,
              child: const Icon(Icons.sports_esports_outlined),
            ),
            selectedIcon: NeoStagger.wave(
              index: 3,
              child: const GradientIcon(Icons.sports_esports),
            ),
            label: 'Jeux',
          ),
          NavigationDestination(
            icon: NeoStagger.wave(
              index: 4,
              child: const Icon(Icons.person_outline),
            ),
            selectedIcon: NeoStagger.wave(
              index: 4,
              child: const GradientIcon(Icons.person),
            ),
            label: 'Profil',
          ),
        ],
      ),
    );
  }

  /// Vitesse minimale, en pixels par seconde, pour qu'un glissement compte
  /// comme un changement de section.
  ///
  /// Assez haut pour qu'un doigt qui hésite sur une grille ne fasse pas
  /// changer d'onglet, assez bas pour ne pas exiger un geste sec.
  static const _swipeVelocity = 300.0;

  /// Glissement horizontal : on passe à la section voisine.
  ///
  /// ⚠️ **La section Vibe n'est pas une destination** : arriver dessus ouvre la
  /// capture par-dessus l'onglet courant, exactement comme le bouton de la
  /// barre. On ne déplace donc PAS `_index` dans ce cas — sinon fermer la
  /// capture laisserait l'app sur un écran vide, qui est la raison d'être du
  /// `SizedBox.shrink()` à l'indice 0.
  void _onSectionSwipe(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v.abs() < _swipeVelocity) return;

    // Glisser vers la GAUCHE (vitesse négative) fait avancer : le contenu
    // suit le doigt, comme une page qu'on pousse hors de l'écran.
    final target = v < 0 ? _index + 1 : _index - 1;
    if (target < _capture || target > _profile) return;

    _userMoved = true;
    if (target == _capture) {
      _openCapture();
      return;
    }
    setState(() {
      _index = target;
      _visited.add(target);
    });
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
    ).push(NeoFadeRoute(builder: (_) => const CardCaptureScreen()));
  }
}
