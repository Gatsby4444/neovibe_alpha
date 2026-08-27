import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../geo/coarse_location.dart';
import '../proximity_identity.dart';
import 'ping_nearby_feed.dart';
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

  /// Cadence de **rafraîchissement** des jetons entendus.
  ///
  /// ⚠️ **On groupe, on n'envoie pas à chaque annonce.** Un émetteur crie ~10
  /// fois par seconde : un appel serveur par annonce serait des centaines
  /// d'appels par minute pour un seul voisin.
  ///
  /// ⚠️ **Passée de 10 s à 60 s le 2026-08-27.** Ce dépôt ne sert plus qu'à
  /// entretenir la fenêtre du serveur (`private.fenetre_canal()` = 3 min) :
  /// une fois par minute, c'est **deux battements manqués tolérés**. Savoir si
  /// l'autre est encore là ne passe plus par le serveur — la radio le dit
  /// (voir [kPingLocalGrace]).
  ///
  /// ⚠️ **La découverte, elle, n'attend pas 60 secondes** : un jeton entendu
  /// pour la **première fois** déclenche un dépôt immédiat. Sans ça, rencontrer
  /// quelqu'un prendrait une minute au lieu de quinze secondes.
  static const flushEvery = Duration(seconds: 60);

  Timer? _refresh;
  Timer? _flush;
  StreamSubscription<RadioEvent>? _radioFeed;

  /// Les jetons à écouter, en hexadécimal. Vide = on n'écoute rien.
  Set<String> _shortlist = const {};

  /// Ce qu'on a entendu depuis le dernier dépôt.
  final _heard = <String>{};

  /// **Quand chaque jeton a été entendu pour la dernière fois, ici, par la
  /// radio.** C'est la donnée qui rend l'écran autonome.
  ///
  /// ⚠️ **Elle existait déjà — on la jetait.** Le téléphone entendait l'autre
  /// dix fois par seconde, et allait quand même demander au serveur, toutes les
  /// dix secondes, s'il était encore là. On garde maintenant ce qu'on entend.
  ///
  /// ⚠️ **Elle se PURGE, et c'est vital.** Sans purge, les jetons s'accumulent :
  /// au changement de créneau (15 min) les anciens restent, `_peutEtre` les voit
  /// comme « entendus mais pas encore nommés », et **force un appel serveur
  /// toutes les dix secondes, pour toujours**. Toute l'économie disparaîtrait —
  /// en silence, sans qu'aucun écran n'affiche quoi que ce soit de faux.
  /// (Défaut introduit et corrigé le 2026-08-27, avant le premier test.)
  final _heardAt = <String, DateTime>{};

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

  /// Démarre l'acquisition. **Sans jamais s'arrêter sur un blocage.**
  ///
  /// ⚠️ **C'est la moitié invisible de la panne du 2026-08-26.** Cette méthode
  /// posait son verdict *avant* d'armer ses minuteurs et sortait : une fois
  /// bloquée, la chaîne ne se réévaluait plus jamais. L'utilisateur pouvait
  /// accorder la permission dans les réglages et revenir — l'écran affichait
  /// toujours le même bandeau, et le seul remède était de rebasculer
  /// l'interrupteur de visibilité, ce que personne ne devine.
  ///
  /// On arme donc **toujours**, et c'est [_tick] qui constate à chaque tour. Un
  /// blocage levé se rattrape tout seul en moins d'une minute — la cause du
  /// cul-de-sac est supprimée, pas contournée.
  Future<void> _start() async {
    if (_refresh != null) return;

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
    // ⚠️ Le ping s'arrête : ce qu'on a entendu n'est plus une observation, c'est
    // un souvenir. Le garder ferait afficher des gens partis au redémarrage.
    _heardAt.clear();
    ref.read(ecouteLocaleProvider.notifier).clear();
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
      // ⚠️ **La finesse accordée est relevée à chaque tour, et elle ne bloque
      // rien.** Une position approximative reste une position : on publie, et
      // on dit la dégradation (voir [LocationPrecision]).
      final precision = await geo.precision();
      final fix = await geo.current();
      if (fix == null) {
        state = state.copyWith(
          blocker: await geo.blocker(),
          precision: precision,
        );
        return;
      }
      final identity = ref.read(proximityIdentityProvider);
      final slot = ProximityIdentity.slotIndex(DateTime.now());
      await repo.publishBeacon(
        fix: fix,
        token: await identity.currentPublicPingId(),
        slot: slot,
      );
      final liste = await repo.shortlist();
      _shortlist = liste.tokens;
      state = state.copyWith(
        blocker: null,
        precision: precision,
        cell: fix.toString(),
        listening: liste.length,
        listeningTruncated: liste.atLeast,
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
  /// d'autres règles (protocole v5, `AdvertType`).
  void _onRadioEvent(RadioEvent event) {
    if (event is! RadioScan) return;
    if (event.type != AdvertType.public) return;
    final hex = _hex(event.advertId);
    // ⚠️ **On ne dépose que ce qui est dans la liste.** Déposer tout ce qu'on
    // entend reviendrait à demander au serveur « qui est-ce ? » pour chaque
    // inconnu du quartier — c'est-à-dire à lui redonner le rôle d'annuaire que
    // toute cette conception lui retire.
    if (!_shortlist.contains(hex)) return;

    // ⚠️ **Un jeton JAMAIS entendu déclenche un dépôt immédiat.** C'est ce qui
    // garde la découverte à une quinzaine de secondes malgré une cadence de
    // rafraîchissement passée à 60 s : on ne fait attendre personne qui arrive.
    final nouveau = !_heardAt.containsKey(hex);
    _heard.add(hex);
    _heardAt[hex] = DateTime.now();

    // ⚠️ **Publié à chaque annonce, fidèlement.** C'est la règle de
    // dissociation : l'acquisition ne décide pas si l'écran doit se redessiner.
    // Le coût est absorbé en aval par l'égalité de valeur des vues dérivées —
    // même conception que `presence_feed.dart` pour les amis.
    _oublieLesVieux();
    ref.read(ecouteLocaleProvider.notifier).publish(Map.of(_heardAt));

    if (nouveau) unawaited(_flushHeard());
  }

  /// Jette ce qu'on n'a plus entendu depuis assez longtemps pour que ça ne
  /// serve plus à personne.
  ///
  /// ⚠️ **La borne est celle du dernier lecteur** — [kPingGraceServeur]. Au-delà,
  /// ni l'affichage ni la décision d'appeler le serveur ne s'en servent : garder
  /// l'entrée ne ferait que déclencher des appels pour un jeton dont plus rien
  /// ne dépend.
  void _oublieLesVieux() {
    final limite = DateTime.now().subtract(kPingGraceServeur);
    _heardAt.removeWhere((_, vu) => vu.isBefore(limite));
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

  /// Redemande la permission de localisation, puis reprend **tout de suite**.
  ///
  /// ⚠️ Sert aussi à demander la position *précise* quand seule
  /// l'approximative a été accordée : [CoarseLocation.request] redemande alors
  /// à Android, qui affiche sa boîte de mise à niveau.
  Future<void> requestPermission() async {
    final blocker = await ref.read(coarseLocationProvider).request();
    state = state.copyWith(blocker: blocker);
    // ⚠️ **On relance sans attendre le prochain tour de minuteur.** L'ancien
    // code appelait `_start()`, qui sort aussitôt si les minuteurs sont déjà
    // armés : la réponse de l'utilisateur serait restée sans effet visible
    // pendant une minute entière, ce qui se lit comme un refus.
    if (blocker == null) await _tick();
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Ce que l'acquisition du ping constate. **Des faits, pas un affichage.**
class PingBeaconState {
  const PingBeaconState({
    this.blocker,
    this.precision = LocationPrecision.precise,
    this.cell,
    this.listening = 0,
    this.listeningTruncated = false,
    this.confirmed = 0,
    this.lastError,
  });

  /// Ce qui empêche de lire une position, ou `null`.
  final LocationBlocker? blocker;

  /// La finesse réellement accordée. **Une dégradation, jamais un blocage** —
  /// voir [LocationPrecision].
  final LocationPrecision precision;

  /// Le carreau publié, pour le diagnostic.
  final String? cell;

  /// Combien de jetons on écoute en ce moment.
  final int listening;

  /// Vrai quand [listening] est un **plancher**, pas un total : le serveur
  /// a rendu tout ce qu'on lui demandait, il y en avait peut-être plus.
  final bool listeningTruncated;

  /// Combien de constats ont été retenus par le serveur depuis le démarrage.
  final int confirmed;

  /// La dernière panne, telle quelle. ⚠️ Jamais avalée : une liste vide et une
  /// panne réseau doivent rester distinguables.
  final String? lastError;

  PingBeaconState copyWith({
    LocationBlocker? blocker,
    LocationPrecision? precision,
    String? cell,
    int? listening,
    bool? listeningTruncated,
    int? confirmed,
    String? lastError,
  }) => PingBeaconState(
    blocker: blocker,
    precision: precision ?? this.precision,
    cell: cell ?? this.cell,
    listening: listening ?? this.listening,
    listeningTruncated: listeningTruncated ?? this.listeningTruncated,
    confirmed: confirmed ?? this.confirmed,
    lastError: lastError,
  );

  @override
  bool operator ==(Object other) =>
      other is PingBeaconState &&
      other.blocker == blocker &&
      other.precision == precision &&
      other.cell == cell &&
      other.listening == listening &&
      other.listeningTruncated == listeningTruncated &&
      other.confirmed == confirmed &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hash(
    blocker,
    precision,
    cell,
    listening,
    listeningTruncated,
    confirmed,
    lastError,
  );
}

final pingBeaconProvider = NotifierProvider<PingBeaconService, PingBeaconState>(
  PingBeaconService.new,
);
