// Le mode d'affichage de la carte (`AndroidPlatformViewHostingMode`) est
// marqué expérimental par le paquet Mapbox ; on le choisit exprès, pour
// comparer la fluidité (réglage développeur, 2026-09-26).
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
import '../../core/palette.dart';
import '../../core/prefs.dart';
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

  /// Les deux images de mon point (avec et sans flèche) sont-elles posées
  /// dans le style, et pour quel thème ?
  bool? _imagesMoiSombre;

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
    _ticker.dispose();
    _couperBoussole();
    super.dispose();
  }

  /// **La boussole s'arrête dès qu'on quitte l'app** : personne ne regarde
  /// la flèche. (La position, elle, est relâchée par [LivePositionKeeper].)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ecouterBoussole();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _couperBoussole();
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
  Object? _envoyeHalo, _envoyePoint, _envoyeCamera;

  /// La vue de derrière est-elle posée (inclinaison + point en bas) ?
  bool _vueDeDerriere = false;

  /// L'inclinaison de la vue de derrière, en degrés (0 = vue du dessus).
  static const _inclinaisonDerriere = 55.0;

  /// Le zoom minimum de la vue de derrière : assez près pour les bâtiments.
  static const _zoomDerriere = 17.0;

  /// **Les gestes, tels que Jay les a définis** (2026-09-26) :
  ///
  /// | Doigts | Geste | Effet |
  /// |---|---|---|
  /// | 1 | glisser | déplacer la carte |
  /// | 2 | se rapprocher / s'écarter | zoomer (et se déplacer avec) |
  /// | 2 | tourner en sens opposés | tourner la carte |
  /// | 2 | glisser ensemble vers le haut / le bas | incliner la vue |
  ///
  /// ⚠️ **Zoomer ne tourne plus la carte.** Par défaut, Mapbox laisse un
  /// pincement tourner la carte en même temps qu'il zoome
  /// (`simultaneousRotateAndPinchToZoomEnabled`) : un zoom un peu de
  /// travers la faisait pivoter. Chaque geste fait désormais UNE chose.
  ///
  /// Deux exceptions, qui suivent le mode du bouton :
  /// - **quand la carte me suit**, pincer zoome sans déplacer : la carte me
  ///   ramènerait au centre à l'image suivante, et le zoom sauterait ;
  /// - **en mode boussole**, pas de rotation à deux doigts : c'est ma
  ///   direction qui oriente la carte, un geste contraire serait défait à
  ///   l'image suivante. La boussole de Mapbox (touchée, elle remet le nord)
  ///   est visible hors de ce mode.
  ///
  /// 🔴 **Deux doigts ne déplacent JAMAIS la carte** (2026-09-26, Jay :
  /// *« parfois je fais le bon geste mais au lieu de changer l'angle de vue,
  /// ça déplace la carte »*). Lu dans le code de Mapbox (gestures 0.10.0 et
  /// maps-gestures 11.31.1) : le détecteur de déplacement suit le centre de
  /// TOUS les doigts et part au premier millimètre, alors que celui de
  /// l'inclinaison attend 16 dp de course (`mapbox_defaultShovePixelThreshold`)
  /// avec des doigts alignés à 45° près, et ne coupe le déplacement qu'une
  /// fois parti. Ces premiers millimètres déplaçaient la carte — et tout le
  /// geste, si les doigts étaient un peu de travers. Le déplacement est donc
  /// coupé dès qu'un deuxième doigt se pose ([_doigts]) et rendu quand il
  /// n'en reste qu'un ; le pincement non plus ne déplace plus
  /// (`pinchPanEnabled: false`) — « zoom », dans la définition de Jay.
  Future<void> _appliquerGestes(MapFollow mode) async {
    final map = _map;
    if (map == null) return;
    final boussole = mode == MapFollow.boussole;
    await map.gestures.updateSettings(
      GesturesSettings(
        scrollEnabled: _doigts < 2,
        scrollMode: ScrollMode.HORIZONTAL_AND_VERTICAL,
        pinchToZoomEnabled: true,
        pinchPanEnabled: false,
        simultaneousRotateAndPinchToZoomEnabled: false,
        increaseRotateThresholdWhenPinchingToZoom: true,
        increasePinchToZoomThresholdWhenRotating: true,
        rotateEnabled: !boussole,
        pitchEnabled: true,
      ),
    );
    await map.compass.updateSettings(CompassSettings(enabled: !boussole));
  }

  /// Combien de doigts touchent la carte en ce moment.
  int _doigts = 0;

  /// Un doigt se pose ou se lève : au passage de 1 à 2 doigts (et retour),
  /// le déplacement est coupé ou rendu. Écouté SANS prendre part aux gestes
  /// (un `Listener`) : la carte reçoit toujours toutes les touches.
  void _compteDoigts(int delta) {
    final avant = _doigts;
    _doigts = math.max(0, _doigts + delta);
    if ((avant < 2) != (_doigts < 2)) unawaited(_appliquerGestes(_suivi));
  }

  /// La carte déplacée à la main : elle cesse de me suivre.
  void _onPan(MapContentGestureContext _) {
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
    _haloPoly = null;
    _envoyeHalo = null;
    _envoyePoint = null;
    _envoyeCamera = null;
    _dessineChauds = null;
    _dessineSoirees = null;
    _imagesMoiSombre = null;
    _lumiere = null;
    // Tourner à deux doigts : permis hors mode boussole ([_appliquerGestes]).
    // L'inclinaison (glisser à deux doigts vers le haut) montre la 3D.
    await _appliquerGestes(_suivi);
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
    _lumiere = null;
    // Les images vivent DANS le style : un style rechargé les a perdues.
    _imagesMoiSombre = null;
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
    final cleSoirees = (
      Object.hashAll([
        for (final e in nearby)
          (e.id, e.title, e.presentCount, e.lat, e.lon, e.kind),
      ]),
      lieu,
      p.isDark,
    );
    if (_soirees != null && cleSoirees != _dessineSoirees) {
      _dessineSoirees = cleSoirees;
      await _soirees!.deleteAll();
      _parId
        ..clear()
        ..addEntries(nearby.map((e) => MapEntry(e.id, e)));
      final fete = await _repere(p, Icons.celebration_rounded);
      final boutique = nearby.any((e) => e.kind != EventKind.open)
          ? await _repere(p, Icons.storefront_rounded)
          : fete;
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
      ]);
    }
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
      if (_imagesMoiSombre != p.isDark) {
        await _poserImagesMoi(p);
        _imagesMoiSombre = p.isDark;
      }
      final ou = _pt(frame.lat, frame.lon);
      final image = frame.heading == null ? _imgPoint : _imgFleche;
      final cap = frame.heading ?? 0;
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

  static const _imgPoint = 'neovibe-moi-point';
  static const _imgFleche = 'neovibe-moi-fleche';

  /// Les deux images de mon point, posées dans le style : sans flèche (pas
  /// de boussole) et avec — un cône qui s'ouvre vers où je regarde, comme
  /// sur Google Maps. Dessinées à la densité de l'écran.
  Future<void> _poserImagesMoi(NeoPalette p) async {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    for (final (id, fleche) in [(_imgPoint, false), (_imgFleche, true)]) {
      final png = await _imageMoi(p, dpr, fleche: fleche);
      final cote = (_coteMoi * dpr).round();
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
  }

  /// Côté de l'image de mon point, en points : la place du cône.
  static const _coteMoi = 72.0;

  static Future<Uint8List> _imageMoi(
    NeoPalette p,
    double dpr, {
    required bool fleche,
  }) async {
    final cote = _coteMoi * dpr;
    final c = Offset(cote / 2, cote / 2);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (fleche) {
      // Le cône : 70° d'ouverture, vers le HAUT de l'image (le nord, avant
      // rotation), qui s'efface en s'éloignant du point.
      final rayon = cote / 2;
      final cone = Path()
        ..moveTo(c.dx, c.dy)
        ..arcTo(
          Rect.fromCircle(center: c, radius: rayon),
          -math.pi / 2 - 35 * math.pi / 180,
          70 * math.pi / 180,
          false,
        )
        ..close();
      canvas.drawPath(
        cone,
        Paint()
          ..shader = ui.Gradient.radial(c, rayon, [
            p.cool.withValues(alpha: 0.55),
            p.cool.withValues(alpha: 0),
          ]),
      );
    }
    // Le point : plein, cerclé de la couleur du fond, pour rester visible
    // sur une carte claire COMME sombre.
    canvas.drawCircle(
      c,
      9 * dpr,
      Paint()..color = Colors.black.withValues(alpha: 0.25),
    );
    canvas.drawCircle(c, 8 * dpr, Paint()..color = p.ground);
    canvas.drawCircle(c, 5.5 * dpr, Paint()..color = p.cool);
    final image = await recorder.endRecording().toImage(
      cote.round(),
      cote.round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

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
  Future<Uint8List> _repere(NeoPalette p, IconData icone) async {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final taille = 34 * dpr;
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
          fontSize: 18 * dpr,
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
    final nearby = eventId == null
        ? ref.watch(nearbyEventsProvider)
        : const AsyncValue<List<NearbyEvent>>.data([]);
    final spots = eventId == null
        ? const <HotSpot>[]
        : ref.watch(eventHotSpotsProvider(eventId)).value ?? const [];

    final live = ref.watch(livePositionProvider);
    final affichage = ref.watch(devMapHostingProvider).value;
    final objets3d = ref.watch(devMap3dProvider);
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
          .then(
            (_) => _dessiner(
              p: p,
              spots: spots,
              nearby: nearby.value ?? const [],
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
        ),
        body: Stack(
          children: [
            // ⚠️ **Le mode d'affichage se COMPARE sur le téléphone**
            // (Réglages › Développeur › Interrupteurs, 2026-09-26) : Jay
            // trouvait la carte saccadée, et le passage à la couche de
            // texture (v0.9.275) n'était qu'une hypothèse. Changer de mode
            // recrée la carte (sa clé).
            if (affichage == null)
              const SizedBox.shrink()
            else
              Listener(
                onPointerDown: (_) => _compteDoigts(1),
                onPointerUp: (_) => _compteDoigts(-1),
                onPointerCancel: (_) => _compteDoigts(-1),
                child: MapWidget(
                  key: ValueKey(affichage),
                  styleUri: MapboxStyles.STANDARD,
                  viewport: _vue,
                  textureView: affichage != MapHosting.natif,
                  androidHostingMode: switch (affichage) {
                    MapHosting.virtuel => AndroidPlatformViewHostingMode.VD,
                    MapHosting.texture =>
                      AndroidPlatformViewHostingMode.TLHC_HC,
                    MapHosting.natif => AndroidPlatformViewHostingMode.HC,
                  },
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
