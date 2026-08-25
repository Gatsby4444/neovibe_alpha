import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../geo/coarse_location.dart';
import '../proximity_identity.dart';
import 'ping_repository.dart';
import 'proximity_supervisor.dart';
import 'radio_status.dart';

/// **L'ACQUISITION du ping de proximité : le GPS oriente, le BLE prouve.**
///
/// ## Ce que ce service fait, en une phrase
///
/// Il publie où je suis **à un kilomètre près**, récupère la liste des jetons à
/// écouter, **écoute** le BLE, et dépose ce qu'il a entendu. Il ne décide ni de
/// qui est affiché, ni de qui est encore là : ce sont des décisions
/// d'affichage, et elles vivent dans les vues.
///
/// ## ⚠️ Il n'ouvre AUCUNE connexion
///
/// C'est ce qui fait tomber le mur d'échelle de la v1. Celui-ci venait d'une
/// seule chose : le jeton public étant opaque, **savoir qui c'est exigeait
/// d'ouvrir une connexion GATT** — une par personne, contre un plafond d'environ
/// sept simultanées sur Android. Dans une salle de trente personnes, la
/// découverte ne pouvait pas aboutir.
///
/// Ici la résolution d'identité est faite par le serveur. Le BLE ne fait plus
/// que **confirmer une distance**, et pour ça il lui suffit d'écouter —
/// opération passive, un-vers-tous, qui monte à des centaines d'émetteurs sans
/// coût supplémentaire.
///
/// ## ⚠️ Premier plan uniquement
///
/// Ce service ne tourne que tant que quelqu'un l'observe. C'est ce qui permet de
/// n'exiger que la permission de localisation « pendant l'utilisation ».
///
/// Le croisement d'amis, lui, ne passe **pas** par ici : il vit en BLE pur,
/// fonctionne app fermée, et ne demande aucune permission de localisation sur
/// Android 12+.
class PingBeaconService extends Notifier<PingBeaconState> {
  /// Cadence de republication de la balise et de rafraîchissement de la liste.
  ///
  /// ⚠️ La balise expire côté serveur au bout de 5 minutes : republier toutes
  /// les 60 s laisse quatre échecs réseau d'affilée avant de disparaître.
  static const refreshEvery = Duration(seconds: 60);

  /// Cadence de dépôt des jetons entendus.
  ///
  /// ⚠️ **On groupe, on n'envoie pas à chaque annonce.** Un émetteur crie ~10
  /// fois par seconde : un appel serveur par annonce serait des centaines
  /// d'appels par minute pour un seul voisin.
  static const flushEvery = Duration(seconds: 10);

  Timer? _refresh;
  Timer? _flush;
  StreamSubscription<RadioEvent>? _radioFeed;

  /// Les jetons à écouter, en hexadécimal. Vide = on n'écoute rien.
  Set<String> _shortlist = const {};

  /// Ce qu'on a entendu depuis le dernier dépôt.
  final _heard = <String>{};

  @override
  PingBeaconState build() {
    ref.onDispose(_stop);

    // ⚠️ **On suit l'intention de l'utilisateur, pas l'état de la radio.**
    // Lier ce service à « la radio tourne » le ferait démarrer et s'arrêter au
    // rythme des aléas Bluetooth ; l'intention, elle, ne change que quand
    // l'utilisateur la change.
    final wants = ref.watch(
      proximitySupervisorProvider.select((r) => r.wantsVisible),
    );
    if (wants) {
      Future.microtask(_start);
    } else {
      _stop();
      Future.microtask(() => ref.read(pingRepositoryProvider).retireBeacon());
    }
    return const PingBeaconState();
  }

  Future<void> _start() async {
    if (_refresh != null) return;

    final blocker = await ref.read(coarseLocationProvider).blocker();
    if (blocker != null) {
      state = state.copyWith(blocker: blocker);
      return;
    }
    state = state.copyWith(blocker: null);

    _radioFeed ??= ref
        .read(proximitySupervisorProvider.notifier)
        .events
        .listen(_onRadioEvent);
    _refresh ??= Timer.periodic(refreshEvery, (_) => unawaited(_tick()));
    _flush ??= Timer.periodic(flushEvery, (_) => unawaited(_flushHeard()));
    await _tick();
  }

  void _stop() {
    _refresh?.cancel();
    _refresh = null;
    _flush?.cancel();
    _flush = null;
    _radioFeed?.cancel();
    _radioFeed = null;
    _shortlist = const {};
    _heard.clear();
  }

