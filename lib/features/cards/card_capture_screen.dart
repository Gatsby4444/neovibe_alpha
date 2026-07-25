import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import '../../core/models/card.dart';
import '../../core/prefs.dart';
import 'card_send_screen.dart';
import 'face_editor_screen.dart';
import 'gallery_import_screen.dart';
import 'native_camera.dart';

/// Flux de création d'une Card.
/// Le TYPE se choisit AVANT la première photo, dans un sélecteur horizontal
/// au-dessus du déclencheur (consigne Jay) — le Oneshot est donc un mode de
/// prise (les deux faces en un déclenché), pas un choix a posteriori.
/// Chaque face peut aussi être un « tableau » (fond noir à dessiner) ou, pour
/// les cards classiques et Mono, une image importée de la galerie.
/// L'aperçu est un cadre 9:16 recadré « cover » et la photo est recadrée au
/// même cadre : ce qu'on voit est exactement ce qui est capturé (fix de la
/// distorsion remontée par Jay le 2026-07-12).
class CardCaptureScreen extends ConsumerStatefulWidget {
  const CardCaptureScreen({super.key, this.bereal = false});

  /// Mode BeReal : fenêtre de capture contrainte de 5 minutes après la
  /// notification (le déclenchement manuel a été retiré du menu).
  final bool bereal;

  @override
  ConsumerState<CardCaptureScreen> createState() => _CardCaptureScreenState();
}

class _CardCaptureScreenState extends ConsumerState<CardCaptureScreen> {
  /// Couche caméra NATIVE (CameraX) — remplace le plugin `camera`
  /// (chantier validé par Jay 2026-07-13).
  final _camera = NativeCameraController();

  /// Diagnostic du double flux (déclarations de l'appareil + dernière erreur
  /// réelle de bind) — affiché dans le HUD développeur.
  CameraCapabilities? _caps;
  String? _dualError;

  /// Double flux Oneshot : la vignette PiP montre la frontale par défaut ;
  /// taper la vignette échange les vues (consigne Jay v0.5.0).
  var _pipSwapped = false;

  /// Info Oneshot (vue simple de secours) déjà montrée.
  var _oneshotNoticeShown = false;

  /// Le moteur natif essaie plusieurs configurations de double flux : on
  /// affiche un cadre d'attente au lieu d'un écran noir.
  var _dualOpening = false;

  /// Type que la CAMÉRA sert actuellement (≠ [_type] tant que le sélecteur
  /// n'est pas posé) + minuterie de stabilisation du sélecteur.
  late CardType _cameraType = _type;
  Timer? _typeSettle;

  /// **Type FIGÉ de la card, verrouillé au déclenchement.**
  ///
  /// Le type d'une card est décidé AU MOMENT DE LA PRISE : une fois le
  /// déclencheur pressé, il ne doit plus jamais changer. Sans ce verrou, Jay a
  /// pu changer de mode PENDANT le traitement d'une capture Oneshot et
  /// obtenir une **Mono à deux faces** — un objet qui ne devrait pas exister
  /// (bug critique, 2026-07-14).
  ///
  /// Tout ce qui définit la card (branches de capture, récap, envoi) lit
  /// [_cardType], jamais [_type] (qui, lui, ne sert qu'à l'affichage du
  /// sélecteur).
  CardType? _lockedType;

  CardType get _cardType => _lockedType ?? _type;

  /// Le type est-il déjà figé (prise en cours ou faites) ?
  bool get _typeLocked => _lockedType != null || _busy || _recording;

  /// Fige le type. Appelé au tout premier acte de création (déclencheur,
  /// vidéo, tableau, import).
  void _lockType() {
    if (_lockedType != null) return;
    _lockedType = _type;
    _typeSettle
        ?.cancel(); // aucun changement de mode en vol ne doit s'appliquer
  }

  File? _front; // recto = caméra arrière (ce que je vois)
  File? _back; // verso = caméra avant (ma réaction) — null en Mono
  var _frontImported = false; // face issue de la galerie
  var _backImported = false;
  var _frontIsVideo = false; // face vidéo (mode vidéo, consigne Jay)
  var _backIsVideo = false;
  var _step = 0; // 0 = recto, 1 = verso, 2 = récap
  var _error = '';
  var _busy = false; // capture ou bascule caméra en cours
  var _switching = false;
  var _micGranted = false; // son des vidéos (permission micro)
  late CardType _type = widget.bereal ? CardType.bereal : CardType.standard;

  /// Enregistrement vidéo en cours : appui maintenu sur le déclencheur ;
  /// glisser hors du cercle = verrouillage (doigt libéré), re-tap = stop.
  /// [_recording] = état UI (affiché dès l'intention, avant que la caméra
  /// soit prête) ; [_videoStarted] = la caméra enregistre RÉELLEMENT ;
  /// [_pressHeld] = le doigt est encore posé. Cette séparation corrige le
  /// bug v0.6.0 : relâcher pendant le démarrage caméra (~0,5 s) laissait la
  /// vidéo tourner orpheline (retour Jay).
  var _recording = false;
  var _videoStarted = false;
  var _pressHeld = false;
  var _recordLocked = false;
  var _recordSeconds = 0;
  Timer? _recordTimer;

  /// Sélecteur de type : swipe localisé + snap (consigne Jay : épuré, texte
  /// seul, mise en avant animée du mode sélectionné).
  late final PageController _typeController = PageController(
    viewportFraction: 0.34,
    initialPage: CardType.selectable.indexOf(_type).clamp(0, 4),
  );

  /// Fenêtre BeReal : 30 secondes pour boucler les deux prises « pour un
  /// vrai BeReal » (consigne Jay 2026-07-12 — remplace les 5 minutes).
  static const _berealWindow = Duration(seconds: 30);

  /// Durée max d'une vidéo selon le mode : 61 s en général (limite dev, à
  /// repenser avant la prod — rappel demandé par Jay), 10 s pour Hot,
  /// 15 s pour BeReal (2 faces dans la fenêtre de 30 s).
  int get _maxVideoSeconds => switch (_type) {
    CardType.hot => 10,
    CardType.bereal => 15,
    _ => 61,
  };
  Timer? _berealTimer;
  int _berealRemaining = _berealWindow.inSeconds;

