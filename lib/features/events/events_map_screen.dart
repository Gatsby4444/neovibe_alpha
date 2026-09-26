// Le mode d'affichage de la carte (`AndroidPlatformViewHostingMode`) est
// marqué expérimental par le paquet Mapbox ; on le choisit exprès (voir
// `androidHostingMode` plus bas).
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../core/models/event.dart';
import '../../core/clock.dart';
import '../../core/models/profile.dart';
import '../../core/palette.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import '../../core/widgets/avatar.dart';
import '../../core/widgets/top_banner.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../proximity/geo/coarse_location.dart';
import '../proximity/geo/heading_source.dart';
import '../proximity/geo/live_position.dart';
import '../proximity/geo/live_position_keeper.dart';
import '../proximity/geo/precision_notice.dart';
import 'event_screen.dart';
import 'events_providers.dart';
import 'map_follow.dart';
import 'map_gesture_tuning.dart';
import 'map_markers.dart';
import '../map/friends_map.dart';
import '../map/vibes_map.dart';
import '../map/friend_wheel.dart';
import '../map/walking_route.dart';
import '../connections/connections_repository.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
import '../library/open_profile.dart';
import '../library/feed/vibes_reel_screen.dart';
import 'map_settings_sheet.dart';
import 'my_point_motion.dart';

/// **La carte** (étape 5 du programme du 2026-09-21) : les soirées à portée
/// autour de moi, et — dans l'événement où je suis — ses points chauds.
///
/// ## 🔴 Sur Mapbox depuis le 2026-09-25 — décision de Jay (option B)
///
/// Le fond venait d'OpenStreetMap, dont la politique interdit l'usage d'une
/// vraie app (RAPPELS #157), et le sombre était fabriqué chez nous en
/// inversant les couleurs. C'est désormais **la carte de Mapbox** — celle
/// qu'utilise Snap : vectorielle (nette à tous les zooms, plus de tuiles
/// floues ni de zoom borné par des images), style **Standard** avec ses
/// bâtiments en 3D, mode **nuit** quand l'app est sombre, sans les étiquettes
/// de commerces qui chargeaient l'ancienne.
///
/// Compte de Jay, jeton public dans `Env.mapboxToken` (copie de
/// `docdev/mapbox.txt`). Gratuit jusqu'à 25 000 utilisateurs de la carte par
/// mois ; ⚠️ **Mapbox n'offre pas de plafond de dépense**, seulement des
/// alertes par e-mail (vérifié le 2026-09-25 dans leur FAQ).
///
/// ## Ce qui est resté, et pourquoi (captures de Jay du 2026-09-22)
///
/// - la carte **s'abonne** à la position (`LivePosition`) au lieu de prendre
///   des photos : le point se resserre comme chez les autres ;
/// - mon point porte **son halo d'incertitude, en mètres** — ce que
///   l'appareil sait vraiment ;
/// - un bouton **recentrer**, et le bandeau quand la position est bridée ;
/// - **ma position vient de NOTRE flux**, jamais du point bleu de Mapbox :
///   le sien serait un second chemin vers la même donnée, avec son propre
///   moteur — deux points qui divergent, et aucun ne dit lequel croire.
///
/// Rien n'est envoyé au serveur depuis cet écran ; il lit les mêmes vues que
/// la liste.
class EventsMapScreen extends ConsumerStatefulWidget {
  const EventsMapScreen({super.key, this.eventId});

  /// Un événement à centrer (ses points chauds) ; nul = autour de moi.
  final String? eventId;

  @override
  ConsumerState<EventsMapScreen> createState() => _EventsMapScreenState();
}

/// Le zoom d'arrivée : la rue et ce qu'il y a autour.
const _initialZoom = 16.0;