  /// Un tour : publier ma balise, puis récupérer la liste à écouter.
  ///
  /// ⚠️ **Dans cet ordre, et ce n'est pas indifférent.** Le serveur ne rend une
  /// liste qu'à celui qui a lui-même une balise fraîche — *on n'écoute que si
  /// on s'annonce*. Demander la liste avant de publier la rendrait
  /// systématiquement vide au premier tour.
  Future<void> _tick() async {
    final geo = ref.read(coarseLocationProvider);
    final repo = ref.read(pingRepositoryProvider);
    try {
      final fix = await geo.current();
      if (fix == null) {
        state = state.copyWith(blocker: await geo.blocker());
        return;
      }
      final identity = ref.read(proximityIdentityProvider);
      final slot = ProximityIdentity.slotIndex(DateTime.now());
      await repo.publishBeacon(
        fix: fix,
        token: await identity.currentPublicPingId(),
        slot: slot,
      );
      _shortlist = await repo.shortlist();
      state = state.copyWith(
        blocker: null,
        cell: fix.toString(),
        listening: _shortlist.length,
        lastError: null,
      );
    } catch (e) {
      // ⚠️ **Une panne réseau se DIT, elle ne se devine pas.** Sans ça, une
      // liste vide serait indiscernable de « personne autour » — c'est le
      // défaut que tout ce projet passe son temps à traquer.
      state = state.copyWith(lastError: '$e');
    }
  }

  /// Une annonce BLE vient d'arriver.
  ///
  /// ⚠️ **Seules les annonces PUBLIQUES nous concernent.** Un jeton privé
  /// appartient à une paire d'amis, et il est traité par une autre chaîne, avec
  /// d'autres règles (protocole v4, `AdvertType`).
  void _onRadioEvent(RadioEvent event) {
    if (event is! RadioScan) return;
    if (event.type != AdvertType.public) return;
    final hex = _hex(event.advertId);
    // ⚠️ **On ne dépose que ce qui est dans la liste.** Déposer tout ce qu'on
    // entend reviendrait à demander au serveur « qui est-ce ? » pour chaque
    // inconnu du quartier — c'est-à-dire à lui redonner le rôle d'annuaire que
    // toute cette conception lui retire.
    if (!_shortlist.contains(hex)) return;
    _heard.add(hex);
  }

  Future<void> _flushHeard() async {
    if (_heard.isEmpty) return;
    final batch = _heard.toList(growable: false);
    _heard.clear();
    try {
      final n = await ref
          .read(pingRepositoryProvider)
          .confirm(
            tokensHex: batch,
            slot: ProximityIdentity.slotIndex(DateTime.now()),
          );
      state = state.copyWith(confirmed: state.confirmed + n);
    } catch (e) {
      // Remettre dans le panier : un dépôt perdu, c'est une rencontre perdue.
      _heard.addAll(batch);
      state = state.copyWith(lastError: '$e');
    }
  }

  /// Redemande la permission de localisation, puis relance.
  Future<void> requestPermission() async {
    final blocker = await ref.read(coarseLocationProvider).request();
    state = state.copyWith(blocker: blocker);
    if (blocker == null) await _start();
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Ce que l'acquisition du ping constate. **Des faits, pas un affichage.**
class PingBeaconState {
  const PingBeaconState({
    this.blocker,
    this.cell,
    this.listening = 0,
    this.confirmed = 0,
    this.lastError,
  });

  /// Ce qui empêche de lire une position, ou `null`.
  final LocationBlocker? blocker;

  /// Le carreau publié, pour le diagnostic.
  final String? cell;

  /// Combien de jetons on écoute en ce moment.
  final int listening;

  /// Combien de constats ont été retenus par le serveur depuis le démarrage.
  final int confirmed;

  /// La dernière panne, telle quelle. ⚠️ Jamais avalée : une liste vide et une
  /// panne réseau doivent rester distinguables.
  final String? lastError;

  PingBeaconState copyWith({
    LocationBlocker? blocker,
    String? cell,
    int? listening,
    int? confirmed,
    String? lastError,
  }) => PingBeaconState(
    blocker: blocker,
    cell: cell ?? this.cell,
    listening: listening ?? this.listening,
    confirmed: confirmed ?? this.confirmed,
    lastError: lastError,
  );

  @override
  bool operator ==(Object other) =>
      other is PingBeaconState &&
      other.blocker == blocker &&
      other.cell == cell &&
      other.listening == listening &&
      other.confirmed == confirmed &&
      other.lastError == lastError;

  @override
  int get hashCode =>
      Object.hash(blocker, cell, listening, confirmed, lastError);
}

final pingBeaconProvider = NotifierProvider<PingBeaconService, PingBeaconState>(
  PingBeaconService.new,
);
