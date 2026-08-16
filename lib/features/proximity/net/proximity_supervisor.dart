import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../proximity_identity.dart';
import 'ble_radio.dart';
import 'radio_status.dart';

/// Ce que l'utilisateur VEUT, et ce que le matériel FAIT — deux choses
/// distinctes, réunies ici sans être confondues.
class ProximityRuntime {
  const ProximityRuntime({
    required this.wantsVisible,
    required this.status,
    this.intentLoaded = false,
  });

  /// L'intention de l'utilisateur. **Persistée**, donc elle survit à la mort de
  /// l'app, à un redémarrage du téléphone, à une coupure de Bluetooth.
  final bool wantsVisible;

  /// Ce que la radio fait réellement, publié par le natif.
  final RadioStatus status;

  /// Faux pendant les quelques millisecondes de lecture des préférences.
  /// Sans lui, l'interrupteur s'afficherait éteint puis sauterait — et un
  /// utilisateur qui le voit sauter le rebascule, donc coupe sa visibilité.
  final bool intentLoaded;

  /// Vrai quand tout marche : l'utilisateur veut être visible **et** la radio
  /// scanne. C'est la seule condition sous laquelle « personne à proximité »
  /// veut dire « personne ».
  bool get isLive => wantsVisible && status.isDetecting;

  ProximityRuntime copyWith({
    bool? wantsVisible,
    RadioStatus? status,
    bool? intentLoaded,
  }) => ProximityRuntime(
    wantsVisible: wantsVisible ?? this.wantsVisible,
    status: status ?? this.status,
    intentLoaded: intentLoaded ?? this.intentLoaded,
  );
}

/// Le superviseur : il tient l'intention, écoute l'état, et **réconcilie les
/// deux en permanence**.
///
/// ## Ce qu'il remplace
///
/// L'ancien `ProximityService` gardait `visible` en mémoire, dans le même objet
/// que la liste des pairs, les sessions chiffrées et les demandes d'amis. Trois
/// conséquences, toutes constatées au test de Jay :
///
/// - **l'app rouverte** repartait invisible, alors que le service de premier
///   plan tournait encore — la notification disait une chose, l'écran une autre ;
/// - **le Bluetooth rallumé** ne relançait rien, il fallait couper puis remettre
///   l'interrupteur, ce que personne ne devine ;
/// - **une erreur** était effacée par la première mise à jour d'état venue.
///
/// ## La règle
///
/// L'intention ne change **que** sur action de l'utilisateur. Tout le reste —
/// Bluetooth coupé, permission retirée, service tué par Android — ne touche
/// **jamais** l'intention : ce sont des états, et le superviseur les rattrape
/// dès qu'ils redeviennent favorables.
class ProximitySupervisor extends Notifier<ProximityRuntime> {
  static const prefsKey = 'proximity_visible';

  final _radio = BleRadio();
  final _identity = ProximityIdentity();

  StreamSubscription<RadioEvent>? _events;
  Timer? _rotation;
  int _slot = -1;

  /// Les constats bruts, pour les couches du dessus (présence, transport).
  ///
  /// Le superviseur ne les interprète pas : il possède l'état de la RADIO, pas
  /// celui du réseau de pairs. Mélanger les deux est exactement ce qui a produit
  /// un fichier de 1040 lignes.
  final _feed = StreamController<RadioEvent>.broadcast();
  Stream<RadioEvent> get events => _feed.stream;

  @override
  ProximityRuntime build() {
    ref.onDispose(() {
      _events?.cancel();
      _rotation?.cancel();
      _feed.close();
    });
    _listen();
    _restore();
    return const ProximityRuntime(wantsVisible: false, status: RadioIdle());
  }

  void _listen() {
    _events = _radio.events().listen((event) {
      if (event is RadioStatusEvent) {
        state = state.copyWith(status: event.status);
      }
      if (!_feed.isClosed) _feed.add(event);
    });
  }

  /// Relit l'intention et rétablit la radio si elle était active.
  ///
  /// ⚠️ C'est ce qui règle « fermer puis rouvrir l'app » : l'utilisateur n'a
  /// rien à refaire, et l'écran ne ment pas pendant la reprise.
  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final wanted = prefs.getBool(prefsKey) ?? false;
    state = state.copyWith(wantsVisible: wanted, intentLoaded: true);
    if (!wanted) {
      state = state.copyWith(status: await _radio.probe());
      return;
    }
    await _engage();
  }

  /// Pose l'intention de l'utilisateur. Le seul point d'entrée qui la modifie.
  Future<void> setVisible(bool wanted) async {
    if (state.wantsVisible == wanted && state.intentLoaded) return;
    state = state.copyWith(wantsVisible: wanted, intentLoaded: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, wanted);
    if (wanted) {
      await _engage();
    } else {
      _rotation?.cancel();
      _rotation = null;
      await _radio.stop();
    }
  }

  /// Redemande à la radio de démarrer — après l'octroi d'une permission, ou
  /// après que l'utilisateur a rallumé le Bluetooth depuis l'app.
  ///
  /// Ne touche pas à l'intention : on ne réessaie que ce qui a échoué.
  Future<void> retry() async {
    if (!state.wantsVisible) return;
    await _engage();
  }

  Future<void> _engage() async {
    // ⚠️ **On sonde AVANT de démarrer.** Un obstacle connu — Bluetooth éteint,
    // permission manquante — se dit tout de suite, sans attendre qu'un
    // événement remonte. Sans cela, l'écran reste sur « Démarrage… » aussi
    // longtemps que le flux tarde : c'est exactement ce que Jay a constaté au
    // test du 2026-08-16, et l'attente n'apprend rien à personne.
    final blocker = await _radio.probe();
    if (blocker is! RadioIdle) {
      state = state.copyWith(status: blocker);
    } else {
      state = state.copyWith(status: const RadioStarting());
    }
    _slot = ProximityIdentity.slotIndex(DateTime.now());
    await _radio.start(await _identity.currentRotatingId());
    _rotation?.cancel();
    // Une minute : le créneau dure 15 min, on veut juste ne pas le rater de
    // beaucoup. Un réveil par minute sur un service déjà vivant ne coûte rien.
    _rotation = Timer.periodic(const Duration(minutes: 1), (_) => _rotate());
  }

  Future<void> _rotate() async {
    final slot = ProximityIdentity.slotIndex(DateTime.now());
    if (slot == _slot) return;
    _slot = slot;
    try {
      await _radio.updateAdvert(await _identity.currentRotatingId());
    } catch (_) {
      // ⚠️ **L'échec dit quelque chose : le service n'est plus là.**
      //
      // La première version se contentait de l'ignorer. Mais si le service a
      // été tué, l'app restait visiblement « active » sans plus aucune radio —
      // et personne ne l'aurait su avant le prochain lancement. Puisque
      // l'intention est toujours là, on rétablit.
      if (state.wantsVisible) await _engage();
    }
  }
}

final proximitySupervisorProvider =
    NotifierProvider<ProximitySupervisor, ProximityRuntime>(
      ProximitySupervisor.new,
    );
