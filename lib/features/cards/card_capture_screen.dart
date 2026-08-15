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

import '../../core/motion.dart';

import '../../core/models/card.dart';
import '../../core/prefs.dart';
import '../../core/theme.dart';
import '../library_vibes/library_share_screen.dart';
import '../library_vibes/library_target.dart';
import 'capture_tools.dart';
import 'face_background.dart';
import 'face_editor_screen.dart';
import 'camera_controls.dart';
import 'gallery_import_screen.dart';
import 'native_camera.dart';
import 'send/circle_settings_screen.dart';
import 'send/send_format_screen.dart';
import 'send/vibe_draft.dart';

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
  const CardCaptureScreen({
    super.key,
    this.bereal = false,
    this.directRecipientIds,
    this.directRecipientLabel,
    this.libraryTarget,
  });

  /// **Bibliothèque éphémère** (chantier Jay 2026-08-10) : la capture est
  /// ouverte depuis le bouton « plus » d'un chat, pour ALIMENTER la
  /// bibliothèque partagée de la conversation plutôt qu'envoyer.
  ///
  /// Ce mode retire trois choses, à la demande de Jay : **l'aperçu après la
  /// prise** (l'auteur ne voit pas ce qu'il vient de capturer, c'est le cœur du
  /// format), la **couleur de fond** et l'**import galerie** — « le but est de
  /// prendre de vraies photos ou vidéos », et une image de la pellicule
  /// contredirait cette intention plus encore que le fond uni.
  final LibraryTarget? libraryTarget;

  /// Mode BeReal : fenêtre de capture contrainte de 5 minutes après la
  /// notification (le déclenchement manuel a été retiré du menu).
  final bool bereal;

  /// **Envoi direct depuis un chat** (consigne Jay 2026-08-01) : la capture est
  /// ouverte depuis une conversation, le destinataire est donc déjà connu.
  /// L'écran d'envoi se réduit alors aux réglages de la Card elle-même — pas de
  /// choix de destinataire, pas de publication en bibliothèque.
  final List<String>? directRecipientIds;
  final String? directRecipientLabel;

  @override
  ConsumerState<CardCaptureScreen> createState() => _CardCaptureScreenState();
}

