import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../core/models/event.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/utils/erreur_serveur.dart';
import '../proximity/geo/coarse_location.dart';
import '../proximity/geo/live_position.dart';
import '../proximity/geo/precision_notice.dart';
import 'event_screen.dart';
import 'events_providers.dart';

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
    with WidgetsBindingObserver {
  MapboxMap? _map;

  /// Les calques, du dessous au dessus : l'incertitude, les points chauds,
  /// mon point, les soirées. Un calque par nature d'objet : mon point bouge
  /// toutes les quelques secondes, et le redessiner ne doit pas redessiner
  /// les soirées.
  PolygonAnnotationManager? _halo;
  CircleAnnotationManager? _chauds;
  CircleAnnotationManager? _moi;
  PointAnnotationManager? _soirees;
  Cancelable? _tapSoirees;

  /// Ce qui est dessiné dans chaque calque — on ne redessine qu'un calque
  /// dont le contenu a CHANGÉ (la reconstruction de l'écran n'en dit rien).
  Object? _dessineHalo, _dessineChauds, _dessineMoi, _dessineSoirees;

  /// Les dessins en attente, un à la fois.
  Future<void> _file = Future.value();

  /// Les soirées dessinées, par identifiant : ce qu'ouvre un tap.
  final _parId = <String, NearbyEvent>{};

  /// Le mode de lumière appliqué (`day` / `night`).
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

  /// Le flux tourne-t-il **pour nous** en ce moment ? Voir
  /// [didChangeAppLifecycleState].
  bool _abonne = false;

  /// La carte s'abonne à la position au lieu de prendre des photos : quinze
  /// photos floues ne font pas une photo nette (métro, 2026-09-22).
  late final LivePosition _position;

  @override
  void initState() {
    super.initState();
    _position = ref.read(livePositionProvider.notifier);
    _position.acquire();
    _abonne = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapSoirees?.cancel();
    // ⚠️ Relâché ici, et le notifier est retenu depuis [initState] : lire un
    // provider pendant `dispose` n'est pas garanti.
    // ⚠️ Et **seulement si on tient encore l'abonnement** : l'écran peut être
    // détruit alors qu'il l'a déjà relâché en passant en arrière-plan.
    if (_abonne) {
      _abonne = false;
      _position.release();
    }
    super.dispose();
  }

  /// **L'écoute continue s'arrête dès qu'on quitte l'app** — décision de Jay
  /// du 2026-09-22 au soir : en continu app ouverte sur la carte, une fois
  /// par minute sinon. Sans ça, une carte laissée ouverte derrière une autre
  /// app garderait le moteur de position allumé à pleine précision.
  ///
  /// ⚠️ **La finesse accordée se relit au retour** : si on la change dans les
  /// réglages système, rien ne nous prévient.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_abonne) {
        _abonne = true;
        _position.acquire();
      }
      unawaited(_position.relisPrecision());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // ⚠️ Relâché **une seule fois**, sinon le compteur d'abonnés passerait
      // sous zéro et couperait le flux sous les pieds d'un autre lecteur.
      if (_abonne) {
        _abonne = false;
        _position.release();
      }
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

  /// Recentrer **redemande** d'abord : c'est le geste de quelqu'un qui trouve
  /// que le point est faux, pas celui de quelqu'un qui veut revoir le même
  /// point.
  Future<void> _recentrer() async {
    final me = await _position.current();
    if (me == null || !mounted) return;
    _allerA(me.latitude, me.longitude);
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    // Pas de rotation : une carte de travers ne sert à personne ici et
    // s'attrape par accident à deux doigts. L'inclinaison reste (glisser à
    // deux doigts) : c'est elle qui montre les bâtiments en 3D.
    await map.gestures.updateSettings(GesturesSettings(rotateEnabled: false));
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
    _moi = await a.createCircleAnnotationManager();
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
  }

  /// Le style chargé : on règle sa lumière et ses étiquettes. Rappelé à
  /// chaque rechargement du style (le réglage vit DANS le style).
  void _onStyleLoaded(StyleLoadedEventData _) {
    _lumiere = null;
    if (mounted) setState(() {});
  }

  /// **Le style Standard, réglé pour un fond** : nuit si l'app est sombre
  /// (une carte claire la nuit éblouit — capture de 21:43, 2026-09-22), et
  /// sans commerces ni arrêts, qui chargeaient l'ancienne carte (pharmacies,
  /// numéros). Les rues et les quartiers restent : c'est ce qui situe.
  void _reglerStyle(bool dark) {
    final map = _map;
    final voulu = dark ? 'night' : 'day';
    if (map == null || _lumiere == voulu) return;
    _lumiere = voulu;
    unawaited(
      map.style
          .setStyleImportConfigProperties('basemap', {
            'lightPreset': voulu,
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
    required LivePositionState live,
    required List<HotSpot> spots,
    required List<NearbyEvent> nearby,
    required NeoEvent? event,
  }) async {
    final me = live.fix;

    // ⚠️ **Le halo d'incertitude, en MÈTRES.** L'appareil ne sait pas où il
    // est au mètre près (21 m au mieux, 100 m et plus en intérieur). Un point
    // net sans halo affirme une précision qu'on n'a pas.
    final halo = me == null
        ? null
        : (me.latitude, me.longitude, me.accuracy.round(), p.cool);
    if (_halo != null && halo != _dessineHalo) {
      _dessineHalo = halo;
      await _halo!.deleteAll();
      if (me != null) {
        await _halo!.create(
          PolygonAnnotationOptions(
            geometry: _cercle(me.latitude, me.longitude, me.accuracy),
            fillColor: p.cool.toARGB32(),
            fillOpacity: 0.12,
            fillOutlineColor: p.cool.withValues(alpha: 0.4).toARGB32(),
          ),
        );
      }
    }

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

    // Mon point : plein, cerclé de la couleur du fond, pour rester visible
    // sur une carte claire COMME sombre.
    final moi = me == null ? null : (me.latitude, me.longitude, p.cool);
    if (_moi != null && moi != _dessineMoi) {
      _dessineMoi = moi;
      await _moi!.deleteAll();
      if (me != null) {
        await _moi!.create(
          CircleAnnotationOptions(
            geometry: _pt(me.latitude, me.longitude),
            circleRadius: 6,
            circleColor: p.cool.toARGB32(),
            circleStrokeColor: p.ground.toARGB32(),
            circleStrokeWidth: 3,
          ),
        );
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
    final me = live.fix;

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
        if (mounted) _allerA(me.latitude, me.longitude);
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
      _reglerStyle(p.isDark);
      // ⚠️ **À la file, jamais en parallèle** : deux dessins entrelacés
      // (effacer, effacer, créer, créer) laisseraient deux fois le même
      // point sur la carte.
      _file = _file
          .then(
            (_) => _dessiner(
              p: p,
              live: live,
              spots: spots,
              nearby: nearby.value ?? const [],
              event: event,
            ),
          )
          .catchError((Object _) {});
    });

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(event?.title ?? 'Autour de moi'),
      ),
      body: Stack(
        children: [
          MapWidget(
            key: const ValueKey('carte'),
            styleUri: MapboxStyles.STANDARD,
            viewport: _vue,
            onMapCreated: _onMapCreated,
            onStyleLoadedListener: _onStyleLoaded,
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
                    foregroundColor: p.ink,
                    child: const Icon(Icons.my_location),
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
  final fix = live.fix!;
  final repli = live.brouillee
      ? 'approché · '
      : switch (fix.source) {
          FixSource.best => '',
          FixSource.network => 'réseau · ',
          FixSource.lastKnown => 'mémoire · ',
        };
  final age = live.ageAt(DateTime.now());
  final vu = age == null ? '' : ' · ${age.inSeconds} s';
  return '$repli± ${fix.accuracy.round()} m$vu · ${live.received} relevés';
}
