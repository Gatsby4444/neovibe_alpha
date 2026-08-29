import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
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
import 'section_cursor.dart';

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

class _HomeShellState extends ConsumerState<HomeShell>
    with TickerProviderStateMixin, RouteAware {
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

  /// Où en est la navigation : l'onglet **visé** (la barre) et l'onglet
  /// **affiché** (l'écran). Les deux ne peuvent plus bouger l'un sans l'autre —
  /// voir `SectionCursor` et le défaut du 2026-08-29 qu'il supprime.
  ///
  /// ⚠️ La valeur de départ n'est plus le Cercle « en attendant » : elle est
  /// **lue avant le premier rendu** (`startupTabAtLaunchProvider`, résolu dans
  /// `main()`). L'app n'a donc plus à sauter d'onglet après coup — et le Cercle
  /// n'est plus construit pour rien quand on démarre ailleurs.
  late final SectionCursor _cursor = SectionCursor(
    _indexOf(ref.read(startupTabAtLaunchProvider)),
  );

  int get _index => _cursor.vise;

  /// Onglets déjà ouverts au moins une fois. L'`IndexedStack` ne construit que
  /// ceux-là ; une fois visité, un onglet reste monté et garde son état.
  ///
  /// ⚠️ **Correction du 2026-08-16.** Ce commentaire affirmait que « le Ping
  /// tient un écouteur BLE vivant tant qu'il est monté ». **C'est faux**, et
  /// ça n'avait jamais été vérifié : `ProximityService.build()` ne démarre
  /// rien, le matériel ne part que sur `enable()` — l'interrupteur explicite de
  /// l'écran Ping — et il tourne alors en **service de premier plan**, donc
  /// indépendamment de l'interface, app fermée comprise. Monter `PingScreen`
  /// n'ajoute qu'un écouteur sur un magasin **local**.
  ///
  /// Ce que le montage paresseux économise réellement : les **chargements
  /// réseau** du Cercle et du Profil, qui partiraient au lancement pour des
  /// onglets que l'utilisateur n'ouvrira peut-être pas.
  ///
  /// C'est une différence de nature : le premier motif interdisait le carrousel
  /// à doigt suivi, le second n'est qu'un coût à arbitrer. **Une contrainte
  /// écrite et jamais revérifiée finit par décider à notre place.**
  ///
  /// ⚠️ **Il part sur l'onglet de DÉMARRAGE, pas sur le Cercle.** Avant le
  /// 2026-08-29 le Cercle était monté au lancement quoi qu'il arrive — donc ses
  /// chargements réseau partaient même quand on démarrait sur le Profil.
  late final _visited = <int>{_cursor.affiche};

  /// Vrai dès que l'utilisateur a touché la barre lui-même : la préférence de
  /// démarrage arrive de façon asynchrone et ne doit jamais lui reprendre la
  /// main si elle est en retard.
  var _userMoved = false;

  /// La séquence d'entrée de la barre de navigation.
  ///
  /// ⚠️ **Son propre contrôleur, et pas l'animation de la route** : le pas
  /// entre deux icônes ([NeoMotion.buildStep], 63 ms) est celui du rail de la
  /// caméra (demande de Jay, 2026-08-15), et cinq icônes à ce rythme ne
  /// tiennent pas dans les 380 ms d'une navigation.
  late final _barEntrance = AnimationController(
    vsync: this,
    duration: NeoBuildIn.durationFor(_tabCount),
  );

  static const _tabCount = 5;

  /// La bascule d'une section à l'autre.
  ///
  /// ## Pourquoi une SÉQUENCE et pas un fondu croisé
  ///
  /// Un fondu croisé exigerait que les deux sections soient peintes en même
  /// temps. Or l'`IndexedStack` n'en peint qu'une.
  ///
  /// ⚠️ **Le motif invoqué ici était faux** (corrigé le 2026-08-16, voir
  /// `_visited`) : ce n'est PAS le BLE qui l'imposait. Ce qu'un `PageView`
  /// coûterait vraiment, c'est de construire ses voisins — donc les
  /// chargements réseau du Cercle et du Profil au lancement — et de perdre
  /// l'état des onglets quittés, sauf à les rendre tous persistants.
  ///
  /// La section sortante s'efface donc **puis** l'entrante arrive, comme la
  /// transition de page de l'app. Ce n'est pas un pis-aller : le fond du thème
  /// NeoVibe ne bouge pas, donc l'écran n'est jamais vide — c'est exactement la
  /// dissociation fond/contenu que Jay a validée le 2026-08-15.
  late final _switch = AnimationController(
    vsync: this,
    duration: NeoMotion.ample,
  )..addListener(_onSwitchTick);

  /// L'index réellement AFFICHÉ. Il rattrape [_index] au milieu de la bascule,
  /// quand le contenu est à son opacité la plus basse.
  int get _shownIndex => _cursor.affiche;

  /// +1 si l'on va vers la droite (index croissant), -1 sinon.
  var _direction = 1;

  /// Position du doigt pendant le glissement, en **fraction de largeur**.
  ///
  /// Le contenu suit le doigt : sans ça, on ne saurait pas qu'un geste est en
  /// cours avant de l'avoir terminé, et un swipe raté n'aurait aucun retour.
  var _drag = 0.0;

  /// Part de la bascule consacrée à la sortie — le reste à l'entrée.
  /// Même découpage que `NeoPageTransitionsBuilder` : une seule grammaire de
  /// mouvement dans l'app.
  static const _handover = 0.45;

  /// Amplitude du déplacement, en fraction de largeur.
  static const _travel = 0.10;

  void _onSwitchTick() {
    // Le contenu change quand il est le moins visible.
    if (_switch.value >= _handover && _cursor.enTransit) {
      setState(_cursor.relayer);
    } else {
      setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  /// Premier affichage de l'app.
  @override
  void didPush() => _barEntrance.forward(from: 0);

  /// Retour d'un écran poussé (réglages, capture, conversation) : la barre se
  /// reconstruit, icône par icône.
  @override
  void didPopNext() => _barEntrance.forward(from: 0);

  /// Départ vers un écran poussé : la barre s'efface **avant** le contenu.
  @override
  void didPushNext() => _barEntrance.animateBack(0, duration: NeoMotion.fast);

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _barEntrance.dispose();
    _switch.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // ⚠️ **Plus aucune lecture asynchrone ici.** Elle posait l'onglet réglé
    // APRÈS le premier rendu, et c'est ce qui a produit le défaut du
    // 2026-08-29 : la barre partait sur Profil, l'écran restait sur le Cercle.
    // La valeur est désormais connue avant `runApp` (`main()`), donc le
    // curseur naît déjà au bon endroit — voir `_cursor`.
    //
    // ⚠️ On ne s'ABONNE toujours pas à `startupTabProvider` : le réglage dit
    // « où démarrer », pas « où aller maintenant ». L'écouter ferait sauter
    // l'app d'onglet à l'instant où Jay change le réglage.
    //
    // Démarrage sur la Vibe : l'app se pose sur le Cercle et ouvre la capture
    // par-dessus. Fermer la capture laisse donc sur le Cercle, au lieu de
    // sortir de l'app sur un écran vide. Le `Navigator` n'existe qu'une fois
    // la première image posée, d'où le report d'une frame.
    if (ref.read(startupTabAtLaunchProvider) == StartupTab.card) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_userMoved) _openCapture();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Active l'écouteur FOMO tant que la session est ouverte
    ref.watch(fomoListenerProvider);
    // Pop-up des demandes de connexion entrantes (consigne Jay)
    listenForConnectionRequestPopups(ref, context);

    return PopScope(
      // La coquille est la RACINE : un retour y fermait l'app sur-le-champ, sans
      // rien demander (aucun `PopScope` n'existait nulle part dans l'app —
      // relevé par inventaire le 2026-08-16).
      //
      // Sans conséquence tant que Jay testait au bouton retour ; en navigation
      // par gestes, un glissement parti d'un bord est capté par Android, arrive
      // comme un retour, et **ferme l'app au milieu d'un changement de section**.
      // La cause n'est pas le mode gestes : c'est que rien ne protégeait la
      // racine. Le mode gestes n'a fait que la rendre atteignable par mégarde.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmExit();
      },
      child: _shell(context),
    );
  }

  /// Instant du dernier retour resté sans suite.
  DateTime? _exitAsked;

  /// Fenêtre laissée pour confirmer. Assez longue pour lire le message, assez
  /// courte pour qu'un retour d'il y a une minute ne ferme pas l'app.
  static const _exitWindow = Duration(seconds: 3);

  /// « Appuyez une deuxième fois pour quitter » (demande de Jay, 2026-08-16).
  void _confirmExit() {
    final now = DateTime.now();
    final asked = _exitAsked;
    if (asked != null && now.difference(asked) <= _exitWindow) {
      // La sortie est DEMANDÉE au système, jamais forcée : `SystemNavigator.pop`
      // rend la main à Android, qui met la tâche en arrière-plan comme il le
      // ferait pour n'importe quelle app. Tuer le processus perdrait l'état.
      SystemNavigator.pop();
      return;
    }
    _exitAsked = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Appuie une deuxième fois pour quitter'),
          duration: _exitWindow,
        ),
      );
  }

  Widget _shell(BuildContext context) {
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
        onHorizontalDragUpdate: _onSectionDrag,
        onHorizontalDragEnd: _onSectionSwipe,
        onHorizontalDragCancel: _releaseDrag,
        child: _sectionLayer(
          IndexedStack(
            index: _shownIndex,
            // Même ordre que les `destinations` ci-dessous — voir le
            // commentaire des constantes.
            children: [
              const SizedBox.shrink(), // emplacement du bouton capture
              _lazy(_ping, const PingScreen()),
              _lazy(_circle, const CircleScreen()),
              _lazy(_play, const PlayScreen()),
              _lazy(_profile, const ProfileScreen()),
            ],
          ),
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
            _goToSection(i, i > _index ? 1 : -1);
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
            icon: NeoBuildIn(
              animation: _barEntrance,
              index: 0,
              total: _tabCount,
              child: const GradientDot(
                size: 38,
                child: Icon(Icons.photo_camera, color: Colors.white, size: 20),
              ),
            ),
            label: 'Vibe',
          ),
          NavigationDestination(
            icon: NeoBuildIn(
              animation: _barEntrance,
              index: 1,
              total: _tabCount,
              child: const Icon(Icons.radar_outlined),
            ),
            selectedIcon: NeoBuildIn(
              animation: _barEntrance,
              index: 1,
              total: _tabCount,
              child: const GradientIcon(Icons.radar),
            ),
            label: 'Ping',
          ),
          NavigationDestination(
            icon: NeoBuildIn(
              animation: _barEntrance,
              index: 2,
              total: _tabCount,
              child: const Icon(Icons.workspaces_outline),
            ),
            // Onglet actif : icône en dégradé de marque (l'indicateur de
            // Material ne sait pas porter un dégradé).
            selectedIcon: NeoBuildIn(
              animation: _barEntrance,
              index: 2,
              total: _tabCount,
              child: const GradientIcon(Icons.workspaces),
            ),
            label: 'Cercle',
          ),
          NavigationDestination(
            icon: NeoBuildIn(
              animation: _barEntrance,
              index: 3,
              total: _tabCount,
              child: const Icon(Icons.sports_esports_outlined),
            ),
            selectedIcon: NeoBuildIn(
              animation: _barEntrance,
              index: 3,
              total: _tabCount,
              child: const GradientIcon(Icons.sports_esports),
            ),
            label: 'Jeux',
          ),
          NavigationDestination(
            icon: NeoBuildIn(
              animation: _barEntrance,
              index: 4,
              total: _tabCount,
              child: const Icon(Icons.person_outline),
            ),
            selectedIcon: NeoBuildIn(
              animation: _barEntrance,
              index: 4,
              total: _tabCount,
              child: const GradientIcon(Icons.person),
            ),
            label: 'Profil',
          ),
        ],
      ),
    );
  }

  /// Le contenu de la section, déplacé et estompé.
  ///
  /// Deux sources se combinent ici, et une seule est active à la fois : le
  /// **doigt** (`_drag`) pendant le geste, la **bascule** (`_switch`) ensuite.
  Widget _sectionLayer(Widget child) {
    final double shift;
    final double fade;

    if (_switch.isAnimating) {
      final t = _switch.value;
      if (t < _handover) {
        // Sortie : le contenu part du côté OPPOSÉ au sens de lecture.
        final k = const Interval(
          0,
          _handover,
          curve: NeoMotion.exit,
        ).transform(t);
        shift = -_direction * _travel * k;
        fade = 1 - k;
      } else {
        // Entrée : il revient du côté d'où l'on vient.
        final k = const Interval(
          _handover,
          1,
          curve: NeoMotion.enter,
        ).transform(t);
        shift = _direction * _travel * (1 - k);
        fade = k;
      }
    } else {
      shift = _drag;
      // Le contenu pâlit à mesure qu'il s'éloigne : c'est ce qui dit que le
      // geste MÈNE quelque part, avant même de l'avoir relâché.
      fade = (1 - _drag.abs() / _travel * 0.35).clamp(0.55, 1.0);
    }

    if (shift == 0 && fade == 1) return child;
    return Opacity(
      opacity: fade,
      child: FractionalTranslation(translation: Offset(shift, 0), child: child),
    );
  }

  /// Y a-t-il quelque chose dans ce sens ? (`+1` = index croissant.)
  ///
  /// La capture compte : arriver dessus **ouvre l'écran caméra**. C'est donc le
  /// critère du RELÂCHEMENT, pas celui du mouvement — voir [_dragFollows].
  bool _hasSection(int direction) {
    final target = _index + direction;
    return target >= _capture && target <= _profile;
  }

  /// Le contenu doit-il suivre le doigt dans ce sens ?
  ///
  /// **Non aux deux extrémités**, et pour deux raisons différentes (consigne de
  /// Jay, 2026-08-16) :
  ///
  /// - **À droite du Profil, il n'y a rien.** Un élastique y ferait bouger
  ///   l'écran pour annoncer… qu'il ne se passera rien. Ne rien bouger le dit
  ///   mieux, et c'est ce que fait iOS au dernier onglet.
  /// - **À gauche du Ping, il y a la caméra** — mais elle s'ouvre PAR-DESSUS,
  ///   avec sa propre transition en fondu. Décaler l'écran d'accueil juste
  ///   avant *« gâche le travail de l'animation d'ouverture »* : deux
  ///   mouvements se disputeraient le même geste, l'un annonçant un
  ///   déplacement latéral qui n'aura pas lieu.
  ///
  /// ⚠️ **Le glissement qui ouvre la caméra reste actif** : seul le décalage
  /// visuel disparaît. Le geste se conclut alors à la vitesse seule, puisqu'il
  /// n'y a plus de distance parcourue à mesurer.
  bool _dragFollows(int direction) {
    final target = _index + direction;
    return target >= _ping && target <= _profile;
  }

  /// Le doigt déplace le contenu — **là où il y a une section à rejoindre**.
  void _onSectionDrag(DragUpdateDetails details) {
    if (_switch.isAnimating) return;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;

    final next = _drag + details.delta.dx / width;
    // Un décalage vers 0 est toujours permis : sinon un geste amorcé dans le
    // bon sens puis ramené en arrière resterait coincé à mi-course.
    if (!_dragFollows(next > 0 ? -1 : 1)) {
      if (_drag != 0) setState(() => _drag = 0);
      return;
    }

    setState(() => _drag = next.clamp(-_travel, _travel));
  }

  /// Le doigt s'en va sans conclure : le contenu revient à sa place.
  void _releaseDrag() {
    if (_drag == 0) return;
    setState(() => _drag = 0);
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

    // Deux façons de conclure : **vite**, ou **loin**. Exiger les deux rendrait
    // le geste posé impossible ; n'exiger que la vitesse rendrait impossible
    // celui qu'on fait lentement, en regardant l'écran.
    final far = _drag.abs() >= _travel * 0.6;
    final fast = v.abs() >= _swipeVelocity;
    final direction = fast ? (v < 0 ? 1 : -1) : (_drag < 0 ? 1 : -1);

    if ((!fast && !far) || !_hasSection(direction)) {
      _releaseDrag();
      return;
    }

    _userMoved = true;
    final target = _index + direction;
    if (target == _capture) {
      // La capture n'est pas une section : elle s'ouvre PAR-DESSUS. Le contenu
      // doit donc reprendre sa place, sinon on le retrouverait décalé au
      // retour — l'écran d'accueil, lui, n'a pas bougé.
      _releaseDrag();
      _openCapture();
      return;
    }
    _goToSection(target, direction);
  }

  /// Change de section **avec la bascule**, quelle que soit l'origine du geste
  /// — glissement ou appui sur la barre.
  ///
  /// ⚠️ Les deux passent par ici volontairement : une bascule animée au doigt
  /// et un changement sec au clic seraient deux comportements pour une même
  /// action, et c'est exactement ce qui fait « pas fini ».
  void _goToSection(int target, int direction) {
    if (target == _index) return;
    // Le doigt a déjà emmené le contenu une partie du chemin : la bascule
    // reprend là où il s'est arrêté au lieu de repartir de zéro.
    final from = (_drag.abs() / _travel * _handover).clamp(0.0, _handover);
    setState(() {
      _direction = direction;
      _cursor.viser(target);
      _visited.add(target);
      _drag = 0;
    });
    _switch.forward(from: from);
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