class _CardCaptureScreenState extends ConsumerState<CardCaptureScreen>
    with TickerProviderStateMixin {
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

  /// Reprise d'UNE face depuis le récap : la prise qui suit remplace cette
  /// face et revient au récap, au lieu d'enchaîner sur la face suivante.
  var _retakeOnly = false;

  /// Fond courant du bouton couleur : face entièrement colorée à l'appui
  /// court, et fond derrière une photo importée qui ne remplit pas le cadre.
  var _background = FaceBackground.black;

  /// **Flash frontal allumé** (lueur d'écran, consigne Jay 2026-07-26).
  /// Le CALIBRAGE (chaleur, intensité) est mémorisé en préférences ;
  /// l'allumage, lui, repart éteint à chaque ouverture de la capture, comme le
  /// flash arrière. La lueur n'est affichée qu'en caméra frontale : c'est un
  /// flash de façade, il n'a aucun sens sur l'arrière.
  var _screenFlash = false;

  /// **Retardateur armé**, en secondes (0 = aucun).
  ///
  /// Il est désarmé dès qu'une face est prise, et [_timerRestore] garde la
  /// dernière valeur choisie pour la rétablir si l'utilisateur REPREND la face
  /// (consigne Jay : « désactivé après la prise, mais rétabli si l'utilisateur
  /// souhaite reprendre la photo ou la vidéo »).
  var _timerSeconds = 0;
  var _timerRestore = 0;

  /// Décompte en cours (null = aucun) et ce qu'il déclenchera à zéro.
  int? _countdown;
  Timer? _countdownTimer;
  VoidCallback? _countdownAction;

  /// **Photo HD** : la face est normalisée en 1440×2560 au lieu de 900×1600.
  /// L'état vaut pour toute la card (l'écran vit le temps de la prise, il
  /// disparaît à l'annulation comme à la finalisation) mais reste réglable
  /// face par face — consigne Jay.
  ///
  /// Sans effet sur la vidéo, dont le débit est plafonné par la limite d'upload
  /// Supabase (arbitrage Jay 2026-07-26, voir `RAPPELS.md`).
  var _hd = false;
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
    initialPage: CardType.selectable
        .indexOf(_type)
        .clamp(0, CardType.selectable.length - 1),
  );

  /// Fenêtre BeReal : 30 secondes pour boucler les deux prises « pour un
  /// vrai BeReal » (consigne Jay 2026-07-12 — remplace les 5 minutes).
  static const _berealWindow = Duration(seconds: 30);

  /// Durée max d'une vidéo selon le mode : 61 s en général (limite dev, à
  /// repenser avant la prod — rappel demandé par Jay),
  /// 15 s pour BeReal (2 faces dans la fenêtre de 30 s).
  int get _maxVideoSeconds => switch (_type) {
    CardType.bereal => 15,
    _ => 61,
  };
  Timer? _berealTimer;
  int _berealRemaining = _berealWindow.inSeconds;

  /// Animation du double-tap de bascule caméra (demande de Jay 2026-07-31) :
  /// jouée EN PLUS du retour haptique, elle occupe le temps mort de réouverture
  /// de la caméra. Voir [LensSwitchBurst].
  late final AnimationController _lensBurst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  /// La bascule avant/arrière est-elle autorisée dans l'état courant ?
  ///
  /// Sert au bouton ET au double-tap sur l'aperçu (demande de Jay 2026-07-31).
  ///
  /// - **BeReal** : la contrainte du format est de ne pas choisir.
  /// - **Oneshot** : les deux caméras prennent en même temps, il n'y a pas de
  ///   sens à choisir (consigne Jay 2026-07-26 — y compris en vue simple de
  ///   secours).
  /// - **Card classique** : autorisée hors enregistrement vidéo.
  bool get _lensToggleAllowed => switch (_type) {
    CardType.bereal || CardType.oneshot => false,
    _ => !_recording,
  };

  /// La **séquence d'entrée** de l'écran de capture.
  ///
  /// Deux fois le palier ample : ce n'est pas une nouvelle durée du système de
  /// mouvement, c'est une **composition** de deux phases (le fondu de
  /// l'interface, puis les contrôles) dont chacune dure un palier.
  /// La durée vit dans `CameraEntrance` : c'est elle qui distribue le rythme,
  /// et les fractions des contrôles en dépendent.

  /// Filet de sécurité : si l'aperçu n'arrive jamais (caméra en erreur,
  /// permission refusée), l'interface doit apparaître quand même.
  ///
  /// ⚠️ **Sans lui, l'écran resterait noir ET sans bouton retour** — l'entrée
  /// pilote l'opacité de tout le calque. Un défaut d'affichage deviendrait un
  /// piège dont on ne peut pas sortir.
  static const _entranceFallback = Duration(milliseconds: 1400);

  late final _entrance = AnimationController(
    vsync: this,
    duration: CameraEntrance.duration,
  );

  @override
  void initState() {
    super.initState();
    // Le bord à bord n'est PLUS basculé ici : il est posé une fois pour toutes
    // au démarrage (`main.dart`). Le basculer changeait la taille utile de la
    // fenêtre en pleine transition, donc remettait tout l'arbre en page —
    // `HomeShell` compris, encore monté derrière. C'était l'à-coup signalé par
    // Jay.
    //
    // Seul le STYLE des barres reste réglé ici : il ne touche pas aux
    // dimensions, donc il ne remet rien en page. Sur l'écran caméra, les
    // barres doivent disparaître dans le noir.
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );
    _camera.addListener(_onCameraChanged);
    _startWhenSettled();
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

  /// N'ouvre la caméra **qu'une fois la transition d'entrée terminée**.
  ///
  /// ## Le diagnostic (2026-08-15), sur le code et non au jugé
  ///
  /// Jay : *« il y a une espèce de lag/bug qui nuit à la transition »*.
  /// Voici ce que l'app faisait pendant les 380 ms du fondu, tout en même
  /// temps et pour l'essentiel **sur le fil de la plateforme** — celui-là même
  /// qui doit rester libre pour composer les images :
  ///
  /// 1. deux demandes de permission (caméra, micro), deux allers-retours ;
  /// 2. `NativeCameraController.capabilities()` — qui passe par
  ///    `withProvider`, donc **initialise toute la pile CameraX**, et interroge
  ///    en plus `concurrentCameraIds` côté Camera2 ;
  /// 3. `open()` — le bind CameraX, l'opération la plus lourde de l'écran ;
  /// 4. et, à chaque notification de la caméra, un `setState` qui reconstruit
  ///    l'arbre entier de cet écran — plusieurs fois pendant l'animation.
  ///
  /// Une animation ne peut pas être fluide pendant ça. **Ce n'était pas un
  /// bug de la transition : c'était du travail lourd programmé dessus.**
  ///
  /// ⚠️ Contrepartie assumée : la caméra commence à s'ouvrir ~380 ms plus tard.
  /// Le point (2) a été retiré du chemin critique en échange, et il coûtait
  /// davantage — voir `_loadCapabilities`.
  Future<void> _startWhenSettled() async {
    final animation = ModalRoute.of(context)?.animation;
    if (animation != null && !animation.isCompleted) {
      final settled = Completer<void>();
      void onStatus(AnimationStatus status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          if (!settled.isCompleted) settled.complete();
        }
      }

      animation.addStatusListener(onStatus);
      // Garde-fou : une transition interrompue ne doit jamais laisser l'écran
      // sans caméra. Le délai vaut deux fois la durée nominale.
      await Future.any([
        settled.future,
        Future<void>.delayed(NeoMotion.ample * 2),
      ]);
      animation.removeStatusListener(onStatus);
    }
    if (mounted) await _init();
  }

  /// Le sondage de capacités, **hors du chemin critique**.
  ///
  /// Il ne sert qu'au HUD de diagnostic (Réglages → Développeur), éteint par
  /// défaut. Il était pourtant **attendu avant l'ouverture de la caméra** — or
  /// il force l'initialisation complète de CameraX côté natif. Il retardait
  /// donc l'aperçu pour tout le monde, au profit d'un affichage que presque
  /// personne n'active.
  ///
  /// ⚠️ Ne pas le remettre dans `_init` : c'est exactement le motif « un outil
  /// de diagnostic qui coûte à ceux qui ne s'en servent pas ».
  Future<void> _loadCapabilities() async {
    final caps = await NativeCameraController.capabilities();
    if (mounted) setState(() => _caps = caps);
  }

  Future<void> _init() async {
    // Le filet de sécurité de la séquence d'entrée part D'ICI, et non de
    // `initState` : depuis que l'ouverture attend la fin de la transition, un
    // compte à rebours lancé à la construction se serait déclenché avant même
    // que la caméra n'ait commencé — et les contrôles seraient apparus sur du
    // noir, ce que cette séquence existe précisément pour éviter.
    Future<void>.delayed(_entranceFallback, () {
      if (mounted) _entrance.forward();
    });
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _error = 'Permission caméra refusée');
      return;
    }
    // Micro pour le son des vidéos ; refusé = vidéos muettes, pas bloquant.
    _micGranted = (await Permission.microphone.request()).isGranted;
    await _openWithRetry();
    // Après l'ouverture, et sans être attendu : l'aperçu ne dépend pas de lui.
    unawaited(_loadCapabilities());
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
  /// [settle] : garde-fou visuel après la bascule. Mis à `false` pendant la
  /// capture séquentielle du Oneshot — là, chaque milliseconde élargit la
  /// fenêtre où l'on peut changer de tête, et l'écran enchaîne aussitôt sur le
  /// récap.
  Future<void> _ensureLens({required bool back, bool settle = true}) async {
    // En double flux GPU, CameraX n'est pas bindé : une bascule taperait dans
    // le vide.
    if (_camera.glDualActive || _camera.lensBack == back) return;
    setState(() => _switching = true);
    try {
      await _camera.switchLens();
      await _dropTorchOnFront();
      await _applyScreenFlashAssist();
    } finally {
      await _settleAfterSwitch(settle: settle);
    }
  }

  /// Retire le voile de bascule.
  ///
  /// **Plus de pause en dur depuis le 2026-07-31.** `switchLens` ne rend
  /// désormais la main qu'une fois la NOUVELLE caméra en train de produire des
  /// images (événement natif `previewReady`, compté sur la session Camera2) :
  /// le trou que couvrait le délai de 160 ms n'existe plus, et c'est lui qui
  /// laissait entrevoir l'aperçu renversé quand il était trop court.
  ///
  /// [settle] ne garde qu'un rôle de garde-fou : sur un appareil où le signal
  /// d'image n'arriverait pas, `switchLens` sort sur son délai maximum et cette
  /// courte pause évite de dévoiler dans la foulée immédiate.
  Future<void> _settleAfterSwitch({bool settle = true}) async {
    if (settle) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (mounted) setState(() => _switching = false);
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
    } else if (previous == CardType.oneshot && !_camera.lensBack) {
      // En quittant le Oneshot, le recto redevient caméra arrière.
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

  /// Double-tap sur l'aperçu : la bascule, **plus** l'animation demandée par
  /// Jay (2026-07-31). Elle n'est jouée QUE sur le geste : au bouton, l'appui
  /// se voit déjà.
  void _toggleLensFromTap() {
    if (_busy || _switching || _camera.glDualActive || _dualOpening) return;
    // Remis à zéro en fin de course : à 1 le pictogramme est transparent mais
    // toujours dans l'arbre, et son `Opacity` coûterait une couche à chaque
    // repeint de l'aperçu (30 fois par seconde).
    _lensBurst.forward(from: 0).whenComplete(() {
      if (mounted) _lensBurst.value = 0;
    });
    _toggleLens();
  }

  /// Bascule avant/arrière (double-tap OU bouton), pour la Card classique.
  /// Jamais en BeReal ni en Oneshot — voir [_lensToggleAllowed].
  Future<void> _toggleLens() async {
    // Pendant l'ouverture du double live, CameraX est libéré : une bascule
    // taperait dans le vide (NullPointerException natif, journal v0.9.1).
    if (_busy || _switching || _camera.glDualActive || _dualOpening) return;
    // Jamais pendant un enregistrement vidéo : le seul mode qui l'autorisait
    // était la Mono, supprimée le 2026-08-10.
    if (_recording) return;
    // La réouverture de la caméra prend quelques centaines de ms : haptique
    // immédiate + voile flouté pendant la bascule, pour que l'attente se
    // lise comme une transition et non comme un gel (retour Jay v0.7.0).
    HapticFeedback.selectionClick();
    setState(() => _switching = true);
    try {
      await _camera.switchLens();
      await _dropTorchOnFront();
      await _applyScreenFlashAssist();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Bascule impossible : $e')));
      }
    } finally {
      await _settleAfterSwitch();
    }
  }

  /// Recadre un cliché au cadre 9:16 centré (celui montré à l'aperçu) et le
  /// normalise au format unifié des cards (900×1600). WYSIWYG : c'est le fix
  /// de la distorsion (l'aperçu n'est plus étiré, la photo correspond).
  ///
  /// Fait **en natif** (rapide : un décodage sous-échantillonné + un encodage
  /// JPEG). Le chemin Dart ci-dessous n'est plus qu'un secours : il encode du
  /// PNG, ce qui coûtait des secondes par face.
  ///
  /// [hd] : bouton HD armé → format 1440×2560 au lieu de 900×1600.
  static Future<File> _cropTo916(File source, {bool hd = false}) async {
    try {
      return await NativeCameraController.normalize(source, hd: hd);
    } catch (e) {
      await NativeCameraController.log(
        'normalisation native indisponible ($e) → repli Dart',
      );
      return _cropTo916Dart(source, hd: hd);
    }
  }

  static Future<File> _cropTo916Dart(File source, {bool hd = false}) async {
    final bytes = await source.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final targetW = hd ? 1440 : 900;
    final targetH = hd ? 2560 : 1600;
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
      ui.Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    image.dispose();
    final out = await recorder.endRecording().toImage(targetW, targetH);
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
  /// [locked] : démarrer DÉJÀ verrouillé (doigt libre, un tap pour arrêter).
  /// C'est le cas du retardateur — voir [_onShutterLongPressStart].
  Future<void> _startVideo({bool locked = false}) async {
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
      _recordLocked = locked;
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
    // Décompte en cours : le déclencheur l'annule. Un retardateur qu'on ne peut
    // plus arrêter serait un piège.
    if (_countdown != null) {
      _cancelCountdown();
      return;
    }
    if (_timerSeconds > 0) {
      _startCountdown(_capture);
      return;
    }
    _capture();
  }

  void _onShutterLongPressStart(LongPressStartDetails details) {
    _pressHeld = true;
    if (_countdown != null) return;
    if (_timerSeconds > 0) {
      // **Retardateur + vidéo : l'enregistrement démarre VERROUILLÉ.** Le
      // principe du retardateur est de pouvoir lâcher le téléphone ; exiger de
      // garder le doigt posé pendant le décompte PUIS toute la vidéo le viderait
      // de son sens. Un tap arrête, exactement comme après un verrouillage
      // manuel (glisser hors du cercle).
      _startCountdown(() => _startVideo(locked: true));
      return;
    }
    _startVideo();
  }

  /// Lance le décompte du retardateur, puis exécute [action].
  ///
  /// Le retardateur ne vaut que pour LA FACE en cours (consigne Jay) : il se
  /// désarme au déclenchement, mais sa valeur est gardée dans [_timerRestore]
  /// pour être rétablie si l'utilisateur reprend la face.
  void _startCountdown(VoidCallback action) {
    _countdownTimer?.cancel();
    _countdownAction = action;
    HapticFeedback.selectionClick();
    setState(() => _countdown = _timerSeconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      final remaining = (_countdown ?? 0) - 1;
      if (remaining > 0) {
        HapticFeedback.selectionClick();
        setState(() => _countdown = remaining);
        return;
      }
      timer.cancel();
      HapticFeedback.mediumImpact();
      setState(() {
        _countdown = null;
        _timerRestore = _timerSeconds;
        _timerSeconds = 0;
      });
      final action = _countdownAction;
      _countdownAction = null;
      action?.call();
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownAction = null;
    setState(() => _countdown = null);
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
    await _ensureLens(back: true, settle: false);
    final backShot = await _camera.takePicture();
    final betweenStart = DateTime.now();
    await _ensureLens(back: false, settle: false);
    final frontShot = await _camera.takePicture();
    final gap = DateTime.now().difference(betweenStart).inMilliseconds;
    await NativeCameraController.log(
      'Oneshot séquentiel : écart entre les deux faces $gap ms '
      '(total ${DateTime.now().difference(started).inMilliseconds} ms)',
    );
    _front = await _cropTo916(backShot, hd: _hd);
    _back = await _cropTo916(frontShot, hd: _hd);
  }

  /// Dernier rempart avant le récap : **le contenu doit correspondre au type**.
  ///
  /// Depuis la refonte du 2026-08-10, une Card classique accepte UNE ou DEUX
  /// faces (le verso peut être « passé »). Restent contraints à deux faces le
  /// **Oneshot** (deux caméras d'un même déclenché) et le **BeReal**. Si ce
  /// n'est pas le cas, c'est un bug — on le consigne et on refuse de continuer
  /// plutôt que de fabriquer une card impossible (une Mono à deux faces avait
  /// été créée le 2026-07-14).
  bool _facesMatchType() {
    final type = _cardType;
    final twoFaces = _back != null;
    final ok = type.requiresTwoFaces ? twoFaces : true;
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
      if (_cardType == CardType.oneshot && _step == 0) {
        var shot = false;
        if (_camera.glDualActive) {
          try {
            // Double flux GPU : les deux faces d'un coup (dernière image rendue
            // de chaque caméra → instantané, vraiment simultané). Arrière =
            // recto, avant = verso. Recadrage 9:16 / format card comme d'hab.
            final shots = await _camera.captureGlDual();
            _front = await _cropTo916(shots.back, hd: _hd);
            _back = await _cropTo916(shots.front, hd: _hd);
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
      final cropped = await _cropTo916(shot, hd: _hd);
      if (_step == 0) {
        _front = cropped;
        // Reprise d'une seule face depuis le récap : l'autre face existe déjà,
        // on ne relance pas le flux — on retourne au récap.
        if (_retakeOnly) {
          _retakeOnly = false;
          if (!_facesMatchType()) return;
          setState(() => _step = 2);
          return;
        }
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
    if (_step != 0) {
      // On est au verso.
      _back = file;
      _backImported = imported;
      _backIsVideo = isVideo;
      _berealTimer?.cancel();
      setState(() => _step = 2);
    } else {
      _front = file;
      _frontImported = imported;
      _frontIsVideo = isVideo;
      if (_retakeOnly) {
        _retakeOnly = false;
        setState(() => _step = 2);
        return;
      }
      setState(() => _step = 1);
      await _ensureLens(back: false);
    }
  }

  /// Reprendre la face précédente **sans tout annuler** (consigne Jay
  /// 2026-07-26) : pendant la prise du verso, revenir au recto.
  Future<void> _retakePreviousFace() async {
    if (_busy || _recording || _step != 1) return;
    setState(() {
      _front = null;
      _frontImported = false;
      _frontIsVideo = false;
      _timerSeconds = _timerRestore; // retardateur rétabli (consigne Jay)
      _step = 0;
    });
    await _ensureLens(back: true);
  }

  /// **Passer le verso** (demande de Jay 2026-08-10, remplace le mode Mono).
  ///
  /// Apparaît une fois le recto posé : la Card s'arrête à une face et part
  /// directement au récap. Ce n'est plus un type à part — c'est la même Card
  /// classique, simplement non retournable faute de verso.
  ///
  /// Réservé aux types dont le verso est optionnel : le Oneshot n'atteint
  /// jamais cette étape (ses deux faces partent d'un même déclenché) et le
  /// BeReal a besoin de ses deux faces par définition.
  bool get _canSkipBackFace =>
      _step == 1 && !_recording && !_cardType.requiresTwoFaces;

  void _skipBackFace() {
    if (_busy || !_canSkipBackFace) return;
    _back = null;
    _backImported = false;
    _backIsVideo = false;
    _berealTimer?.cancel();
    if (!_facesMatchType()) return;
    setState(() => _step = 2);
  }

  /// Refaire UNE face depuis le récap, en gardant l'autre.
  ///
  /// Le Oneshot est à part, comme toujours : ses deux faces sont capturées au
  /// même instant, on ne peut pas en refaire une seule — on relance la prise.
  Future<void> _retakeFromRecap(bool isFront) async {
    if (_busy) return;
    if (_cardType == CardType.oneshot) {
      setState(() {
        _front = null;
        _back = null;
        _frontIsVideo = false;
        _backIsVideo = false;
        _step = 0;
      });
      return;
    }
    // Card à une seule face (verso passé) : pas de face à préserver, on
    // repasse par le flux normal — et le bouton « Passer » se represente.
    _retakeOnly = _back != null;
    setState(() {
      // Reprise d'une face : le retardateur choisi pour la prise précédente est
      // rétabli (consigne Jay).
      _timerSeconds = _timerRestore;
      if (isFront) {
        _front = null;
        _frontImported = false;
        _frontIsVideo = false;
        _step = 0;
      } else {
        _back = null;
        _backImported = false;
        _backIsVideo = false;
        _step = 1;
      }
    });
    await _ensureLens(back: isFront);
  }

  /// Face entièrement colorée : saute la photo et pose un fond de la couleur
  /// (ou du dégradé) courant, à dessiner/annoter à l'étape suivante.
  ///
  /// Plus de dialogue de confirmation depuis que le bouton porte la couleur
  /// choisie : le geste est explicite, la demander à chaque fois serait une
  /// friction inutile (l'ancien bouton « tableau » était ambigu, pas celui-ci).
  Future<void> _useColorFace() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await _background.render();
      await _applyFace(file, imported: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Appui long sur le bouton couleur : palette (unis + dégradés).
  Future<void> _openPalette() async {
    final chosen = await showFaceBackgroundPalette(
      context,
      current: _background,
    );
    if (chosen != null && mounted) setState(() => _background = chosen);
  }

  /// Passage sur la caméra FRONTALE alors que le flash permanent (torche) est
  /// actif : la torche est coupée **et le flash arrière repasse en automatique**
  /// (consigne Jay 2026-07-26).
  ///
  /// Le rebind sur la frontale éteint déjà physiquement la LED, mais le MODE
  /// resterait « permanent » côté natif : revenir à l'arrière rallumerait la
  /// torche sans que l'utilisateur l'ait demandé. C'est ce retour surprise que
  /// cette règle supprime.
  Future<void> _dropTorchOnFront() async {
    if (_camera.lensBack || _camera.flashMode != FlashMode.torch) return;
    await _setFlash(FlashMode.auto);
  }

  /// La lueur du flash frontal est dessinée en Dart, mais deux choses ne
  /// peuvent se faire que côté natif (retour Jay 2026-07-31 : « Snap semble
  /// ajuster le capteur, ce que NeoVibe ne fait pas ») — le rétroéclairage à
  /// fond, et la correction d'exposition du capteur.
  ///
  /// Appelée exactement là où la lueur peut changer d'état : au bouton, et à
  /// chaque bascule de caméra (elle ne vaut qu'en frontale, comme la lueur).
  Future<void> _applyScreenFlashAssist() =>
      _camera.setScreenFlash(_screenFlashLit);

  /// La lueur est-elle réellement à l'écran ? (Le réglage survit à un
  /// aller-retour vers l'arrière, mais un flash de façade n'y a aucun sens.)
  bool get _screenFlashLit =>
      _screenFlash && !_camera.lensBack && _type != CardType.oneshot;

  Future<void> _setFlash(FlashMode mode) async {
    try {
      await _camera.setFlash(mode);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Flash indisponible : $e')));
      }
    }
  }

  /// Import galerie (cards classiques uniquement, consigne Jay) :
  /// choix dans la galerie puis ajustement (recadrage, zoom, rotation,
  /// remplir/adapter sur fond noir) — pas d'outils dessin/texte ensuite.
  /// Exclu en bibliothèque éphémère : une photo de la pellicule n'est pas une
  /// prise du moment (consigne Jay 2026-08-10).
  bool get _galleryAllowed =>
      _type == CardType.standard && widget.libraryTarget == null;

  Future<void> _importFromGallery() async {
    if (_busy) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    final adjusted = await Navigator.of(context).push<File>(
      MaterialPageRoute(
        builder: (_) => GalleryImportScreen(
          source: File(picked.path),
          // Le fond du bouton couleur sert aussi ici : c'est ce qu'on voit
          // derrière une photo qui ne remplit pas le 9:16 (consigne Jay).
          background: _background,
        ),
      ),
    );
    if (adjusted == null || !mounted) return;
    await _applyFace(adjusted, imported: true);
  }

  @override
  void dispose() {
    _berealTimer?.cancel();
    _recordTimer?.cancel();
    _countdownTimer?.cancel();
    _typeSettle?.cancel();
    _entrance.dispose();
    _typeController.dispose();
    _lensBurst.dispose();
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
        // Voile de bascule : OPAQUE et INSTANTANÉ à l'apparition, fondu doux
        // au retrait. Il était translucide (20 % de noir) et mettait 140 ms à
        // apparaître — soit exactement la fenêtre où l'aperçu montrait l'image
        // renversée (bug signalé par Jay, non résolu par la v0.9.24). Tant
        // qu'on n'a pas de signal « première image de la nouvelle caméra »
        // côté CameraX, la seule garantie est de ne RIEN laisser voir de la
        // transition, quelle qu'en soit la cause exacte.
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _switching ? 1 : 0,
            duration: Duration(milliseconds: _switching ? 0 : 200),
            curve: NeoMotion.enter,
            // Voile de bascule caméra : noir neutre, jamais teinté.
            child: const ColoredBox(color: NeoNeutrals.black),
          ),
        ),
        // Au-DESSUS du voile : c'est pendant la transition qu'il faut montrer
        // que le double-tap a été pris en compte.
        LensSwitchBurst(animation: _lensBurst),
      ],
    );

    if (_lensToggleAllowed) {
      // Double-tap = bascule caméra (comme Snapchat, consigne Jay). Étendu le
      // 2026-07-31 de Mono seul à **Card, One of One et Hot** — même règle que
      // le bouton, donc jamais en BeReal ni en Oneshot. En Mono, il vaut aussi
      // pendant une vidéo (enregistrement persistant natif).
      main = GestureDetector(onDoubleTap: _toggleLensFromTap, child: main);
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
                      duration: NeoMotion.normal,
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
                            duration: NeoMotion.normal,
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
      // Bibliothèque éphémère : PAS de récap. L'auteur ne revoit pas sa prise —
      // il passe directement à l'écran de partage (consigne Jay 2026-08-10).
      final target = widget.libraryTarget;
      if (target != null) {
        return LibraryShareScreen(
          front: _front!,
          back: _back,
          type: _cardType,
          target: target,
          frontIsVideo: _frontIsVideo,
          backIsVideo: _backIsVideo,
        );
      }
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
        directRecipientIds: widget.directRecipientIds,
        directRecipientLabel: widget.directRecipientLabel,
        onRetake: _retakeFromRecap,
      );
    }

    final shutterColor = _type == CardType.standard
        ? Colors.white
        : _type.color;
    // Bouton de bascule caméra — disponible sur TOUS les types et sur LES DEUX
    // FACES (consigne Jay 2026-07-26 : « il faut laisser un peu de liberté à la
    // création »). Le défaut reste arrière puis frontale, l'utilisateur décide
    // ensuite. Deux exceptions, comme toujours :
    // - Oneshot : les deux caméras filment ensemble, il n'y a rien à basculer
    //   (sauf en vue simple de secours, avant la prise) ;
    // - BeReal : la contrainte du format est justement de ne pas choisir.
    // Mono garde en plus la bascule PENDANT la vidéo (la couche native
    // maintient l'enregistrement à travers, comme Snapchat).
    // Le détail vit dans [_lensToggleAllowed] — le double-tap sur l'aperçu
    // suit exactement la même règle.
    final showLensToggle = _lensToggleAllowed;

    // Outils de PRISE ajoutés le 2026-07-26 : retardateur, grille, HD.
    // - **Oneshot** : exclu d'office, il n'hérite de rien (règle Jay) ;
    // - **BeReal** : exclu aussi, Jay a « d'autres projets pour le BeReal » et
    //   ne sait pas encore si ces outils y seront compatibles. Il détaillera.
    final showCaptureTools =
        _type != CardType.oneshot && _type != CardType.bereal;
    final gridOn = ref.watch(captureGridProvider);
    final screenFlashSettings = ref.watch(screenFlashProvider);
    // La lueur du flash frontal ne s'affiche QU'EN frontale : c'est un flash de
    // façade. Le réglage survit à un aller-retour vers l'arrière.
    final screenFlashLit = _screenFlashLit;
    // Retraits appliqués par le SafeArea : la lueur les annule pour reprendre
    // l'écran entier.
    final safePadding = MediaQuery.paddingOf(context);

    // Dès que l'aperçu a sa première image, la séquence d'entrée part. Le
    // `post-frame` évite de lancer une animation pendant un `build`.
    // ⚠️ `flashKnown` AUTANT que `_previewReady`, et c'est le correctif du
    // bouton flash qui « arrivait séparément après » (Jay, 2026-08-15).
    //
    // Séquence relevée dans `native_camera.dart` : l'événement `previewInfo`
    // notifie les écouteurs PENDANT la configuration de session, donc bien
    // avant qu'`open()` n'ait interrogé le natif sur la présence d'une LED.
    // Démarrer sur le seul `_previewReady` construisait donc le rail à cinq
    // boutons, et le sixième s'ajoutait après coup, hors animation.
    //
    // `hasFlash` seul ne pouvait pas servir de verrou : il vaut `false` avant
    // d'être connu ET `false` quand la réponse est non.
    if (_previewReady &&
        _camera.flashKnown &&
        _entrance.status == AnimationStatus.dismissed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entrance.forward();
      });
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        // Chaque enfant du Stack porte une clé : plusieurs sont
        // conditionnels (masqués pendant l'enregistrement) et, sans clé,
        // le rebuild déclenché PENDANT l'appui long recréait l'élément du
        // déclencheur — son LongPressGestureRecognizer était détruit en
        // plein geste et onLongPressEnd n'arrivait jamais (relâcher ne
        // stoppait plus la vidéo).
        //
        // `Clip.none` : la lueur du flash frontal DÉBORDE volontairement de la
        // zone sûre pour couvrir l'écran entier (voir sa clé plus bas).
        //
        // Le fondu d'ensemble occupe la PREMIÈRE moitié de la séquence ; le
        // déclencheur et le rail s'échelonnent ensuite, chacun lisant
        // `CameraEntrance` — voir `camera_controls.dart`.
        //
        // ⚠️ **Aucun fondu global ici, et c'est délibéré.** La v0.9.88 en avait
        // posé un autour de tout le `Stack` : il enveloppait donc l'aperçu
        // caméra — un `Texture`, composé par la plateforme — dans un calque
        // d'opacité. Résultat rapporté par Jay : **écran noir en mode Vibe,
        // seuls les boutons visibles**, plus un à-coup à l'ouverture. Le
        // Oneshot y échappait parce qu'il emprunte un autre chemin d'aperçu.
        //
        // Le fondu d'ouverture est déjà donné par `NeoFadeRoute`, une fois, au
        // niveau de la route. En remettre un ici ne faisait que superposer
        // deux fondus **et** toucher à la seule chose qu'il ne fallait pas
        // toucher.
        //
        // *Règle : le fondu appartient à l'habillage, jamais à l'image. Une
        // texture externe ne passe pas sous un calque d'opacité.*
        child: CameraEntrance(
          animation: _entrance,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                key: const ValueKey('preview'),
                child: _previewFrame(),
              ),
              // Grille de cadrage : dessinée dans le cadre 9:16, donc sur
              // exactement ce qui sera capturé — pas sur tout l'écran.
              if (gridOn && showCaptureTools)
                const Positioned.fill(
                  key: ValueKey('grid'),
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      child: CaptureGridOverlay(),
                    ),
                  ),
                ),
              // Flash frontal : la lueur doit couvrir **TOUT L'ÉCRAN** — pas le
              // cadre d'aperçu, ni même la zone de l'app (consigne Jay,
              // 2026-07-26 seconde passe). Ce `Positioned` aux marges NÉGATIVES
              // annule exactement le retrait du `SafeArea` parent : le calque
              // repart des quatre bords physiques, barre d'état et barre de
              // navigation comprises (d'où le mode bord à bord posé en initState
              // et le `Clip.none` du Stack).
              if (screenFlashLit)
                Positioned(
                  key: const ValueKey('screen-flash'),
                  top: -safePadding.top,
                  bottom: -safePadding.bottom,
                  left: -safePadding.left,
                  right: -safePadding.right,
                  child: ScreenFlashOverlay(settings: screenFlashSettings),
                ),
              if (_countdown != null)
                Positioned.fill(
                  key: const ValueKey('countdown'),
                  child: CountdownOverlay(seconds: _countdown!),
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
              // Reprendre la face précédente sans tout annuler (consigne Jay)
              if (_step == 1 && !_recording)
                Positioned(
                  key: const ValueKey('retake'),
                  top: 12,
                  left: 60,
                  child: IconButton(
                    tooltip: 'Reprendre le recto',
                    icon: const Icon(Icons.undo, color: Colors.white),
                    onPressed: _busy || _switching ? null : _retakePreviousFace,
                  ),
                ),
              // « Passer » : la Card s'arrête à une face (demande de Jay
              // 2026-08-10, en remplacement du mode Mono). N'apparaît qu'une
              // fois le recto posé, et jamais là où le verso est obligatoire
              // (Oneshot, BeReal).
              // Placé en bas à DROITE, en miroir du bouton galerie : le
              // haut-droite est pris par le bandeau d'étape et le flanc droit
              // par la colonne d'outils.
              if (_canSkipBackFace)
                Positioned(
                  key: const ValueKey('skip-back'),
                  bottom: 42,
                  right: 28,
                  child: _SkipBackButton(
                    onPressed: _busy || _switching ? null : _skipBackFace,
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
                        _step == 0 ? 'Recto — ce que tu vois' : 'Verso — toi',
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
                      duration: NeoMotion.fast,
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
                                    duration: NeoMotion.normal,
                                    curve: NeoMotion.enter,
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
                                                        alpha:
                                                            0.7 * selectedness,
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
              // Import galerie (cards classiques uniquement)
              if (_galleryAllowed && !_recording)
                Positioned(
                  key: const ValueKey('gallery'),
                  bottom: 42,
                  left: 28,
                  // Même direction artistique que le rail : c'est un contrôle de
                  // l'écran caméra, il n'a pas de raison d'avoir sa propre
                  // matière. Un `CameraRail` d'un seul enfant, parce que c'est
                  // lui qui porte la direction jusqu'au bouton.
                  child: CameraRail(
                    children: [
                      CameraButton(
                        tooltip: 'Importer depuis la galerie',
                        icon: const Icon(Icons.photo_library_outlined),
                        onPressed: _busy ? null : _importFromGallery,
                      ),
                    ],
                  ),
                ),
              // Colonne d'outils à droite (consigne Jay 2026-07-26), de haut en
              // bas : flash (LED à l'arrière / lueur d'écran en frontale),
              // retardateur, grille, HD, bascule caméra, couleur de fond. Les
              // menus s'ouvrent vers la gauche.
              //
              // **Rien de tout ça en Oneshot** (consigne Jay 2026-07-26) : le
              // Oneshot, c'est la caméra pure. Jamais de face tableau, pas de
              // bascule de sens (les deux caméras prennent en même temps), et un
              // flash qui n'aura pas les mêmes règles — Jay détaillera.
              if (!_recording && _type != CardType.oneshot)
                Positioned(
                  key: const ValueKey('tools'),
                  right: 20,
                  // Centrée verticalement (consigne Jay 2026-07-26) : `top` et
                  // `bottom` à 0 donnent toute la hauteur, `Center` place la
                  // colonne au milieu.
                  top: 0,
                  bottom: 0,
                  child: Center(
                    // Le rail de la caméra, dans la direction artistique
                    // choisie par Jay (Réglages → Apparence). L'écartement lui
                    // appartient : les `SizedBox(height: 12)` qui séparaient les
                    // boutons ont disparu, sinon deux réglages d'espacement
                    // seraient en désaccord.
                    child: CameraRail(
                      children: [
                        // FLASH — deux boutons qui ne coexistent JAMAIS
                        // (consigne Jay 2026-07-26) : la LED en caméra arrière,
                        // la lueur d'écran en frontale, au même emplacement.
                        if (_camera.lensBack) ...[
                          // Pas de LED sur cette caméra : pas de bouton du tout
                          // plutôt qu'un bouton menteur.
                          if (_camera.hasFlash)
                            _FlashControl(
                              mode: _camera.flashMode,
                              onChanged: _busy ? null : _setFlash,
                            ),
                        ] else
                          ScreenFlashControl(
                            on: _screenFlash,
                            settings: screenFlashSettings,
                            onToggle: (on) {
                              setState(() => _screenFlash = on);
                              _applyScreenFlashAssist();
                            },
                            onChanged: (s) =>
                                ref.read(screenFlashProvider.notifier).set(s),
                          ),
                        if (showCaptureTools) ...[
                          CaptureTimerControl(
                            seconds: _timerSeconds,
                            onChanged: _busy
                                ? null
                                : (value) => setState(() {
                                    _timerSeconds = value;
                                    if (value > 0) _timerRestore = value;
                                  }),
                          ),
                          GridButton(
                            active: gridOn,
                            onChanged: (value) => ref
                                .read(captureGridProvider.notifier)
                                .set(value),
                          ),
                          HdButton(
                            active: _hd,
                            onChanged: _busy
                                ? null
                                : (value) => setState(() => _hd = value),
                          ),
                        ],
                        if (showLensToggle)
                          CameraButton(
                            tooltip: 'Changer de caméra',
                            icon: const Icon(Icons.cameraswitch),
                            onPressed: _busy || _switching ? null : _toggleLens,
                          ),
                        // Bouton COULEUR (ex-bouton dessin) : appui court = face
                        // entièrement remplie de cette couleur, appui long =
                        // palette.
                        //
                        // **Jamais en BeReal** (consigne Jay 2026-07-31, « cela
                        // va de soi ») : le BeReal est obligatoirement une PHOTO
                        // PRISE AVEC LES CAMÉRAS du téléphone. Une face de
                        // couleur unie n'est pas une prise de vue — elle viderait
                        // le format de sa contrainte.
                        // Exclu aussi en **bibliothèque éphémère** (consigne Jay
                        // 2026-08-10) : le tableau n'y sert à rien, le but est
                        // une vraie photo ou vidéo du moment.
                        if (_type != CardType.bereal &&
                            widget.libraryTarget == null)
                          _ColorButton(
                            background: _background,
                            onTap: _busy ? null : _useColorFace,
                            onLongPress: _busy ? null : _openPalette,
                          ),
                      ],
                    ),
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
                child: CameraShutterEntrance(
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
                              recognizer.onTap = _switching
                                  ? null
                                  : _onShutterTap;
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
                                  ..onLongPressMoveUpdate =
                                      _onShutterLongPressMove
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
              ),
            ],
          ),
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

/// « Passer » : termine la Card sur son recto seul (demande de Jay
/// 2026-08-10). Volontairement discret et non coloré — c'est une sortie de
/// secours du parcours, pas une action mise en avant : la Card à deux faces
/// reste la forme normale du produit.
class _SkipBackButton extends StatelessWidget {
  const _SkipBackButton({required this.onPressed});

  final VoidCallback? onPressed;

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
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
        iconAlignment: IconAlignment.end,
        icon: const Icon(Icons.arrow_forward, size: 18),
        label: const Text(
          'Passer',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
    this.directRecipientIds,
    this.directRecipientLabel,
    required this.onRetake,
  });
  final File front;
  final File? back; // null = Mono (face unique)

  /// Refaire une face (true = recto) sans perdre l'autre.
  final void Function(bool isFront) onRetake;
  final CardType type;
  final bool frontImported;
  final bool backImported;
  final bool frontIsVideo;
  final bool backIsVideo;

  /// Destinataire imposé (capture ouverte depuis un chat) — simplement relayé
  /// à l'écran d'envoi.
  final List<String>? directRecipientIds;
  final String? directRecipientLabel;

  @override
  State<_RecapStep> createState() => _RecapStepState();
}

class _RecapStepState extends State<_RecapStep> {
  late File _front = widget.front;
  late File? _back = widget.back;

  /// Identité locale de CETTE prise, tirée une seule fois.
  ///
  /// Le `VibeDraft` se reconstruit à chaque appui sur « Continuer » — il le
  /// faut, les faces ont pu être retouchées entre-temps. L'identifiant, lui,
  /// doit survivre à ces reconstructions : c'est la clé sous laquelle
  /// « Enregistrer pour moi » a peut-être déjà écrit une copie.
  late final String _localId = VibeDraft.newLocalId();

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
            const Text('Ta Vibe '),
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
            // Verso passé : face unique, présentée seule et centrée
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
                    onRetake: () => widget.onRetake(true),
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
                    onRetake: () => widget.onRetake(true),
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
                    onRetake: () => widget.onRetake(false),
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
            onPressed: () {
              final draft = VibeDraft(
                front: _front,
                back: _back,
                type: type,
                imported: widget.frontImported || widget.backImported,
                frontIsVideo: widget.frontIsVideo,
                backIsVideo: widget.backIsVideo,
                directRecipientIds: widget.directRecipientIds,
                directRecipientLabel: widget.directRecipientLabel,
                localId: _localId,
              );
              Navigator.of(context).push(
                MaterialPageRoute(
                  // Envoi depuis un chat : la destination est imposée, il n'y a
                  // pas de format à choisir. C'est le SEUL chemin qui saute
                  // l'étape 1 (découpage du 2026-08-14).
                  builder: (_) => draft.direct
                      ? CircleSettingsScreen(draft: draft)
                      : SendFormatScreen(draft: draft),
                ),
              );
            },
            child: const Text('Continuer'),
          ),
        ],
      ),
    );
  }
}