  @override
  void initState() {
    super.initState();
    _camera.addListener(_onCameraChanged);
    _init();
    if (widget.bereal) {
      _berealTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _berealRemaining--);
        if (_berealRemaining <= 0) {
          _berealTimer?.cancel();
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Fenêtre BeReal écoulée — l\'instant est passé.'),
            ),
          );
        }
      });
    }
  }

  void _onCameraChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _error = 'Permission caméra refusée');
      return;
    }
    // Micro pour le son des vidéos ; refusé = vidéos muettes, pas bloquant.
    _micGranted = (await Permission.microphone.request()).isGranted;
    _caps = await NativeCameraController.capabilities();
    await _openWithRetry();
  }

  /// Ouvre la caméra arrière avec UN réessai : une init CameraX peut échouer
  /// temporairement (« Available cameras: 0 » — typiquement quand la pile
  /// caméra n'est pas encore libérée). Le message d'erreur Android lui-même
  /// conseille de réessayer.
  Future<void> _openWithRetry() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _camera.open(back: true, audio: _micGranted);
        if (mounted) setState(() => _error = '');
        return;
      } catch (e) {
        if (attempt == 0) {
          await _camera.close();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        if (mounted) setState(() => _error = 'Caméra indisponible : $e');
      }
    }
  }

  /// Miroir de la caméra frontale dans l'aperçu — réglage utilisateur, ON par
  /// défaut (Réglages → Caméra). Ne concerne QUE l'aperçu : la photo
  /// enregistrée n'est jamais mirrorée, comme sur la plupart des appareils
  /// photo — sinon un texte capturé sortirait illisible sur la card.
  bool get _selfieMirror => ref.watch(selfieMirrorProvider);

  bool get _previewReady =>
      (_camera.glDualActive && _camera.previews.containsKey('glBack')) ||
      (_camera.textureId != null && _camera.previews.containsKey('main'));

  /// Passe (ou reste) sur la caméra [back]. La couche native rebinde le
  /// même flux : pas de destruction/re-création de contrôleur.
  Future<void> _ensureLens({required bool back}) async {
    // En double flux (logiciel OU GPU), CameraX n'est pas bindé : une bascule
    // taperait dans le vide.
    if (_camera.dualActive || _camera.glDualActive) return;
    if (_camera.lensBack == back) return;
    setState(() => _switching = true);
    try {
      await _camera.switchLens();
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// Changement de type dans le sélecteur.
  ///
  /// Le PageView émet un changement pour CHAQUE type traversé pendant le
  /// swipe : sans temporisation, un simple passage sur Oneshot lançait une
  /// ouverture de double flux (~3 s) — parfois plusieurs en parallèle, et
  /// l'écran d'attente restait affiché sur le mode d'arrivée (retour Jay,
  /// v0.8.4). On ne reconfigure donc la caméra qu'une fois le sélecteur POSÉ.
  void _onTypeChanged(CardType type) {
    // Verrou : après le déclenchement, le type de la card est figé. Le
    // sélecteur est déjà bloqué à l'affichage — ceci est la seconde barrière
    // (un événement de page peut être en vol au moment du déclenchement).
    if (_typeLocked) return;
    setState(() => _type = type);
    _typeSettle?.cancel();
    _typeSettle = Timer(const Duration(milliseconds: 350), _applyTypeToCamera);
  }

  /// Applique à la caméra le type réellement choisi (une fois posé).
  Future<void> _applyTypeToCamera() async {
    final type = _type;
    if (type == _cameraType) return;
    // Une ouverture de double flux est en cours : elle se réaligne toute
    // seule à la fin (voir la fin de _tryOpenDual).
    if (_dualOpening) return;
    final previous = _cameraType;
    _cameraType = type;

    if (type == CardType.oneshot) {
      // Le Oneshot ouvre MAINTENANT le double flux par DÉFAUT (décision Jay,
      // 2026-07-24) : c'est le seul moyen de capturer les deux faces au MÊME
      // instant. La bascule séquentielle laissait un écart de plusieurs
      // centaines de ms (le temps de fermer une caméra et d'ouvrir l'autre) où
      // l'utilisateur pouvait tricher — ce n'était plus un Oneshot.
      // Repli automatique en séquentiel si l'appareil refuse (géré dans
      // _tryOpenDual). Deux court-circuits : le toggle dev « vue simple forcée »
      // et un échec déjà survenu dans la session (on ne re-sonde pas — un échec
      // peut laisser le service caméra d'Android hors service).
      final forceSimple = ref.read(devDualOneshotProvider);
      if (!forceSimple && !NativeCameraController.dualFailedThisSession) {
        await _tryOpenDual();
      } else {
        _showOneshotFallbackNotice();
      }
    } else if (previous == CardType.oneshot && _camera.glDualActive) {
      // Sortie du Oneshot : on ferme d'abord le double flux GPU (sinon glBack/
      // glFront gardent les caméras et le flux simple ne peut pas s'ouvrir),
      // puis retour au flux simple caméra arrière.
      await _camera.closeGlDual();
      await _openWithRetry();
    } else if (type != CardType.mono &&
        (previous == CardType.mono || previous == CardType.oneshot) &&
        !_camera.lensBack) {
      // En quittant Mono ou Oneshot, le recto redevient caméra arrière.
      await _ensureLens(back: true);
    }
  }

  /// Bouton « Double live » manuel. Le Oneshot ouvre déjà le double flux par
  /// défaut ; ce bouton ne sert donc plus que d'échappatoire lorsque
  /// l'utilisateur a FORCÉ la vue simple via le toggle dev (`devDualOneshot` =
  /// « vue simple forcée ») et veut malgré tout tenter le double une fois.
  /// Un échec le retire jusqu'au prochain lancement (sonder le matériel n'est
  /// pas gratuit — un échec peut laisser le service caméra hors service).
  bool get _canOfferDual =>
      _type == CardType.oneshot &&
      _step == 0 &&
      !_camera.glDualActive &&
      !_dualOpening &&
      !NativeCameraController.dualFailedThisSession &&
      ref.read(devDualOneshotProvider);

  /// Ouvre le double live (demande explicite de l'utilisateur). En cas
  /// d'échec : retour à la vue simple, message clair, et on ne le repropose
  /// plus de la session.
  Future<void> _tryOpenDual() async {
    await NativeCameraController.log('Oneshot : double live GPU demandé');
    if (mounted) setState(() => _dualOpening = true);
    try {
      // Moteur GPU (OpenGL) depuis l'étape 5a : double aperçu fluide (2×30 i/s)
      // + photo double instantanée, là où le moteur logiciel plafonnait à
      // ~20-27 i/s avec freezes.
      await _camera.openGlDual();
      _dualError = null;
      _pipSwapped = false;
      await NativeCameraController.log(
        'Oneshot : double live GPU actif — textures '
        'back=${_camera.glBackTextureId} front=${_camera.glFrontTextureId}',
      );
      if (mounted) setState(() {});
    } catch (e) {
      _dualError = e is DualUnsupportedException ? e.reason : e.toString();
      await NativeCameraController.log('Oneshot : double live GPU refusé — $e');
      await _camera.close();
      await _openWithRetry();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Double live impossible sur cet appareil. Le Oneshot capture '
              'quand même les deux faces, l\'une après l\'autre.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _dualOpening = false);
      // Le sélecteur a pu bouger pendant les quelques secondes d'ouverture :
      // on réaligne la caméra sur le type réellement affiché.
      if (_type != CardType.oneshot) {
        _cameraType = _type;
        if (_camera.glDualActive) {
          await _camera.closeGlDual();
          await _openWithRetry();
        }
      }
    }
  }

  void _showOneshotFallbackNotice() {
    if (_oneshotNoticeShown || !mounted) return;
    _oneshotNoticeShown = true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Oneshot : le déclenché prend les deux faces. Bascule l\'aperçu avec '
          'le bouton.',
        ),
      ),
    );
  }

  /// Bascule avant/arrière : Mono (double-tap OU bouton, y compris PENDANT
  /// une vidéo — l'enregistrement persistant natif survit à la bascule,
  /// comme Snapchat) et Oneshot en vue simple de secours.
  Future<void> _toggleLens() async {
    // Pendant l'ouverture du double live, CameraX est libéré : une bascule
    // taperait dans le vide (NullPointerException natif, journal v0.9.1).
    if (_busy || _switching || _camera.glDualActive || _dualOpening) return;
    // Pendant une vidéo : bascule autorisée UNIQUEMENT en Mono (consigne).
    if (_recording && _type != CardType.mono) return;
    if (_recording && !_videoStarted) return; // démarrage caméra en cours
    // La réouverture de la caméra prend quelques centaines de ms : haptique
    // immédiate + voile flouté pendant la bascule, pour que l'attente se
    // lise comme une transition et non comme un gel (retour Jay v0.7.0).
    HapticFeedback.selectionClick();
    setState(() => _switching = true);
    try {
      await _camera.switchLens();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Bascule impossible : $e')));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// Recadre un cliché au cadre 9:16 centré (celui montré à l'aperçu) et le
  /// normalise au format unifié des cards (900×1600). WYSIWYG : c'est le fix
  /// de la distorsion (l'aperçu n'est plus étiré, la photo correspond).
  ///
  /// Fait **en natif** (rapide : un décodage sous-échantillonné + un encodage
  /// JPEG). Le chemin Dart ci-dessous n'est plus qu'un secours : il encode du
  /// PNG en 900×1600, ce qui coûtait des secondes par face.
  static Future<File> _cropTo916(File source) async {
    try {
      return await NativeCameraController.normalize(source);
    } catch (e) {
      await NativeCameraController.log(
        'normalisation native indisponible ($e) → repli Dart',
      );
      return _cropTo916Dart(source);
    }
  }

  static Future<File> _cropTo916Dart(File source) async {
    final bytes = await source.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    const targetRatio = 9 / 16;
    final w = image.width.toDouble(), h = image.height.toDouble();
    var cropW = w, cropH = h;
    if (w / h > targetRatio) {
      cropW = h * targetRatio;
    } else {
      cropH = w / targetRatio;
    }
    final src = ui.Rect.fromLTWH(
      (w - cropW) / 2,
      (h - cropH) / 2,
      cropW,
      cropH,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      src,
      const ui.Rect.fromLTWH(0, 0, 900, 1600),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    image.dispose();
    final out = await recorder.endRecording().toImage(900, 1600);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    final file = File(
      '${Directory.systemTemp.path}/card_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(data!.buffer.asUint8List());
    return file;
  }

  /// Démarre l'enregistrement vidéo (appui maintenu sur le déclencheur).
  /// Oneshot en double flux : les DEUX caméras filment en même temps
  /// (chantier caméra native — priorité 1 de Jay) ; en vue simple de
  /// secours, le Oneshot reste photo uniquement.
  Future<void> _startVideo() async {
    if (!_previewReady || _busy || _switching || _recording) return;
    _lockType(); // le type est figé dès le début de l'enregistrement
    // Oneshot : les DEUX caméras filment en même temps (moteur GPU, étape 5b).
    // Sans double flux (repli séquentiel), le Oneshot reste photo : filmer une
    // face puis l'autre laisserait un écart où l'on peut tricher — ce ne serait
    // plus un Oneshot.
    final dualVideo = _cardType == CardType.oneshot && _camera.glDualActive;
    if (_cardType == CardType.oneshot && !dualVideo) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Oneshot : photo uniquement sur cet appareil (pas de double '
            'flux vidéo).',
          ),
        ),
      );
      return;
    }
    // Retour haptique et UI rouge IMMÉDIATS (avant le démarrage caméra,
    // qui prend ~0,5 s) : l'utilisateur sait que la vidéo est engagée.
    HapticFeedback.heavyImpact();
    setState(() {
      _recording = true;
      _videoStarted = false;
      _recordLocked = false;
      _recordSeconds = 0;
    });
    try {
      if (dualVideo) {
        await _camera.startGlDualVideo(audio: _micGranted);
      } else {
        await _camera.startVideo(audio: _micGranted);
      }
    } on DualUnsupportedException catch (e) {
      // Le matériel accepte deux aperçus mais pas deux encodeurs : photo seule.
      // Rien à rouvrir — un échec d'encodeur ne touche pas l'aperçu GPU, qui
      // continue de tourner (contrairement au moteur logiciel, qui débranchait
      // les ImageCapture et imposait une réouverture).
      _dualError = e.reason;
      await NativeCameraController.log(
        'Oneshot : double vidéo GPU refusée — ${e.reason}',
      );
      if (mounted) {
        setState(() => _recording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Oneshot vidéo non supporté — photo uniquement.'),
          ),
        );
      }
      return;
    } catch (e) {
      if (mounted) {
        setState(() => _recording = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Vidéo impossible : $e')));
      }
      return;
    }
    if (!mounted) return;
    _videoStarted = true;
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordSeconds++);
      if (_recordSeconds >= _maxVideoSeconds) _stopVideo();
    });
    // Doigt relâché PENDANT le démarrage caméra (sans verrou) : on coupe
    // tout de suite — c'était le bug « la vidéo continue après relâcher ».
    if (!_pressHeld && !_recordLocked) {
      await _stopVideo();
    }
  }

  Future<void> _stopVideo() async {
    // Tant que la caméra n'enregistre pas réellement, on ne peut pas
    // l'arrêter — le relâchement précoce est géré en fin de _startVideo.
    if (!_recording || !_videoStarted) return;
    final dualVideo = _cardType == CardType.oneshot && _camera.glDualActive;
    _recordTimer?.cancel();
    HapticFeedback.selectionClick();
    setState(() {
      _recording = false;
      _videoStarted = false;
      _recordLocked = false;
      _busy = true;
    });
    try {
      if (dualVideo) {
        // Arrière = recto, avant = verso (ordre inchangé, consigne Jay).
        final shots = await _camera.stopGlDualVideo();
        _front = shots.back;
        _frontIsVideo = true;
        _frontImported = false;
        _back = shots.front;
        _backIsVideo = true;
        _backImported = false;
        _berealTimer?.cancel();
        await NativeCameraController.log(
          'Oneshot : double vidéo GPU écrite — '
          'recto ${await shots.back.length() ~/ 1024} Ko, '
          'verso ${await shots.front.length() ~/ 1024} Ko',
        );
        // Rien à rouvrir : arrêter les encodeurs ne fait que retirer leur
        // surface EGL, les deux caméras continuent de rendre l'aperçu.
        if (mounted) setState(() => _step = 2);
      } else {
        final shot = await _camera.stopVideo();
        await _applyFace(shot, imported: false, isVideo: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Vidéo impossible : $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Tap sur le déclencheur : photo — ou arrêt d'une vidéo verrouillée
  /// (un simple tap suffit, consigne Jay). Filet de sécurité : un
  /// enregistrement sans doigt posé ni verrou (état orphelin si un geste a
  /// été perdu) s'arrête aussi d'un simple tap.
  void _onShutterTap() {
    if (_recording) {
      if (_recordLocked || !_pressHeld) _stopVideo();
      return;
    }
    _capture();
  }

  void _onShutterLongPressStart(LongPressStartDetails details) {
    _pressHeld = true;
    _startVideo();
  }

  /// Glisser hors du cercle de commande pendant l'appui = verrouillage de
  /// l'enregistrement (le doigt est libéré, un tap pour arrêter).
  void _onShutterLongPressMove(LongPressMoveUpdateDetails details) {
    if (_recording &&
        !_recordLocked &&
        details.offsetFromOrigin.distance > 70) {
      HapticFeedback.mediumImpact();
      setState(() => _recordLocked = true);
    }
  }

  /// Relâcher = stop (sauf verrouillage). Si la caméra démarre encore,
  /// _startVideo s'en charge dès qu'elle est prête (via _pressHeld).
  void _onShutterLongPressEnd(LongPressEndDetails details) {
    _pressHeld = false;
    if (_recording && !_recordLocked) _stopVideo();
  }

  /// Oneshot en vue simple : les deux faces l'une après l'autre (arrière puis
  /// avant). C'est le mode fiable, et celui de BeReal.
  Future<void> _captureBothSequentially() async {
    // Repli du Oneshot sur un appareil incapable du double flux : les deux
    // faces l'une après l'autre. L'écart entre les deux clichés est LE défaut
    // de ce mode (c'est la fenêtre où l'on peut changer de tête), donc plus
    // aucun délai en dur ici : `switchLens` ne répond que lorsque la caméra
    // est réellement ouverte (`CameraState`), et `takePicture` fait sa propre
    // convergence d'exposition. On mesure l'écart pour pouvoir en juger.
    final started = DateTime.now();
    await _ensureLens(back: true);
    final backShot = await _camera.takePicture();
    final betweenStart = DateTime.now();
    await _ensureLens(back: false);
    final frontShot = await _camera.takePicture();
    final gap = DateTime.now().difference(betweenStart).inMilliseconds;
    await NativeCameraController.log(
      'Oneshot séquentiel : écart entre les deux faces $gap ms '
      '(total ${DateTime.now().difference(started).inMilliseconds} ms)',
    );
    _front = await _cropTo916(backShot);
    _back = await _cropTo916(frontShot);
  }

  /// Dernier rempart avant le récap : **le contenu doit correspondre au type**.
  /// Une Mono a UNE face, un Oneshot/BeReal/standard en a DEUX. Si ce n'est pas
  /// le cas, c'est un bug — on le consigne et on refuse de continuer plutôt que
  /// de fabriquer une card impossible (une Mono à deux faces a été créée le
  /// 2026-07-14).
  bool _facesMatchType() {
    final type = _cardType;
    final twoFaces = _back != null;
    final ok = type == CardType.mono ? !twoFaces : twoFaces;
    if (!ok) {
      NativeCameraController.log(
        'INCOHÉRENCE : type=${type.name} mais faces=${twoFaces ? 2 : 1} '
        '— card refusée',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Prise incohérente avec le mode choisi — recommence la prise.',
            ),
          ),
        );
      }
    }
    return ok;
  }

  Future<void> _capture() async {
    if (!_previewReady || _busy || _recording) return;
    // Le type est FIGÉ ici, avant le moindre await : tout ce qui suit décrit
    // une card de ce type-là, quoi que fasse le sélecteur ensuite.
    _lockType();
    setState(() => _busy = true);
    try {
      if (_cardType == CardType.mono) {
        // Mono : une seule face, celle de la caméra active — comme un snap.
        final shot = await _camera.takePicture();
        _front = await _cropTo916(shot);
        _back = null;
        if (!_facesMatchType()) return;
        setState(() => _step = 2);
        return;
      }
      if (_cardType == CardType.oneshot && _step == 0) {
        var shot = false;
        if (_camera.glDualActive) {
          try {
            // Double flux GPU : les deux faces d'un coup (dernière image rendue
            // de chaque caméra → instantané, vraiment simultané). Arrière =
            // recto, avant = verso. Recadrage 9:16 / format card comme d'hab.
            final shots = await _camera.captureGlDual();
            _front = await _cropTo916(shots.back);
            _back = await _cropTo916(shots.front);
            shot = true;
          } catch (e) {
            // Échec de la capture GPU : on ferme le double flux GPU et on
            // reprend en vue simple séquentielle, qui marche toujours. La card
            // est capturée quand même : Jay ne perd pas sa prise.
            await NativeCameraController.log(
              'Oneshot : capture GPU échouée ($e) → repli séquentiel',
            );
            await _camera.closeGlDual();
            await _openWithRetry();
          }
        }
        if (!shot) {
          // Vue simple : arrière puis avant (c'est aussi ce que fait BeReal).
          await _captureBothSequentially();
        }
        if (!_facesMatchType()) return;
        _berealTimer?.cancel();
        setState(() => _step = 2);
        return;
      }
      final shot = await _camera.takePicture();
      final cropped = await _cropTo916(shot);
      if (_step == 0) {
        _front = cropped;
        setState(() => _step = 1);
        await _ensureLens(back: false);
      } else {
        _back = cropped;
        if (!_facesMatchType()) return;
        _berealTimer?.cancel();
        setState(() => _step = 2);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Capture impossible : $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Applique un fichier à la face courante (tableau, import galerie ou
  /// vidéo) et avance le flux comme après une photo.
  Future<void> _applyFace(
    File file, {
    required bool imported,
    bool isVideo = false,
  }) async {
    _lockType(); // une face posée = le type de la card est décidé
    if (_cardType == CardType.mono || _step != 0) {
      // Mono : face unique ; sinon on est au verso.
      if (_cardType == CardType.mono) {
        _front = file;
        _frontImported = imported;
        _frontIsVideo = isVideo;
        _back = null;
      } else {
        _back = file;
        _backImported = imported;
        _backIsVideo = isVideo;
      }
      _berealTimer?.cancel();
      setState(() => _step = 2);
    } else {
      _front = file;
      _frontImported = imported;
      _frontIsVideo = isVideo;
      setState(() => _step = 1);
      await _ensureLens(back: false);
    }
  }

  /// « Face tableau » : saute la photo de la face courante et pose un fond
  /// noir, à dessiner/annoter au récap (consigne Jay, avec confirmation).
  Future<void> _useBlackboard() async {
    if (_busy) return;
    final label = _type == CardType.mono || _step == 0 ? 'recto' : 'verso';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Face tableau'),
        content: Text(
          'Le $label ne sera pas une photo : tu auras un tableau noir à '
          'dessiner et annoter à l\'étape suivante. Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Oui, tableau'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final file = await _generateBlackboard();
      await _applyFace(file, imported: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Import galerie (cards classiques et Mono uniquement, consigne Jay) :
  /// choix dans la galerie puis ajustement (recadrage, zoom, rotation,
  /// remplir/adapter sur fond noir) — pas d'outils dessin/texte ensuite.
  bool get _galleryAllowed =>
      _type == CardType.standard || _type == CardType.mono;

  Future<void> _importFromGallery() async {
    if (_busy) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    final adjusted = await Navigator.of(context).push<File>(
      MaterialPageRoute(
        builder: (_) => GalleryImportScreen(source: File(picked.path)),
      ),
    );
    if (adjusted == null || !mounted) return;
    await _applyFace(adjusted, imported: true);
  }

  static Future<File> _generateBlackboard() async {
    // Format unifié des cards : 9:16 vertical
    const width = 900.0, height = 1600.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, width, height),
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
    final image = await recorder.endRecording().toImage(
      width.toInt(),
      height.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(
      '${Directory.systemTemp.path}/board_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    return file;
  }

  @override
  void dispose() {
    _berealTimer?.cancel();
    _recordTimer?.cancel();
    _typeSettle?.cancel();
    _typeController.dispose();
    _camera.removeListener(_onCameraChanged);
    _camera.dispose();
    super.dispose();
  }

  /// Aperçu d'un flux natif (clé de préview + texture), recadré « cover »
  /// dans le cadre du parent — jamais d'étirement (fix distorsion conservé).
  Widget _nativePreview(String key, int? textureId, {required bool mirror}) {
    if (textureId == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return NativeCameraPreview(
      textureId: textureId,
      info: _camera.previews[key],
      mirror: mirror,
    );
  }

  /// Cadre 9:16 : aperçu principal — flux simple (bascule animée entre
  /// caméras) ou DOUBLE FLUX Oneshot (vignette PiP 9:16 en haut à droite,
  /// frontale par défaut, tap sur la vignette = échange des vues).
  Widget _previewFrame() {
    if (_dualOpening) return _dualSearchFrame();
    if (_camera.glDualActive && _type == CardType.oneshot) {
      return _dualPreviewFrame();
    }

    // La texture reste la MÊME à travers la bascule (la couche native
    // rebinde le flux dessus) : on ne recrée plus le widget Texture — c'est
    // ce qui montrait un trou noir pendant la réouverture de la caméra.
    // Pendant la bascule, un voile flouté couvre la dernière image.
    Widget main = Stack(
      fit: StackFit.expand,
      children: [
        _nativePreview(
          'main',
          _camera.textureId,
          mirror: !_camera.lensBack && _selfieMirror,
        ),
        AnimatedOpacity(
          opacity: _switching ? 1 : 0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          child: IgnorePointer(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: const ColoredBox(color: Color(0x33000000)),
            ),
          ),
        ),
      ],
    );

    if (_type == CardType.mono) {
      // Mono : double-tap = bascule caméra (comme Snapchat, consigne Jay) —
      // y compris pendant une vidéo (enregistrement persistant natif).
      main = GestureDetector(onDoubleTap: _toggleLens, child: main);
    }

    return Center(
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: ClipRRect(borderRadius: BorderRadius.circular(18), child: main),
      ),
    );
  }

  /// Ouverture du double live (~2 s) : cadre d'attente explicite, jamais un
  /// écran noir muet (retour Jay, v0.8.5).
  Widget _dualSearchFrame() {
    return Center(
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: const ColoredBox(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 14),
                  Text(
                    'Ouverture du double live…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Double prévisualisation Oneshot (consigne Jay v0.5.0, enfin possible
  /// avec la couche native) : arrière en grand, frontale en vignette PiP
  /// 9:16 (~22 % de la largeur) en haut à droite ; taper la vignette
  /// échange les vues. La CAPTURE reste arrière = recto, avant = verso,
  /// quel que soit l'agencement.
  Widget _dualPreviewFrame() {
    final mainIsBack = !_pipSwapped;
    // Miroir de la frontale : réglage utilisateur, ON par défaut (v0.9.17).
    // L'arrière n'est JAMAIS mirrorée. Le réglage ne touche que l'aperçu — la
    // photo capturée n'est pas mirrorée (voir _selfieMirror).
    //
    // INVERSION VOULUE sur le moteur GPU (constatée au test, v0.9.18) : le flux
    // GL de la frontale arrive DÉJÀ mirroré (la matrice de la SurfaceTexture
    // contient le retournement), là où le flux CameraX du mode simple arrive
    // brut. Un retournement Dart y produit donc l'effet CONTRAIRE : pour un
    // miroir ON à l'écran, il ne faut PAS retourner. D'où le `!`.
    // Ce sens dépend du matériel — à revérifier sur d'autres appareils
    // (RAPPELS « fiabilité dual-cam : test multi-appareils »).
    final mirrorFront = !_selfieMirror;
    final mainView = _nativePreview(
      mainIsBack ? 'glBack' : 'glFront',
      mainIsBack ? _camera.glBackTextureId : _camera.glFrontTextureId,
      mirror: !mainIsBack && mirrorFront,
    );
    final pipView = _nativePreview(
      mainIsBack ? 'glFront' : 'glBack',
      mainIsBack ? _camera.glFrontTextureId : _camera.glBackTextureId,
      mirror: mainIsBack && mirrorFront,
    );

    return Center(
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final pipWidth = constraints.maxWidth * 0.22;
              return Stack(
                children: [
                  Positioned.fill(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: KeyedSubtree(
                        key: ValueKey('main-$mainIsBack'),
                        child: mainView,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    width: pipWidth,
                    height: pipWidth * 16 / 9,
                    child: GestureDetector(
                      onTap: () => setState(() => _pipSwapped = !_pipSwapped),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white38),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            transitionBuilder: (child, animation) =>
                                SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0.3, -0.3),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                                ),
                            child: KeyedSubtree(
                              key: ValueKey('pip-$mainIsBack'),
                              child: pipView,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(_error)),
      );
    }
    if (_step == 2) {
      return _RecapStep(
        front: _front!,
        back: _back,
        // Type FIGÉ à la prise — surtout pas _type (que le sélecteur peut
        // encore refléter) : c'est ce qui a produit une Mono à deux faces.
        type: _cardType,
        frontImported: _frontImported,
        backImported: _backImported,
        frontIsVideo: _frontIsVideo,
        backIsVideo: _backIsVideo,
      );
    }

    final shutterColor = _type == CardType.standard
        ? Colors.white
        : _type.color;
    // Bouton de bascule caméra : Mono (en plus du double-tap, y compris
    // PENDANT une vidéo — la couche native maintient l'enregistrement à
    // travers la bascule, comme Snapchat) et Oneshot en vue simple de
    // secours (bascule de l'aperçu, jamais pendant un enregistrement).
    final showLensToggle =
        _type == CardType.mono ||
        (_type == CardType.oneshot &&
            _step == 0 &&
            !_camera.glDualActive &&
            !_recording);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        // Chaque enfant du Stack porte une clé : plusieurs sont
        // conditionnels (masqués pendant l'enregistrement) et, sans clé,
        // le rebuild déclenché PENDANT l'appui long recréait l'élément du
        // déclencheur — son LongPressGestureRecognizer était détruit en
        // plein geste et onLongPressEnd n'arrivait jamais (relâcher ne
        // stoppait plus la vidéo).
        child: Stack(
          children: [
            Positioned.fill(
              key: const ValueKey('preview'),
              child: _previewFrame(),
            ),
            if (_busy && _type == CardType.oneshot)
              const Positioned.fill(
                key: ValueKey('oneshot-busy'),
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Oneshot — les deux faces…'),
                      ],
                    ),
                  ),
                ),
              ),
            if (ref.watch(devCameraHudProvider))
              Positioned(
                key: const ValueKey('hud'),
                top: 60,
                left: 12,
                child: _CameraHud(
                  camera: _camera,
                  caps: _caps,
                  dualError: _dualError,
                ),
              ),
            Positioned(
              key: const ValueKey('close'),
              top: 12,
              left: 12,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              key: const ValueKey('header'),
              top: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _type == CardType.mono
                          ? 'Mono — face unique'
                          : _step == 0
                          ? 'Recto — ce que tu vois'
                          : 'Verso — toi',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  if (widget.bereal)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          gradient: CardType.bereal.gradient,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'BeReal · ${_berealRemaining ~/ 60}:${(_berealRemaining % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Double live (Oneshot) : demandé EXPLICITEMENT (décision Jay,
            // 2026-07-14). Changer de mode ne réveille plus la caméra double :
            // c'est ce bouton, et lui seul, qui l'ouvre.
            if (_canOfferDual)
              Positioned(
                key: const ValueKey('dual-live'),
                bottom: 190,
                right: 16,
                child: _DualLiveButton(onPressed: _tryOpenDual),
              ),
            // Sélecteur de type : AVANT la première photo. Épuré : texte seul,
            // swipe localisé (PageView) et mise en avant animée du mode actif.
            // Masqué pendant un enregistrement vidéo.
            if (!widget.bereal && _step == 0 && !_recording)
              Positioned(
                key: const ValueKey('type-selector'),
                bottom: 124,
                left: 0,
                right: 0,
                // VERROU : dès le déclenchement, le type de la card est figé
                // (bug critique du 2026-07-14 : mode changé pendant le
                // traitement → Mono à deux faces). Le sélecteur devient
                // inerte ET grisé — l'utilisateur voit que c'est verrouillé,
                // il ne se demande pas pourquoi son geste n'a rien fait.
                child: IgnorePointer(
                  ignoring: _typeLocked,
                  child: AnimatedOpacity(
                    opacity: _typeLocked ? 0.35 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: SizedBox(
                      height: 46,
                      child: PageView.builder(
                        controller: _typeController,
                        physics: _typeLocked
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        onPageChanged: (i) =>
                            _onTypeChanged(CardType.selectable[i]),
                        itemCount: CardType.selectable.length,
                        itemBuilder: (context, index) {
                          final type = CardType.selectable[index];
                          return AnimatedBuilder(
                            animation: _typeController,
                            builder: (context, _) {
                              final page =
                                  _typeController.hasClients &&
                                      _typeController.position.haveDimensions
                                  ? _typeController.page!
                                  : _typeController.initialPage.toDouble();
                              final distance = (page - index).abs().clamp(
                                0.0,
                                1.0,
                              );
                              final selectedness = 1.0 - distance;
                              return GestureDetector(
                                onTap: () => _typeController.animateToPage(
                                  index,
                                  duration: const Duration(milliseconds: 280),
                                  curve: Curves.easeOutCubic,
                                ),
                                child: Center(
                                  child: Transform.scale(
                                    scale: 0.82 + 0.34 * selectedness,
                                    child: Text(
                                      type.tag,
                                      style: TextStyle(
                                        color: Color.lerp(
                                          Colors.white38,
                                          type == CardType.standard
                                              ? Colors.white
                                              : type.color,
                                          selectedness,
                                        ),
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.1,
                                        shadows: [
                                          Shadow(
                                            blurRadius: 14 * selectedness,
                                            color:
                                                (type == CardType.standard
                                                        ? Colors.white
                                                        : type.color)
                                                    .withValues(
                                                      alpha: 0.7 * selectedness,
                                                    ),
                                          ),
                                          const Shadow(
                                            blurRadius: 4,
                                            color: Colors.black87,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            // Import galerie (cards classiques et Mono uniquement)
            if (_galleryAllowed && !_recording)
              Positioned(
                key: const ValueKey('gallery'),
                bottom: 42,
                left: 28,
                child: IconButton.filledTonal(
                  tooltip: 'Importer depuis la galerie',
                  icon: const Icon(Icons.photo_library_outlined),
                  onPressed: _busy ? null : _importFromGallery,
                ),
              ),
            // Face tableau : fond noir au lieu d'une photo
            if (!_recording)
              Positioned(
                key: const ValueKey('blackboard'),
                bottom: 42,
                right: 28,
                child: IconButton.filledTonal(
                  tooltip: 'Face tableau (fond noir à dessiner)',
                  icon: const Icon(Icons.gesture),
                  onPressed: _busy ? null : _useBlackboard,
                ),
              ),
            if (showLensToggle)
              Positioned(
                key: const ValueKey('lens-toggle'),
                bottom: 108,
                right: 28,
                child: IconButton.filledTonal(
                  tooltip: 'Changer de caméra',
                  icon: const Icon(Icons.cameraswitch),
                  onPressed: _busy || _switching ? null : _toggleLens,
                ),
              ),
            // Indicateur d'enregistrement : durée + consigne de verrouillage
            if (_recording)
              Positioned(
                key: const ValueKey('record-status'),
                bottom: 124,
                left: 0,
                right: 0,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.fiber_manual_record,
                            color: Colors.redAccent,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_recordSeconds ~/ 60}:${(_recordSeconds % 60).toString().padLeft(2, '0')}'
                            ' / ${_maxVideoSeconds ~/ 60}:${(_maxVideoSeconds % 60).toString().padLeft(2, '0')}',
                            style: const TextStyle(color: Colors.white),
                          ),
                          if (_recordLocked) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.lock,
                              color: Colors.white70,
                              size: 14,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _recordLocked
                          ? 'Vidéo verrouillée — tape le bouton pour arrêter'
                          : 'Relâche pour arrêter · glisse hors du bouton pour verrouiller',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                      ),
                    ),
                  ],
                ),
              ),
            Positioned(
              key: const ValueKey('shutter'),
              bottom: 28,
              left: 0,
              right: 0,
              child: Center(
                // Tap = photo ; appui maintenu = vidéo (verrouillage en
                // glissant hors du cercle, tap pour arrêter). Seuil réduit à
                // 180 ms (300 ms perçu trop long par Jay) — il remplace la
                // « pression forte », indétectable sur Android.
                child: RawGestureDetector(
                  gestures: {
                    TapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          TapGestureRecognizer
                        >(() => TapGestureRecognizer(), (recognizer) {
                          recognizer.onTap = _switching ? null : _onShutterTap;
                        }),
                    LongPressGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          LongPressGestureRecognizer
                        >(
                          () => LongPressGestureRecognizer(
                            duration: const Duration(milliseconds: 180),
                          ),
                          (recognizer) {
                            recognizer
                              ..onLongPressStart = _onShutterLongPressStart
                              ..onLongPressMoveUpdate = _onShutterLongPressMove
                              ..onLongPressEnd = _onShutterLongPressEnd;
                          },
                        ),
                  },
                  child: Container(
                    height: 76,
                    width: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _recording ? Colors.redAccent : shutterColor,
                        width: 5,
                      ),
                      color: _recording
                          ? Colors.redAccent.withValues(alpha: 0.35)
                          : _type == CardType.oneshot
                          ? shutterColor.withValues(alpha: 0.25)
                          : null,
                    ),
                    child: _recording
                        ? Icon(
                            _recordLocked ? Icons.stop : Icons.videocam,
                            color: Colors.white,
                          )
                        : _type == CardType.oneshot
                        ? const Icon(Icons.flip_camera_android)
                        : null,
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

/// Diagnostic caméra (dev) : ce que la couche native annonce réellement à
/// Flutter. Sert à trancher un bug d'aperçu (distorsion/rotation) sur chiffres
/// plutôt qu'au jugé. Activable dans Réglages → Développeur.
/// Bouton « double live » du Oneshot : les deux caméras en direct, à la
/// demande. Volontairement explicite — le double flux mobilise le matériel et
/// tous les appareils ne le supportent pas (décision Jay, 2026-07-14).
class _DualLiveButton extends StatelessWidget {
  const _DualLiveButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white24),
      ),
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        ),
        icon: const Icon(Icons.flip_camera_android, size: 18),
        label: const Text(
          'Double live',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _CameraHud extends StatelessWidget {
  const _CameraHud({required this.camera, this.caps, this.dualError});
  final NativeCameraController camera;
  final CameraCapabilities? caps;
  final String? dualError;

  @override
  Widget build(BuildContext context) {
    String line(String key) {
      final info = camera.previews[key];
      if (info == null) return '$key : —';
      return '$key : ${info.width}×${info.height} · rot ${info.rotationDegrees}°';
    }

    const style = TextStyle(color: Colors.white70, fontSize: 11);
    final c = caps;

    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            camera.glDualActive
                ? 'DOUBLE FLUX GPU ACTIF'
                : camera.dualActive
                ? 'DOUBLE FLUX (soft) ACTIF'
                : 'flux simple · ${camera.lensBack ? "arrière" : "avant"}',
            style: const TextStyle(
              color: Colors.amberAccent,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (c != null) ...[
            Text('${c.device} · SDK ${c.sdk}', style: style),
            Text(
              'concurrent — CameraX : ${c.cameraXCombos} · Camera2 : '
              '${c.camera2Combos == -1 ? "API<30" : c.camera2Combos}',
              style: style,
            ),
          ],
          for (final key in ['main', 'glBack', 'glFront'])
            Text(line(key), style: style),
          if (dualError != null)
            Text(
              'échec double flux : $dualError',
              style: const TextStyle(color: Colors.redAccent, fontSize: 10),
            ),
        ],
      ),
    );
  }
}

/// Récap : aperçu recto/verso (ou face unique en Mono), éditeur par face
/// (désactivé pour une image importée ou une vidéo — consigne Jay : les
/// outils d'édition ne s'appliquent qu'aux photos), type déjà fixé.
class _RecapStep extends StatefulWidget {
  const _RecapStep({
    required this.front,
    required this.back,
    required this.type,
    this.frontImported = false,
    this.backImported = false,
    this.frontIsVideo = false,
    this.backIsVideo = false,
  });
  final File front;
  final File? back; // null = Mono (face unique)
  final CardType type;
  final bool frontImported;
  final bool backImported;
  final bool frontIsVideo;
  final bool backIsVideo;

  @override
  State<_RecapStep> createState() => _RecapStepState();
}

class _RecapStepState extends State<_RecapStep> {
  late File _front = widget.front;
  late File? _back = widget.back;

  /// Originaux conservés pour « revenir à l'image initiale » (consigne Jay).
  late final File _originalFront = widget.front;
  late final File? _originalBack = widget.back;

  Future<void> _editFace(bool isFront) async {
    final current = isFront ? _front : _back!;
    final result = await Navigator.of(context).push<File>(
      MaterialPageRoute(builder: (_) => FaceEditorScreen(baseImage: current)),
    );
    if (result != null) {
      setState(() => isFront ? _front = result : _back = result);
    }
  }

  void _restoreFace(bool isFront) {
    setState(() => isFront ? _front = _originalFront : _back = _originalBack);
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type;
    final back = _back;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Ta Card '),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                gradient: type.gradient,
                color: type.gradient == null
                    ? type.color.withValues(alpha: 0.2)
                    : null,
                border: type.gradient == null
                    ? Border.all(color: type.color)
                    : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                type.tag,
                style: TextStyle(
                  color: type.gradient == null ? type.color : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (back == null)
            // Mono : face unique, présentée seule et centrée
            Row(
              children: [
                const Spacer(),
                Expanded(
                  flex: 2,
                  child: _Shot(
                    label: 'Face unique',
                    file: _front,
                    edited: _front != _originalFront,
                    imported: widget.frontImported,
                    isVideo: widget.frontIsVideo,
                    onEdit: () => _editFace(true),
                    onRestore: () => _restoreFace(true),
                  ),
                ),
                const Spacer(),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: _Shot(
                    label: 'Recto',
                    file: _front,
                    edited: _front != _originalFront,
                    imported: widget.frontImported,
                    isVideo: widget.frontIsVideo,
                    onEdit: () => _editFace(true),
                    onRestore: () => _restoreFace(true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Shot(
                    label: 'Verso',
                    file: back,
                    edited: back != _originalBack,
                    imported: widget.backImported,
                    isVideo: widget.backIsVideo,
                    onEdit: () => _editFace(false),
                    onRestore: () => _restoreFace(false),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Text(
            type.description,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white54),
          ),
          const SizedBox(height: 16),
          FilledButton(
            // push (pas pushReplacement) : le retour depuis l'écran d'envoi
            // ramène ici, dans la section Card (consigne Jay)
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CardSendScreen(
                  front: _front,
                  back: _back,
                  type: type,
                  imported: widget.frontImported || widget.backImported,
                  frontIsVideo: widget.frontIsVideo,
                  backIsVideo: widget.backIsVideo,
                ),
              ),
            ),
            child: const Text('Continuer'),
          ),
        ],
      ),
    );
  }
}

class _Shot extends StatelessWidget {
  const _Shot({
    required this.label,
    required this.file,
    required this.edited,
    required this.imported,
    required this.isVideo,
    required this.onEdit,
    required this.onRestore,
  });
  final String label;
  final File file;
  final bool edited;

  /// Image issue de la galerie : pas d'outils dessin/texte (consigne Jay).
  final bool imported;

  /// Face vidéo : aperçu en boucle muet, pas d'outils d'édition (photos
  /// uniquement pour le moment — consigne Jay).
  final bool isVideo;
  final VoidCallback onEdit;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: isVideo
                ? _VideoThumb(file: file)
                : Image.file(file, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isVideo)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Icon(Icons.videocam, size: 16, color: Colors.white38),
              )
            else if (imported)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Icon(
                  Icons.photo_library_outlined,
                  size: 16,
                  color: Colors.white38,
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.draw, size: 20),
                tooltip: 'Modifier (dessin, texte)',
                onPressed: onEdit,
              ),
            if (edited && !isVideo)
              IconButton(
                icon: const Icon(Icons.restore, size: 20),
                tooltip: 'Revenir à l\'image initiale',
                onPressed: onRestore,
              ),
          ],
        ),
      ],
    );
  }
}

/// Aperçu vidéo du récap : lecture en boucle, muette, recadrée cover.
class _VideoThumb extends StatefulWidget {
  const _VideoThumb({required this.file});
  final File file;

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  late final VideoPlayerController _controller = VideoPlayerController.file(
    widget.file,
  );

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (!mounted) return;
      _controller
        ..setLooping(true)
        ..setVolume(0)
        ..play();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: Icon(Icons.videocam, color: Colors.white38)),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: _controller.value.size.width,
        height: _controller.value.size.height,
        child: VideoPlayer(_controller),
      ),
    );
  }
}