class _EventsMapScreenState extends ConsumerState<EventsMapScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  MapboxMap? _map;

  /// Les calques, du dessous au dessus : l'incertitude, les points chauds,
  /// mon point, les soirées. Un calque par nature d'objet : mon point bouge
  /// en continu, et le redessiner ne doit pas redessiner les soirées.
  PolygonAnnotationManager? _halo;
  CircleAnnotationManager? _chauds;
  PointAnnotationManager? _moi;
  PointAnnotationManager? _soirees;
  Cancelable? _tapSoirees;

  /// Les Vibes publiques autour de moi (sous les amis).
  PointAnnotationManager? _vibes;
  Cancelable? _tapVibes;
  Object? _dessineVibes;
  List<MapVibe> _vibesDessinees = const [];

  /// Mes amis (leur photo, « il y a … ») ; puis MA photo, tout en haut.
  PointAnnotationManager? _amis;
  Cancelable? _tapAmis;
  List<FriendOnMap> _amisDessines = const [];

  /// La roue d'actions ouverte sur un ami : lui, et sa place à l'écran.
  (FriendOnMap, Offset)? _roue;

  /// Le trajet à pied vers un ami (« Rejoindre »), sous les repères.
  PolylineAnnotationManager? _trajet;
  (FriendOnMap, WalkingRoute)? _itineraire;
  PointAnnotationManager? _moiPhoto;
  PointAnnotation? _moiPhotoPoint;
  Object? _dessineAmis;

  /// Les images des amis déjà posées dans le style (clé → identifiant).
  final _imagesAmis = <Object, String>{};

  /// L'envoi de MA position aux amis, carte ouverte : au plus toutes les
  /// 10 s (Jay), et seulement si je partage — le serveur le vérifie aussi.
  Timer? _partage;

  /// Ce qui est dessiné dans chaque calque — on ne redessine qu'un calque
  /// dont le contenu a CHANGÉ (la reconstruction de l'écran n'en dit rien).
  Object? _dessineChauds, _dessineSoirees;

  // ─── Mon point, qui GLISSE (2026-09-25) ──────────────────────────────────

  /// Où dessiner mon point entre deux relevés, et vers où tourner la flèche.
  final _motion = MyPointMotion();

  /// L'horloge de l'animation : elle ne tourne que tant que quelque chose
  /// bouge encore ([MyPointMotion.settledAt]).
  late final Ticker _ticker;

  /// Mon point et son halo : créés une fois, puis DÉPLACÉS — jamais effacés
  /// et recréés à chaque relevé (c'était un clignotement à chaque seconde).
  PointAnnotation? _moiPoint;
  PolygonAnnotation? _haloPoly;

  /// Un envoi à la carte à la fois, et pas plus de 30 par seconde : la carte
  /// est un objet natif, chaque déplacement est un message.
  bool _envoiEnCours = false;

  /// 60 images par seconde au plus : à 30, la caméra qui me suit avançait
  /// par petits à-coups visibles.
  final _cadence = FrameGate(const Duration(milliseconds: 16));

  /// Pour quel thème et quelle photo de profil les deux images de mon point
  /// (avec et sans flèche) sont-elles posées dans le style ?
  Object? _imagesMoiCle;

  /// La boussole : écoutée tant que la carte est à l'écran, app au premier
  /// plan.
  ProviderSubscription<AsyncValue<HeadingReading>>? _boussole;

  /// Les dessins en attente, un à la fois.
  Future<void> _file = Future.value();

  /// Les soirées dessinées, par identifiant : ce qu'ouvre un tap.
  final _parId = <String, NearbyEvent>{};

  /// Le réglage de style appliqué (lumière jour / nuit, objets 3D).
  String? _lumiere;

  /// ⚠️ **Posé une seule fois, au premier build utile.** Recalculer le centre
  /// à chaque reconstruction ramènerait la carte de force sous le doigt dès
  /// qu'une position arrive ou qu'un point chaud bouge.
  Point? _centreInitial;

  /// La vue de départ, créée une fois (voir [build]).
  CameraViewportState? _vue;

  /// La carte s'est-elle déjà posée sur le premier relevé reçu ?
  ///
  /// ⚠️ Une seule fois, et c'est tout l'objet de ce drapeau : le flux publie
  /// un relevé toutes les quelques secondes, et sans lui la carte reviendrait
  /// se recentrer de force sous le doigt de quelqu'un en train de la déplacer.
  bool _poseeSurMoi = false;

  /// Pour demander la position précise, et un relevé avant le premier.
  /// Le suivi continu, lui, est tenu par [LivePositionKeeper] (voir [build]).
  late final LivePosition _position;

  /// **Ce que la carte fait avec mon point** (bouton « recentrer », façon
  /// Google Maps, 2026-09-26).
  MapFollow _suivi = MapFollow.libre;

  /// Pendant l'animation vers mon point, la caméra n'est pas encore à nous :
  /// la suivre image par image se battrait avec l'animation.
  DateTime _suiviPretA = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _position = ref.read(livePositionProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick);
    // Chaque relevé NEUF relance le glissement — pas chaque reconstruction.
    ref.listenManual(livePositionProvider, (avant, apres) {
      // Le relevé à SUIVRE, pas le meilleur : voir [LivePositionState.track].
      final fix = apres.track;
      if (fix == null || identical(fix, avant?.track)) return;
      _motion.setFix(fix.latitude, fix.longitude, fix.accuracy, DateTime.now());
      _reveiller();
    }, fireImmediately: true);
    _ecouterBoussole();
    _demarrerPartage();
  }

  void _ecouterBoussole() {
    _boussole ??= ref.listenManual(headingProvider, (_, lu) {
      final h = lu.value;
      if (h == null) return;
      _motion.setHeading(h.degrees);
      _reveiller();
    });
  }

  void _couperBoussole() {
    _boussole?.close();
    _boussole = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapSoirees?.cancel();
    _tapVibes?.cancel();
    _tapAmis?.cancel();
    _ticker.dispose();
    _couperBoussole();
    _arreterPartage();
    super.dispose();
  }

  /// **La boussole s'arrête dès qu'on quitte l'app** : personne ne regarde
  /// la flèche. (La position, elle, est relâchée par [LivePositionKeeper].)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ecouterBoussole();
      _demarrerPartage();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _couperBoussole();
      // Hors de l'app, la position des amis passe par la balise (30 min).
      _arreterPartage();
    }
  }

  static Point _pt(double lat, double lon) =>
      Point(coordinates: Position(lon, lat));

  void _allerA(double lat, double lon) {
    unawaited(
      _map?.flyTo(
        CameraOptions(center: _pt(lat, lon), zoom: _initialZoom),
        MapAnimationOptions(duration: 600),
      ),
    );
  }

  /// **Le bouton, façon Google Maps** (Jay, 2026-09-26) : un premier appui
  /// centre la carte sur mon point et la fait me suivre ; un deuxième la fait
  /// tourner avec moi (ce qui est devant moi en haut) ; un troisième la
  /// remet nord en haut. Déplacer la carte à la main la libère ([_onPan]).
  ///
  /// ⚠️ **La cible est là où mon point est DESSINÉ** — la même source que le
  /// point, jamais une autre. Corrigé le 2026-09-25 au soir (constat de
  /// Jay) : le bouton demandait le MEILLEUR relevé gardé, que l'app conserve
  /// jusqu'à 5 minutes ; le point, lui, suit le relevé à SUIVRE
  /// (`LivePositionState.track`). Le point était juste, le bouton ramenait à
  /// une ancienne position.
  Future<void> _recentrer() async {
    final now = DateTime.now();
    var ici = _motion.positionAt(now);
    if (ici == null) {
      // Avant le premier relevé seulement : on en demande un.
      final me = await _position.current();
      if (me == null || !mounted) return;
      ici = (lat: me.latitude, lon: me.longitude);
    }
    final cap = _motion.frameAt(now)?.heading;
    final mode = _suivi.afterTap(hasHeading: cap != null);
    setState(() => _suivi = mode);
    _suiviPretA = now.add(const Duration(milliseconds: 700));
    await _appliquerGestes(mode);
    final zoom = (await _map?.getCameraState())?.zoom ?? _initialZoom;
    final boussole = mode == MapFollow.boussole;
    final quitteBoussole = !boussole && _vueDeDerriere;
    _vueDeDerriere = boussole;
    if (!mounted) return;
    // En mode boussole, la « vue de derrière » (Jay, 2026-09-26) : la carte
    // s'incline et mon point descend vers le bas de l'écran — on voit ce
    // qui est DEVANT soi, comme en navigation.
    final hauteur = MediaQuery.sizeOf(context).height;
    unawaited(
      _map?.flyTo(
        CameraOptions(
          center: _pt(ici.lat, ici.lon),
          // Trop loin pour voir la rue : on s'approche ; sinon on garde le
          // zoom choisi. La vue de derrière se regarde de plus près.
          zoom: boussole
              ? math.max(zoom, _zoomDerriere)
              : (zoom < 14 ? _initialZoom : zoom),
          // Centré depuis la carte libre : on garde l'orientation choisie à
          // la main ; en sortant de la boussole, retour nord en haut.
          bearing: boussole ? cap : (quitteBoussole ? 0 : null),
          pitch: boussole ? _inclinaisonDerriere : (quitteBoussole ? 0 : null),
          padding: boussole
              ? MbxEdgeInsets(top: hauteur * 0.35, left: 0, bottom: 0, right: 0)
              : (quitteBoussole
                    ? MbxEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
                    : null),
        ),
        MapAnimationOptions(duration: 800),
      ),
    );
    _suiviPretA = DateTime.now().add(const Duration(milliseconds: 900));
    _reveiller();
  }

  /// Ce qui a été envoyé en dernier à la carte, pour mon point et son
  /// cercle : on ne renvoie que ce qui a changé ([_poserMoi]).
  Object? _envoyeHalo, _envoyePoint, _envoyeCamera, _envoyePhoto;

  /// La vue de derrière est-elle posée (inclinaison + point en bas) ?
  bool _vueDeDerriere = false;

  /// L'inclinaison de la vue de derrière, en degrés (0 = vue du dessus).
  static const _inclinaisonDerriere = 55.0;

  /// Le zoom minimum de la vue de derrière : assez près pour les bâtiments.
  static const _zoomDerriere = 17.0;

  /// **Les gestes, tels que Jay les a relevés sur Google Maps** (2026-09-26)
  ///
  /// | Doigts | Geste | Effet |
  /// |---|---|---|
  /// | 1 | glisser | déplacer la carte |
  /// | 1 | double appui (maintenu : glisser) | zoomer |
  /// | 2 | se rapprocher / s'écarter EN PREMIER | zoom seul, jusqu'au bout |
  /// | 2 | glisser ensemble | déplacer ; incliner si la montée se prolonge ~4 mm |
  /// | 2 | tourner en sens opposés | rotation, et zoom en même temps |
  ///
  /// 🔴 **Tout est fait par le moteur de Mapbox**, qui lit les doigts sans
  /// détour — c'est ce qui fait la précision (Jay, après la v0.9.282 : « pas
  /// assez précis, Google est ultra précis »). La v0.9.281-282 reconnaissait
  /// les gestes à deux doigts dans Flutter et envoyait la caméra par
  /// messages : un temps de retard, des positions sautées. Ce moteur a déjà
  /// la hiérarchie de Google (lu dans son code) ; seuls ses seuils sont
  /// réglés : `res/values/mapbox_gestures.xml` et [MapGestureTuning].
  ///
  /// - `simultaneousRotateAndPinchToZoomEnabled: false` : c'est ce qui fait
  ///   qu'un zoom parti en premier coupe la rotation, et qu'une rotation
  ///   partie en premier laisse le zoom s'ajouter (règles 1 et 3).
  /// - Quand la carte me suit, pincer ne la déplace pas (elle me
  ///   ramènerait au centre à l'image suivante).
  /// - En mode boussole, pas de rotation : c'est ma direction qui oriente
  ///   la carte. La boussole de Mapbox (touchée, elle remet le nord) est
  ///   visible hors de ce mode.
  Future<void> _appliquerGestes(MapFollow mode) async {
    final map = _map;
    if (map == null) return;
    final boussole = mode == MapFollow.boussole;
    await map.gestures.updateSettings(
      GesturesSettings(
        scrollEnabled: true,
        scrollMode: ScrollMode.HORIZONTAL_AND_VERTICAL,
        // L'élan est le NÔTRE (celui des listes d'Android, MapGestureTuner.kt) :
        // celui de Mapbox ne part qu'au-delà de 1 000 dp/s, et deux élans se
        // battraient.
        scrollDecelerationEnabled: false,
        pinchToZoomEnabled: true,
        pinchPanEnabled: !mode.follows,
        simultaneousRotateAndPinchToZoomEnabled: false,
        increaseRotateThresholdWhenPinchingToZoom: true,
        increasePinchToZoomThresholdWhenRotating: true,
        rotateEnabled: !boussole,
        pitchEnabled: true,
        quickZoomEnabled: true,
        doubleTapToZoomInEnabled: true,
        doubleTouchToZoomOutEnabled: true,
      ),
    );
    await map.compass.updateSettings(CompassSettings(enabled: !boussole));
  }

  /// Règle les gestes dans le moteur de la carte.
  Future<void> _reglerGestes() => MapGestureTuning.tune();

  /// **La roue de réglages** : les réglages de la carte pour l'utilisateur
  /// (Jay, 2026-09-26), sans quitter la carte.
  void _ouvrirReglages() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const SafeArea(
        child: SingleChildScrollView(child: MapSettingsSheet()),
      ),
    );
  }

  /// La carte déplacée à la main : elle cesse de me suivre.
  void _onPan(MapContentGestureContext _) {
    if (_roue != null) setState(() => _roue = null);
    if (!_suivi.follows) return;
    final mode = _suivi.afterPan;
    setState(() => _suivi = mode);
    unawaited(_appliquerGestes(mode));
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    // ⚠️ **Une carte neuve n'a rien de ce qu'on avait posé sur l'ancienne**
    // (la carte est recréée quand on change son mode d'affichage) : on
    // oublie tout ce qui la désignait, sinon on déplacerait des points qui
    // n'existent plus — en silence.
    _moiPoint = null;
    _moiPhotoPoint = null;
    _haloPoly = null;
    _dessineAmis = null;
    _dessineVibes = null;
    _imagesAmis.clear();
    _envoyeHalo = null;
    _envoyePoint = null;
    _envoyeCamera = null;
    _envoyePhoto = null;
    _dessineChauds = null;
    _dessineSoirees = null;
    _imagesMoiCle = null;
    _dessineAmis = null;
    _dessineVibes = null;
    _imagesAmis.clear();
    _lumiere = null;
    // Tourner à deux doigts : permis hors mode boussole ([_appliquerGestes]).
    // L'inclinaison (glisser à deux doigts vers le haut) montre la 3D.
    await _appliquerGestes(_suivi);
    unawaited(_reglerGestes());
    await map.setBounds(CameraBoundsOptions(minZoom: 4, maxZoom: 20));
    await map.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
    // ⚠️ **Le logo et l'attribution sont obligatoires, donc LISIBLES** : au
    // bas de l'écran, ils passaient sous la barre de navigation du téléphone
    // (même défaut que l'ancienne attribution, capture du 2026-09-22).
    if (!mounted) return;
    final bas = MediaQuery.paddingOf(context).bottom + 6;
    await map.logo.updateSettings(LogoSettings(marginBottom: bas));
    await map.attribution.updateSettings(
      AttributionSettings(marginBottom: bas),
    );
    final a = map.annotations;
    _trajet = await a.createPolylineAnnotationManager();
    _halo = await a.createPolygonAnnotationManager();
    _chauds = await a.createCircleAnnotationManager();
    _moi = await a.createPointAnnotationManager();
    // La flèche est posée À PLAT sur la carte et orientée par rapport au
    // nord — pas par rapport à l'écran : carte inclinée, elle reste au sol.
    await _moi!.setIconRotationAlignment(IconRotationAlignment.MAP);
    await _moi!.setIconPitchAlignment(IconPitchAlignment.MAP);
    await _moi!.setIconAllowOverlap(true);
    await _moi!.setIconIgnorePlacement(true);
    _soirees = await a.createPointAnnotationManager();
    // Au-dessus des soirées : les Vibes, mes amis, puis ma photo.
    _vibes = await a.createPointAnnotationManager();
    await _vibes!.setIconAllowOverlap(true);
    _tapVibes = _vibes!.tapEvents(
      onTap: (annotation) {
        final id = annotation.customData?['vibe'];
        if (id is String) unawaited(_ouvrirVibe(id));
      },
    );
    _amis = await a.createPointAnnotationManager();
    await _amis!.setIconAllowOverlap(true);
    _tapAmis = _amis!.tapEvents(
      onTap: (annotation) {
        final id = annotation.customData?['ami'];
        if (id is String) unawaited(_ouvrirRoue(id));
      },
    );
    await _amis!.setTextAllowOverlap(true);
    _moiPhoto = await a.createPointAnnotationManager();
    await _moiPhoto!.setIconAllowOverlap(true);
    await _moiPhoto!.setIconIgnorePlacement(true);
    _tapSoirees = _soirees!.tapEvents(
      onTap: (annotation) {
        final id = annotation.customData?['id'];
        final e = id is String ? _parId[id] : null;
        if (e == null || !mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EventScreen(eventId: e.id, preview: e),
          ),
        );
      },
    );
    if (mounted) setState(() {});
    _reveiller();
  }

  /// Le style chargé : on règle sa lumière et ses étiquettes. Rappelé à
  /// chaque rechargement du style (le réglage vit DANS le style).
  void _onStyleLoaded(StyleLoadedEventData _) {
    // Deuxième passage : la vue native est parfois accrochée à l'écran
    // après la création. Une carte déjà réglée ne l'est pas deux fois.
    unawaited(_reglerGestes());
    _lumiere = null;
    // Les images vivent DANS le style : un style rechargé les a perdues.
    _imagesMoiCle = null;
    _dessineAmis = null;
    _dessineVibes = null;
    _imagesAmis.clear();
    if (mounted) setState(() {});
  }

  /// **Le style Standard, réglé pour un fond** : nuit si l'app est sombre
  /// (une carte claire la nuit éblouit — capture de 21:43, 2026-09-22), et
  /// sans commerces ni arrêts, qui chargeaient l'ancienne carte (pharmacies,
  /// numéros). Les rues et les quartiers restent : c'est ce qui situe.
  void _reglerStyle(bool dark, {required bool objets3d}) {
    final map = _map;
    final voulu = '${dark ? 'night' : 'day'}-$objets3d';
    if (map == null || _lumiere == voulu) return;
    _lumiere = voulu;
    unawaited(
      map.style
          .setStyleImportConfigProperties('basemap', {
            'lightPreset': dark ? 'night' : 'day',
            // Interrupteur de test (Réglages › Développeur) : la 3D est ce
            // qui coûte le plus à dessiner.
            'show3dObjects': objets3d,
            'showPointOfInterestLabels': false,
            'showTransitLabels': false,
            'showLandmarkIcons': false,
          })
          .catchError((Object _) {
            // Style pas encore prêt : [_onStyleLoaded] rappellera.
            _lumiere = null;
          }),
    );
  }

  /// Redessine chaque calque **dont le contenu a changé**, et seulement lui.
  Future<void> _dessiner({
    required NeoPalette p,
    required List<HotSpot> spots,
    required List<NearbyEvent> nearby,
    required List<NearbyEvent> gros,
    required NeoEvent? event,
  }) async {
    // Les points chauds : un cercle par cellule de 50 m, proportionnel au
    // monde qu'il y a. ⚠️ **Seulement là où il y a du monde (2026-09-24)** :
    // le serveur rend aussi le LIEU, à 0 personne — dessiné pareil, il
    // faisait un rond rose sur un endroit vide. Le lieu a son repère.
    final chauds = [
      for (final s in spots)
        if (s.headcount > 0) (s.lat, s.lon, s.headcount),
    ];
    final cleChauds = (Object.hashAll(chauds), p.action);
    if (_chauds != null && cleChauds != _dessineChauds) {
      _dessineChauds = cleChauds;
      await _chauds!.deleteAll();
      if (chauds.isNotEmpty) {
        await _chauds!.createMulti([
          for (final (lat, lon, n) in chauds)
            CircleAnnotationOptions(
              geometry: _pt(lat, lon),
              circleRadius: 12.0 + 4 * n.clamp(0, 10),
              circleColor: p.action.toARGB32(),
              circleOpacity: 0.25,
              circleStrokeColor: p.action.toARGB32(),
              circleStrokeWidth: 1.5,
            ),
        ]);
      }
    }

    // Les soirées à portée (nom · présents, un tap ouvre), ou le lieu de la
    // soirée affichée — un repère, pas un point chaud.
    final lieu = event?.lat != null && event?.lon != null
        ? (event!.lat!, event.lon!)
        : null;
    // Les gros événements VUS DE LOIN : seulement ceux qui ne sont pas déjà
    // dans le rayon choisi (ceux-là ont leur repère ordinaire).
    final proches = {for (final e in nearby) e.id};
    final loin = [
      for (final e in gros)
        if (!proches.contains(e.id)) e,
    ];
    final cleSoirees = (
      Object.hashAll([
        for (final e in [...nearby, ...loin])
          (e.id, e.title, e.presentCount, e.lat, e.lon, e.kind),
      ]),
      loin.length,
      lieu,
      p.isDark,
    );
    if (_soirees != null && cleSoirees != _dessineSoirees) {
      _dessineSoirees = cleSoirees;
      await _soirees!.deleteAll();
      _parId
        ..clear()
        ..addEntries(nearby.map((e) => MapEntry(e.id, e)))
        ..addEntries(loin.map((e) => MapEntry(e.id, e)));
      final fete = await _repere(p, Icons.celebration_rounded);
      final boutique = nearby.any((e) => e.kind != EventKind.open)
          ? await _repere(p, Icons.storefront_rounded)
          : fete;
      // Un gros événement : plus grand, une flamme — il se voit de loin.
      final flamme = loin.isEmpty
          ? fete
          : await _repere(p, Icons.local_fire_department_rounded, points: 48);
      await _soirees!.createMulti([
        if (lieu != null)
          PointAnnotationOptions(geometry: _pt(lieu.$1, lieu.$2), image: fete),
        for (final e in nearby)
          PointAnnotationOptions(
            geometry: _pt(e.lat, e.lon),
            image: e.kind == EventKind.open ? fete : boutique,
            textField: '${e.title} · ${e.presentCount}',
            textSize: 12,
            textAnchor: TextAnchor.TOP,
            textOffset: [0, 1.3],
            textColor: p.ink.toARGB32(),
            textHaloColor: p.surface.toARGB32(),
            textHaloWidth: 1.5,
            customData: {'id': e.id},
          ),
        for (final e in loin)
          PointAnnotationOptions(
            geometry: _pt(e.lat, e.lon),
            image: flamme,
            textField: '${e.title}\n${e.presentCount} présents',
            textSize: 13,
            textAnchor: TextAnchor.TOP,
            textOffset: [0, 1.6],
            textColor: p.ink.toARGB32(),
            textHaloColor: p.surface.toARGB32(),
            textHaloWidth: 1.5,
            customData: {'id': e.id},
          ),
      ]);
    }
  }

  /// **Les Vibes publiques autour de moi** (Jay, 2026-09-26) : une pastille
  /// par Vibe ; les plus aimées plus grandes, avec leur nombre de « j'aime ».
  Future<void> _dessinerVibes(NeoPalette p, List<MapVibe> vibes) async {
    final calque = _vibes;
    if (calque == null || _map == null) return;
    final cle = (Object.hashAll(vibes), p.isDark);
    if (cle == _dessineVibes) return;
    _dessineVibes = cle;
    _vibesDessinees = vibes;
    try {
      await calque.deleteAll();
      if (vibes.isEmpty) return;
      final recente = await _repere(p, Icons.bolt_rounded, points: 26);
      final populaire = vibes.any((v) => v.populaire)
          ? await _repere(p, Icons.favorite_rounded, points: 34)
          : recente;
      await calque.createMulti([
        for (final v in vibes)
          PointAnnotationOptions(
            geometry: _pt(v.lat, v.lng),
            image: v.populaire ? populaire : recente,
            textField: v.populaire ? '${v.likes}' : null,
            textSize: 11,
            textAnchor: TextAnchor.TOP,
            textOffset: [0, 1.2],
            textColor: p.ink.toARGB32(),
            textHaloColor: p.surface.toARGB32(),
            textHaloWidth: 1.5,
            customData: {'vibe': v.id},
          ),
      ]);
    } catch (_) {
      _dessineVibes = null;
    }
  }

  /// Une Vibe touchée : le lecteur s'ouvre dessus, avec toutes celles de la
  /// carte à faire défiler.
  Future<void> _ouvrirVibe(String id) async {
    final fix = await _position.current();
    if (fix == null || !mounted) return;
    try {
      final items = await ref
          .read(vibesMapRepositoryProvider)
          .items(
            [for (final v in _vibesDessinees) v.id],
            fix.latitude,
            fix.longitude,
          );
      final i = items.indexWhere((it) => it.id == id);
      if (i < 0 || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VibesReelScreen(vibes: items, initialIndex: i),
        ),
      );
    } catch (e) {
      if (mounted) {
        TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
      }
    }
  }

  /// **Mes amis sur la carte** (Jay, 2026-09-26) : leur photo dans un rond,
  /// et, dessous, leur prénom et de quand date leur position (« il y a
  /// 45 min »). Redessinés seulement si l'un a bougé, ou si la minute a
  /// changé (le « il y a » vieillit).
  Future<void> _dessinerAmis(
    NeoPalette p,
    List<FriendOnMap> amis,
    DateTime maintenant,
  ) async {
    final calque = _amis;
    if (calque == null || _map == null) return;
    final cle = (
      Object.hashAll(amis),
      maintenant.difference(DateTime(2026)).inMinutes,
      p.isDark,
    );
    if (cle == _dessineAmis) return;
    _dessineAmis = cle;
    _amisDessines = amis;
    try {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final images = <String, String>{};
      for (final ami in amis) {
        final cleImage = (ami.userId, ami.avatarUrl, ami.displayName, p.isDark);
        var id = _imagesAmis[cleImage];
        if (id == null) {
          id = 'ami-${_imagesAmis.length}';
          final stored = ami.avatarUrl;
          final fichier = stored == null || stored.isEmpty
              ? null
              : await ref.read(avatarFileProvider(stored).future);
          final photo = await MapMarkers.photo(fichier);
          final png = await MapMarkers.rond(
            dpr: dpr,
            cote: _cotePhoto,
            rayon: 15,
            anneau: p.action,
            fond: p.ground,
            photo: photo,
            initiales: MapMarkers.initiales(ami.displayName),
          );
          photo?.dispose();
          final cote = (_cotePhoto * dpr).round();
          await _map!.style.addStyleImage(
            id,
            dpr,
            MbxImage(width: cote, height: cote, data: png),
            false,
            [],
            [],
            null,
          );
          _imagesAmis[cleImage] = id;
        }
        images[ami.userId] = id;
      }
      await calque.deleteAll();
      if (amis.isEmpty) return;
      await calque.createMulti([
        for (final ami in amis)
          PointAnnotationOptions(
            geometry: _pt(ami.lat, ami.lon),
            iconImage: images[ami.userId],
            textField:
                '${ami.displayName.split(' ').first} · '
                '${ilYa(ami.at, maintenant)}',
            textSize: 11,
            textAnchor: TextAnchor.TOP,
            textOffset: [0, 1.6],
            textColor: p.ink.toARGB32(),
            textHaloColor: p.surface.toARGB32(),
            textHaloWidth: 1.5,
            customData: {'ami': ami.userId},
          ),
      ]);
    } catch (_) {
      // Carte détruite en plein dessin : rien à rattraper.
      _dessineAmis = null;
    }
  }

  /// **Déposer ma position pour mes amis**, carte ouverte, au plus toutes
  /// les 10 s — et seulement si je partage (le serveur le revérifie, et
  /// ignore ce qui arrive plus vite que sa règle).
  Future<void> _partagerMaPosition() async {
    if (ref.read(locationSharingProvider).value != true) return;
    final live = ref.read(livePositionProvider);
    final fix = live.track ?? live.fix;
    final depuis = live.trackAt ?? live.at;
    if (fix == null || depuis == null) return;
    if (DateTime.now().difference(depuis) > const Duration(minutes: 2)) return;
    try {
      await ref
          .read(friendsMapRepositoryProvider)
          .shareMyLocation(fix.latitude, fix.longitude, fix.accuracy);
    } catch (_) {
      // Réseau absent : le prochain tour réessaiera.
    }
  }

  void _demarrerPartage() {
    _partage ??= Timer.periodic(
      friendsRefreshEvery,
      (_) => unawaited(_partagerMaPosition()),
    );
    unawaited(_partagerMaPosition());
  }

  void _arreterPartage() {
    _partage?.cancel();
    _partage = null;
  }

  /// **La roue d'actions** sur la photo d'un ami (Jay, 2026-09-26).
  Future<void> _ouvrirRoue(String amiId) async {
    final ami = _amisDessines.where((a) => a.userId == amiId).firstOrNull;
    final map = _map;
    if (ami == null || map == null) return;
    final ecran = await map.pixelForCoordinate(_pt(ami.lat, ami.lon));
    if (!mounted) return;
    setState(() => _roue = (ami, Offset(ecran.x, ecran.y)));
  }

  void _fermerRoue() {
    if (_roue != null) setState(() => _roue = null);
  }

  Future<void> _voirProfil(FriendOnMap ami) async {
    _fermerRoue();
    final profil = await ref.read(profileByIdProvider(ami.userId).future);
    if (profil != null && mounted) openProfile(context, profil);
  }

  Future<void> _message(FriendOnMap ami) async {
    _fermerRoue();
    try {
      final conv = await ref
          .read(conversationsRepositoryProvider)
          .getOrCreateDirect(ami.userId);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(conversationId: conv),
        ),
      );
    } catch (e) {
      if (mounted) {
        TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
      }
    }
  }

  Future<void> _demanderPosition(FriendOnMap ami) async {
    _fermerRoue();
    try {
      await ref.read(friendsMapRepositoryProvider).requestLocation(ami.userId);
      if (mounted) {
        TopBanner.show(
          context,
          'Demande envoyée à ${ami.displayName.split(' ').first} — '
          'dans votre conversation.',
        );
      }
    } catch (e) {
      if (mounted) {
        TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
      }
    }
  }

  /// **Rejoindre** : le trajet à pied le plus court, dessiné sur la carte.
  Future<void> _rejoindre(FriendOnMap ami) async {
    _fermerRoue();
    final ici =
        _motion.positionAt(DateTime.now()) ??
        await _position.current().then(
          (f) => f == null ? null : (lat: f.latitude, lon: f.longitude),
        );
    if (ici == null || !mounted) return;
    try {
      final trajet = await ref
          .read(walkingRouteServiceProvider)
          .route(ici.lat, ici.lon, ami.lat, ami.lon);
      if (!mounted) return;
      if (trajet == null) {
        TopBanner.show(
          context,
          'Aucun trajet à pied trouvé.',
          tone: TopBannerTone.already,
        );
        return;
      }
      setState(() => _itineraire = (ami, trajet));
      await _dessinerTrajet(context.palette, trajet);
    } catch (e) {
      if (mounted) {
        TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
      }
    }
  }

  Future<void> _dessinerTrajet(NeoPalette p, WalkingRoute? trajet) async {
    final calque = _trajet;
    if (calque == null) return;
    await calque.deleteAll();
    if (trajet == null || trajet.points.length < 2) return;
    await calque.create(
      PolylineAnnotationOptions(
        geometry: LineString(
          coordinates: [
            for (final (lat, lon) in trajet.points) Position(lon, lat),
          ],
        ),
        lineColor: p.action.toARGB32(),
        lineWidth: 5,
        lineOpacity: 0.85,
      ),
    );
  }

  void _effacerTrajet() {
    setState(() => _itineraire = null);
    unawaited(_dessinerTrajet(context.palette, null));
  }

  /// Quelque chose bouge : on relance l'horloge si elle dort.
  void _reveiller() {
    if (mounted && !_ticker.isActive) _ticker.start();
  }

  /// Un battement de l'animation : où est mon point MAINTENANT, et on
  /// l'envoie à la carte — au plus 30 fois par seconde, un envoi à la fois.
  void _tick(Duration ecoule) {
    if (_moi == null || _halo == null || _map == null) return;
    if (_envoiEnCours) return;
    final now = DateTime.now();
    // ⚠️ L'HEURE RÉELLE, jamais [ecoule] : voir [FrameGate].
    if (!_cadence.laisse(now)) return;
    final frame = _motion.frameAt(now);
    if (frame == null) {
      _ticker.stop();
      return;
    }
    _envoiEnCours = true;
    final arrive = _motion.settledAt(now);
    _poserMoi(frame, context.palette, suivre: _suivre(now)).whenComplete(() {
      _envoiEnCours = false;
      // Arrivé : l'horloge s'endort jusqu'au prochain relevé ou au prochain
      // mouvement de boussole.
      if (arrive && mounted && _motion.settledAt(DateTime.now())) {
        _ticker.stop();
      }
    });
  }

  /// Pose mon point et son halo à [frame] : créés la première fois, puis
  /// seulement déplacés.
  Future<void> _poserMoi(
    MyPointFrame frame,
    NeoPalette p, {
    MapFollow suivre = MapFollow.libre,
  }) async {
    try {
      final profil = ref.read(myProfileProvider).value;
      final cleImages = (p.isDark, profil?.avatarUrl, profil?.displayName);
      if (_imagesMoiCle != cleImages) {
        await _poserImagesMoi(p, profil);
        _imagesMoiCle = cleImages;
      }
      final ou = _pt(frame.lat, frame.lon);
      final image = frame.heading == null ? _imgVide : _imgCone;
      final cap = frame.heading ?? 0;
      final photo = _moiPhotoPoint;
      final clePhoto = (frame.lat, frame.lon);
      final bougePhoto = photo == null || clePhoto != _envoyePhoto;
      _envoyePhoto = clePhoto;
      // ⚠️ **Le halo d'incertitude, en MÈTRES.** L'appareil ne sait pas où
      // il est au mètre près (21 m au mieux, 100 m et plus en intérieur).
      // Un point net sans halo affirme une précision qu'on n'a pas.
      final cercle = _cercle(frame.lat, frame.lon, frame.accuracy);
      final point = _moiPoint;
      final halo = _haloPoly;
      // ⚠️ **N'envoyer que ce qui a CHANGÉ** (2026-09-26, carte saccadée).
      // La boussole tremble sans arrêt, même immobile : chaque tremblement
      // renvoyait le point ET le cercle d'incertitude — 49 sommets — jusqu'à
      // 60 fois par seconde, y compris pendant qu'on déplaçait la carte au
      // doigt. Le cercle ne dépend que de la position ; le point, de la
      // position et de la flèche, à un degré près.
      final cleHalo = (frame.lat, frame.lon, frame.accuracy.round());
      final bougeHalo = halo == null || cleHalo != _envoyeHalo;
      final clePoint = (frame.lat, frame.lon, image, cap.round());
      final bougePoint = point == null || clePoint != _envoyePoint;
      // La caméra aussi : tourner TOUTE la carte pour un tremblement d'un
      // dixième de degré la redessine entièrement, pour rien.
      final cleCamera = suivre.follows
          ? (
              frame.lat,
              frame.lon,
              suivre == MapFollow.boussole ? (cap * 2).round() : null,
            )
          : null;
      final bougeCamera = cleCamera != null && cleCamera != _envoyeCamera;
      _envoyeHalo = cleHalo;
      _envoyePoint = clePoint;
      _envoyeCamera = cleCamera;
      // Les trois envois partent ENSEMBLE : l'un après l'autre, leurs allers-
      // retours s'additionnaient et limitaient le nombre d'images par
      // seconde.
      await Future.wait([
        // La caméra suit mon point — et tourne avec moi en mode boussole —
        // dans le MÊME battement que le point : ils bougent ensemble.
        if (bougeCamera)
          _map!.setCamera(
            CameraOptions(
              center: ou,
              bearing: suivre == MapFollow.boussole ? frame.heading : null,
            ),
          ),
        if (bougePoint && point == null)
          _moi!
              .create(
                PointAnnotationOptions(
                  geometry: ou,
                  iconImage: image,
                  iconRotate: cap,
                ),
              )
              .then((a) => _moiPoint = a)
        else if (bougePoint)
          _moi!.update(
            point
              ..geometry = ou
              ..iconImage = image
              ..iconRotate = cap,
          ),
        if (bougePhoto && photo == null)
          _moiPhoto!
              .create(
                PointAnnotationOptions(geometry: ou, iconImage: _imgPhoto),
              )
              .then((a) => _moiPhotoPoint = a)
        else if (bougePhoto)
          _moiPhoto!.update(photo..geometry = ou),
        if (bougeHalo && halo == null)
          _halo!
              .create(
                PolygonAnnotationOptions(
                  geometry: cercle,
                  fillColor: p.cool.toARGB32(),
                  fillOpacity: 0.12,
                  fillOutlineColor: p.cool.withValues(alpha: 0.4).toARGB32(),
                ),
              )
              .then((a) => _haloPoly = a)
        else if (bougeHalo)
          _halo!.update(halo..geometry = cercle),
      ]);
    } catch (_) {
      // Carte détruite en plein envoi (écran refermé) : rien à rattraper.
    }
  }

  /// Le mode de suivi à appliquer à [now] : aucun tant que l'animation
  /// vers mon point n'est pas finie.
  MapFollow _suivre(DateTime now) =>
      now.isBefore(_suiviPretA) ? MapFollow.libre : _suivi;

  static const _imgPhoto = 'neovibe-moi-photo';
  static const _imgCone = 'neovibe-moi-cone';
  static const _imgVide = 'neovibe-vide';

  /// **Mon point : ma photo de profil** (Jay, 2026-09-26), dans un anneau
  /// de ma couleur, face à l'écran ; dessous, le cône de direction posé à
  /// plat sur la carte quand la boussole répond. Sans photo : mes initiales.
  Future<void> _poserImagesMoi(NeoPalette p, Profile? profil) async {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final stored = profil?.avatarUrl;
    final fichier = stored == null || stored.isEmpty
        ? null
        : await ref.read(avatarFileProvider(stored).future);
    final photo = await MapMarkers.photo(fichier);
    try {
      final images = <String, (Uint8List, double)>{
        _imgPhoto: (
          await MapMarkers.rond(
            dpr: dpr,
            cote: _cotePhoto,
            rayon: _rayonMoi,
            anneau: p.cool,
            fond: p.ground,
            photo: photo,
            initiales: MapMarkers.initiales(profil?.displayName ?? ''),
          ),
          _cotePhoto,
        ),
        _imgCone: (
          await MapMarkers.cone(dpr: dpr, cote: _coteMoi, couleur: p.cool),
          _coteMoi,
        ),
      };
      for (final MapEntry(key: id, value: (png, cotePts)) in images.entries) {
        final cote = (cotePts * dpr).round();
        await _map!.style.addStyleImage(
          id,
          dpr,
          MbxImage(width: cote, height: cote, data: png),
          false,
          [],
          [],
          null,
        );
      }
      await _map!.style.addStyleImage(
        _imgVide,
        1,
        MbxImage(width: 1, height: 1, data: await MapMarkers.vide()),
        false,
        [],
        [],
        null,
      );
    } finally {
      photo?.dispose();
    }
  }

  /// Côté de l'image de ma photo, en points (le rond et son liseré).
  static const _cotePhoto = 44.0;

  /// Côté de l'image de mon point, en points : la place du cône.
  static const _coteMoi = 76.0;

  /// Rayon du rond de ma photo, en points.
  static const _rayonMoi = 17.0;

  /// Un cercle de [rayonM] mètres, en polygone (la carte ne sait dessiner un
  /// cercle qu'en PIXELS ; un halo d'incertitude se mesure en mètres).
  static Polygon _cercle(double lat, double lon, double rayonM) {
    const pas = 48;
    final dLat = rayonM / 111320;
    final dLon = rayonM / (111320 * math.cos(lat * math.pi / 180));
    return Polygon(
      coordinates: [
        [
          for (var i = 0; i <= pas; i++)
            Position(
              lon + dLon * math.sin(2 * math.pi * i / pas),
              lat + dLat * math.cos(2 * math.pi * i / pas),
            ),
        ],
      ],
    );
  }

  /// Le repère d'une soirée : un rond au dégradé de l'app, l'icône dedans,
  /// cerclé de la couleur du fond. Dessiné en image (la carte n'affiche que
  /// des images), à la densité de l'écran pour rester net.
  Future<Uint8List> _repere(
    NeoPalette p,
    IconData icone, {
    double points = 34,
  }) async {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final taille = points * dpr;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final centre = Offset(taille / 2, taille / 2);
    final rect = Offset.zero & ui.Size(taille, taille);
    canvas.drawCircle(
      centre,
      taille / 2 - 1,
      Paint()..shader = p.signatureCourte.createShader(rect),
    );
    canvas.drawCircle(
      centre,
      taille / 2 - 1 * dpr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * dpr
        ..color = p.ground,
    );
    final texte = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icone.codePoint),
        style: TextStyle(
          fontFamily: icone.fontFamily,
          package: icone.fontPackage,
          fontSize: points * 0.53 * dpr,
          color: p.onAction,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    texte.paint(canvas, centre - Offset(texte.width / 2, texte.height / 2));
    final image = await recorder.endRecording().toImage(
      taille.round(),
      taille.round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final eventId = widget.eventId;
    final event = eventId == null
        ? null
        : ref.watch(eventByIdProvider(eventId));
    // Les soirées de la CARTE : dans le rayon choisi (roue), et les gros
    // événements de plus loin.
    final nearby = eventId == null
        ? ref.watch(mapEventsProvider)
        : const AsyncValue<List<NearbyEvent>>.data([]);
    // Mes amis, relus toutes les 10 s tant que la carte est ouverte ; et la
    // minute, pour que « il y a … » vieillisse.
    final amis = ref.watch(friendsOnMapProvider).value ?? const <FriendOnMap>[];
    final vibes = ref.watch(mapVibesProvider).value ?? const <MapVibe>[];
    final minute =
        ref.watch(tickProvider(const Duration(minutes: 1))).value ??
        DateTime.now();
    final gros = eventId == null
        ? ref.watch(bigEventsProvider).value ?? const <NearbyEvent>[]
        : const <NearbyEvent>[];
    final spots = eventId == null
        ? const <HotSpot>[]
        : ref.watch(eventHotSpotsProvider(eventId)).value ?? const [];

    final live = ref.watch(livePositionProvider);
    final objets3d = ref.watch(mapBuildings3dProvider);
    // Sur la carte, UNE position : celle que suit mon point ([track]) — le
    // centrage d'arrivée, le bouton et le libellé lisent la même.
    final me = live.track ?? live.fix;

    // La position arrive après coup : la carte s'est ouverte sur le centre de
    // secours, on l'amène sur le premier relevé reçu — une fois, et seulement
    // s'il n'y a pas d'événement à montrer, qui lui prime.
    if (me != null &&
        _map != null &&
        !_poseeSurMoi &&
        event?.lat == null &&
        spots.isEmpty) {
      _poseeSurMoi = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // À l'ouverture, la carte me suit — comme Google Maps.
        setState(() => _suivi = MapFollow.centre);
        unawaited(_appliquerGestes(MapFollow.centre));
        _suiviPretA = DateTime.now().add(const Duration(milliseconds: 700));
        _allerA(me.latitude, me.longitude);
      });
    }

    _centreInitial ??= event?.lat != null
        ? _pt(event!.lat!, event.lon!)
        : spots.isNotEmpty
        ? _pt(spots.first.lat, spots.first.lon)
        : me != null
        ? _pt(me.latitude, me.longitude)
        : null;

    // ⚠️ **Un seul objet, gardé** : la carte compare l'ancien et le nouveau
    // par identité, et un objet neuf à chaque reconstruction la ferait
    // revenir de force au point de départ sous le doigt.
    _vue ??= CameraViewportState(
      center: _centreInitial ?? _pt(50.63, 3.06),
      zoom: _initialZoom,
    );

    // La carte est un objet natif : on lui parle APRÈS l'image, jamais
    // pendant la construction de l'écran.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reglerStyle(p.isDark, objets3d: objets3d);
      // ⚠️ **À la file, jamais en parallèle** : deux dessins entrelacés
      // (effacer, effacer, créer, créer) laisseraient deux fois le même
      // point sur la carte.
      _file = _file
          .then((_) => _dessinerAmis(p, amis, minute))
          .then((_) => _dessinerVibes(p, vibes))
          .then(
            (_) => _dessiner(
              p: p,
              spots: spots,
              nearby: nearby.value ?? const [],
              gros: gros,
              event: event,
            ),
          )
          .catchError((Object _) {});
    });

    return LivePositionKeeper(
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Text(event?.title ?? 'Autour de moi'),
          actions: [
            IconButton(
              tooltip: 'Réglages de la carte',
              icon: const Icon(Icons.settings_rounded),
              onPressed: _ouvrirReglages,
            ),
          ],
        ),
        body: Stack(
          children: [
            // ⚠️ **Le mode d'affichage : la couche de texture** (`TLHC_HC`),
            // choisi par Jay le 2026-09-26 après comparaison sur son
            // téléphone avec l'écran virtuel (le défaut du paquet) et la
            // vue native. Les réglages de gestes natifs
            // (`MapGestureTuner.kt`) ont besoin que la carte soit accrochée
            // aux vues de l'écran : c'est le cas ici, pas en écran virtuel.
            MapWidget(
              key: const ValueKey('carte'),
              styleUri: MapboxStyles.STANDARD,
              viewport: _vue,
              androidHostingMode: AndroidPlatformViewHostingMode.TLHC_HC,
              onMapCreated: _onMapCreated,
              onStyleLoadedListener: _onStyleLoaded,
              onScrollListener: _onPan,
              // ⚠️ **Toutes les touches à la carte, TOUT DE SUITE.** Sans
              // ça, Flutter retient chaque doigt le temps de décider si un
              // de ses propres gestes le réclame, puis le transmet : les
              // gestes à deux doigts arrivent en retard et mal découpés.
              gestureRecognizers: {
                Factory<OneSequenceGestureRecognizer>(
                  EagerGestureRecognizer.new,
                ),
              },
            ),
            if (_roue case (final ami, final centre))
              Positioned.fill(
                child: FriendWheel(
                  centre: centre,
                  onClose: _fermerRoue,
                  actions: [
                    FriendWheelAction(
                      icone: Icons.person_rounded,
                      nom: 'Voir le profil',
                      onTap: () => _voirProfil(ami),
                    ),
                    FriendWheelAction(
                      icone: Icons.chat_bubble_rounded,
                      nom: 'Message',
                      onTap: () => _message(ami),
                    ),
                    // « Rejoindre » : ouvert ou non par le SERVEUR (bloqué au
                    // premier lancement public, décision de Jay).
                    if (ref.watch(walkingRouteEnabledProvider).value ?? false)
                      FriendWheelAction(
                        icone: Icons.directions_walk_rounded,
                        nom: 'Rejoindre à pied',
                        onTap: () => _rejoindre(ami),
                      ),
                    FriendWheelAction(
                      icone: Icons.share_location_rounded,
                      nom: 'Demander sa position',
                      onTap: () => _demanderPosition(ami),
                    ),
                  ],
                ),
              ),
            if (_itineraire case (final ami, final trajet))
              Positioned(
                left: 16,
                right: 72,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: Material(
                      color: p.surface,
                      borderRadius: BorderRadius.circular(NeoRadius.md),
                      elevation: 4,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                        child: Row(
                          children: [
                            Icon(
                              Icons.directions_walk_rounded,
                              color: p.action,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${trajet.libelle} · vers '
                                '${ami.displayName.split(' ').first}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Effacer le trajet',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: _effacerTrajet,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (nearby.hasError)
              Positioned(
                left: 16,
                right: 16,
                bottom: 64,
                child: Material(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(NeoRadius.md),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      nearby.error is StateError
                          ? 'Active la localisation pour voir les soirées.'
                          : messageServeur(nearby.error!),
                    ),
                  ),
                ),
              ),
            if (me != null)
              Positioned(
                right: 16,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: FloatingActionButton.small(
                      heroTag: 'recentrer',
                      onPressed: _recentrer,
                      backgroundColor: p.surface,
                      foregroundColor: _suivi.follows ? p.action : p.ink,
                      child: Icon(switch (_suivi) {
                        MapFollow.libre => Icons.location_searching_rounded,
                        MapFollow.centre => Icons.my_location_rounded,
                        MapFollow.boussole => Icons.explore_rounded,
                      }),
                    ),
                  ),
                ),
              ),
            // 🔴 **Le point est à trois kilomètres, et l'écran le DIT** —
            // 2026-09-22 au soir (`finesse : approximate`, `± 2000 m`). Sans ce
            // bandeau, la carte affichait un point faux avec l'aplomb d'un
            // point juste.
            if (live.brouillee)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: SafeArea(
                  bottom: false,
                  child: BandeauPositionApprochee(
                    onAutoriser: () => unawaited(_position.requestPrecise()),
                  ),
                ),
              ),
            // Ce que vaut le point, dit en clair — à droite : le logo et
            // l'attribution de Mapbox tiennent la gauche.
            if (me != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Container(
                    margin: const EdgeInsets.only(right: 8, bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: p.ground.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _libelleFix(live),
                      style: TextStyle(fontSize: 10, color: p.inkMuted),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Ce que vaut le point affiché, dit en clair sous la carte.
///
/// ## ⚠️ Ce libellé ne dit pas « GPS », et c'est une correction
///
/// Tous les relevés du flux arrivent étiquetés [FixSource.best] — parce que
/// c'est ce qu'on *demande*, pas ce qui répond : Android ne dit jamais quel
/// palier a réellement contribué (vérifié le 2026-09-22 dans
/// `LocationMapper.java`). Écrire « GPS » serait inventer une mesure.
///
/// Restent trois choses qu'on sait vraiment : **l'incertitude annoncée**,
/// **l'âge** (un point juste et un point figé ont la même apparence) et **le
/// nombre de relevés reçus** (« le flux tourne-t-il ? »).
///
/// 🔴 **« approché » passe DEVANT tout le reste** : `± 2000 m` nu se lit
/// « le GPS est mauvais ici », alors qu'il veut dire « Android a reçu l'ordre
/// de ne rien dire de mieux » — et la seconde cause se répare en un geste.
String _libelleFix(LivePositionState live) {
  // Le point AFFICHÉ est le relevé suivi ([LivePositionState.track]).
  final fix = live.track ?? live.fix!;
  final repli = live.brouillee
      ? 'approché · '
      : switch (fix.source) {
          FixSource.best => '',
          FixSource.network => 'réseau · ',
          FixSource.lastKnown => 'mémoire · ',
        };
  final depuis = live.trackAt ?? live.at;
  final age = depuis == null ? null : DateTime.now().difference(depuis);
  final vu = age == null ? '' : ' · ${age.inSeconds} s';
  return '$repli± ${fix.accuracy.round()} m$vu · ${live.received} relevés';
}