/// Bouton flash + menu dépliant (consigne Jay 2026-07-26) : quatre modes en
/// **pictogrammes seuls**, le menu s'ouvre **vers la gauche**.
///
/// N'est monté que si la caméra active a une LED : pas de bouton du tout en
/// frontale (consigne Jay — un bouton grisé restait du bruit).
class _FlashControl extends StatefulWidget {
  const _FlashControl({required this.mode, required this.onChanged});

  final FlashMode mode;
  final ValueChanged<FlashMode>? onChanged;

  @override
  State<_FlashControl> createState() => _FlashControlState();
}

class _FlashControlState extends State<_FlashControl> {
  var _open = false;

  static IconData _icon(FlashMode mode) => switch (mode) {
    FlashMode.off => Icons.flash_off,
    FlashMode.auto => Icons.flash_auto,
    FlashMode.on => Icons.flash_on,
    FlashMode.torch => Icons.wb_sunny,
  };

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Le menu occupe la place à GAUCHE du bouton ; sa largeur s'anime.
        ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.centerRight,
            duration: NeoMotion.normal,
            curve: NeoMotion.enter,
            widthFactor: _open ? 1 : 0,
            // ⚠️ `heightFactor` AUTANT que `widthFactor` — corrigé le
            // 2026-08-15. Replier la seule largeur laissait le panneau
            // **occuper toute sa hauteur** : la ligne du flash frontal (des
            // curseurs, ~130 px) était donc trois fois plus haute que celle du
            // flash arrière (une rangée d'icônes), et la colonne centrée du
            // rail ne tombait pas au même endroit selon la caméra.
            //
            // C'est ce que Jay décrivait par « la disposition des boutons de la
            // vue frontale est différente ». Le défaut ne se voyait PAS sur le
            // panneau lui-même — il était invisible et poussait ses voisins.
            heightFactor: _open ? 1 : 0,
            child: AnimatedOpacity(
              opacity: _open ? 1 : 0,
              duration: NeoMotion.fast,
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final mode in FlashMode.values)
                      IconButton(
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          _icon(mode),
                          color: mode == widget.mode
                              ? NeoTheme.accentPink
                              : Colors.white,
                        ),
                        onPressed: () {
                          setState(() => _open = false);
                          widget.onChanged?.call(mode);
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        CameraButton(
          tooltip: 'Flash',
          active: widget.mode != FlashMode.off,
          icon: Icon(_icon(widget.mode)),
          onPressed: enabled ? () => setState(() => _open = !_open) : null,
        ),
      ],
    );
  }
}

/// Bouton couleur : une pastille de la couleur (ou du dégradé) choisie.
/// Appui court = face entièrement colorée ; appui long = palette.
class _ColorButton extends StatelessWidget {
  const _ColorButton({
    required this.background,
    required this.onTap,
    required this.onLongPress,
  });

  final FaceBackground background;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    // La couleur passe SOUS le bouton (`underlay`) : elle prend donc la
    // matière de la direction choisie au lieu de porter sa propre bordure
    // blanche, qui détonnait dans le rail.
    return CameraButton(
      tooltip: 'Face colorée — appui long pour la palette',
      icon: const SizedBox.shrink(),
      onPressed: onTap,
      onLongPress: onLongPress,
      underlay: DecoratedBox(
        decoration: background.decoration.copyWith(shape: BoxShape.circle),
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
    required this.onRetake,
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

  /// Reprendre la prise de cette face, en gardant l'autre.
  final VoidCallback onRetake;

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
            // Refaire CETTE face en gardant l'autre (consigne Jay 2026-07-26)
            IconButton(
              icon: const Icon(Icons.replay, size: 20),
              tooltip: 'Refaire cette face',
              onPressed: onRetake,
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
