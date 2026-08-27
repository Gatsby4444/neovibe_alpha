import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/supabase_providers.dart';
import '../ping_store.dart';
import '../proximity_identity.dart';
import 'advert_plan.dart';
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

  /// ⚠️ **L'identité vient du provider.** C'est ce superviseur qui démarre la
  /// radio, donc lui qui calcule l'ID diffusé ; avec sa propre instance, il
  /// pouvait au tout premier lancement diffuser une clé pendant que la synchro
  /// en publiait une autre au serveur — et nos amis ne nous reconnaissaient
  /// jamais.
  ProximityIdentity get _identity => ref.read(proximityIdentityProvider);

  /// ⚠️ **Le carnet vient du provider, jamais d'un `new` local.** Cinq
  /// instances coexistaient jadis, chacune avec son cache — le superviseur
  /// aurait planifié sur une liste d'amis différente de celle que le réseau
  /// utilise pour reconnaître. C'est le défaut déjà payé deux fois sur ce
  /// chantier (carnet le 2026-08-17, identité le 2026-08-18).
  FriendKeyStore get _keyBook => ref.read(friendBookProvider);

  /// Version de la table de reconnaissance actuellement déposée au natif.
  var _tableId = 0;

  /// La table déposée, **avec sa clé de lecture des rangs**.
  ///
  /// ⚠️ C'est la seule façon de savoir qui est le « rang 3 » d'un constat natif.
  /// Elle vit ici, à côté de l'envoi, et pas ailleurs : deux copies de cet ordre
  /// finiraient par diverger, et un constat serait alors attribué à la mauvaise
  /// personne — sans erreur, sans trace.
  NativeRecognitionTable? _recognition;

  /// Traduit un constat du natif en identifiant d'ami.
  ///
  /// Rend `null` si le constat vient d'une table périmée : on **jette** plutôt
  /// que d'attribuer au hasard. Un croisement faux vaut moins que pas de
  /// croisement.
  String? friendOfSighting(int tableId, int index) {
    final table = _recognition;
    if (table == null || table.tableId != tableId) return null;
    return table.friendAt(index);
  }

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
  /// Ouvre les réglages de LOCALISATION du système — pas ceux de l'app.
  ///
  /// ⚠️ **Aucune permission ne remplace cet interrupteur** : sur Android 10 et
  /// 11, c'est le service de localisation lui-même qu'il faut allumer pour
  /// qu'un scan BLE rende quoi que ce soit.
  ///
  /// ⚠️ **Vit ici depuis le 2026-08-27, et plus dans l'écran.** `PingScreen`
  /// construisait son propre `BleRadio()` pour l'appeler : un écran qui parle
  /// directement au natif, c'est-à-dire le client qui va en cuisine. Le
  /// superviseur **possède** la radio ; c'est à lui qu'on s'adresse, et il n'y a
  /// qu'un seul chemin vers le canal natif.
  Future<void> openLocationSettings() => _radio.openLocationSettings();

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
    // Le démarrage a besoin d'un identifiant tout de suite ; le plan complet
    // arrive juste après et prend le relais.
    await _radio.start(await _identity.currentPublicPingId());
    await refreshPlan();
    _rotation?.cancel();
    // ⚠️ **Ce minuteur ne pousse plus d'identifiant, il RENOUVELLE le plan.**
    //
    // C'est toute la différence avec l'ancien code : si ce minuteur ne tourne
    // pas — parce qu'Android a détruit l'activité — le natif continue d'émettre
    // juste pendant des heures. Avant, l'identifiant se figeait à la seconde où
    // le Dart mourait (audit du 2026-08-19, point H).
    //
    // Toutes les heures : le plan couvre 12 h, donc il faudrait rater douze
    // renouvellements d'affilée pour qu'il expire.
    _rotation = Timer.periodic(const Duration(hours: 1), (_) => refreshPlan());
  }

  /// Recalcule et redépose le plan d'émission.
  ///
  /// À appeler quand le carnet d'amis change (un ami ajouté ou **retiré** — sa
  /// révocation est immédiate et locale), quand le mode ping bascule, et
  /// régulièrement pour repousser l'horizon.
  Future<void> refreshPlan() async {
    if (!state.wantsVisible) return;
    final now = DateTime.now();
    _slot = ProximityIdentity.slotIndex(now);
    try {
      final friends = await _keyBook.all();
      final secrets = await _identity.pairSecrets({
        for (final f in friends.values) f.userId: f.x25519PublicKey,
      });

      // ⚠️ **Le mode ping est ce qui ajoute l'identifiant PUBLIC, et rien
      // d'autre.** Les jetons d'amis, eux, partent toujours : croiser un ami et
      // se rendre découvrable d'inconnus sont deux fonctions distinctes qui
      // partagent la même radio (consigne de Jay, 2026-08-20).
      // ⚠️ **Le jeton d'ami porte le nom de celui qui l'émet** depuis le
      // 2026-08-26 (voir [ProximityIdentity.pairToken]). Sans mon identifiant,
      // aucun jeton d'ami ne part — le planificateur le dit lui-même.
      final plan = await const AdvertPlanner().plan(
        secrets: secrets,
        fromSlot: _slot,
        slots:
            planHorizon.inMilliseconds ~/
            ProximityIdentity.slotDuration.inMilliseconds,
        meUserId: ref.read(currentUserIdProvider),
        pingSeed: _identity.pingSeed(),
      );

      if (plan.isEmpty) {
        // Aucun ami et pas de ping : rien à crier. On le dit plutôt que de
        // laisser une annonce périmée tourner.
        return;
      }

      final perSlot = plan.forSlot(_slot).length;
      final flat = Uint8List(
        plan.tokens.length * ProximityIdentity.tokenLength,
      );
      // ⚠️ **Le type descend avec le jeton, il ne se déduit pas en bas.**
      // `audience == null` désigne l'identifiant public du mode ping ; tout le
      // reste est le jeton privé d'un ami précis. C'est une règle produit, elle
      // vit ici et nulle part ailleurs (consigne de Jay, 2026-08-25).
      final types = Uint8List(plan.tokens.length);
      for (var i = 0; i < plan.tokens.length; i++) {
        flat.setRange(
          i * ProximityIdentity.tokenLength,
          (i + 1) * ProximityIdentity.tokenLength,
          plan.tokens[i].bytes,
        );
        types[i] = plan.tokens[i].audience == null ? 1 : 2;
      }

      await _radio.setAdvertPlan(
        tokens: flat,
        types: types,
        fromSlot: plan.fromSlot,
        slotMillis: ProximityIdentity.slotDuration.inMilliseconds,
        slotCount: plan.toSlot - plan.fromSlot + 1,
        perSlot: perSlot,
        tokenLength: ProximityIdentity.tokenLength,
      );

      // ⚠️ **Et la table de reconnaissance, sinon le natif diffuse en aveugle.**
      //
      // Le plan l'a rendu autonome pour ÉMETTRE ; sans table, il reste incapable
      // de VOIR. L'appareil serait alors vu sans voir — exactement le défaut
      // qu'on corrige. Les deux se déposent donc ensemble, toujours.
      if (secrets.isNotEmpty) {
        _tableId++;
        final table = await const AdvertPlanner().nativeTable(
          secrets: secrets,
          fromSlot: _slot,
          slots:
              planHorizon.inMilliseconds ~/
              ProximityIdentity.slotDuration.inMilliseconds,
          tableId: _tableId,
        );
        _recognition = table;
        await _radio.setRecognitionTable(
          tableId: table.tableId,
          tokens: table.tokens,
          fromSlot: table.fromSlot,
          slotMillis: ProximityIdentity.slotDuration.inMilliseconds,
          slotCount: table.slotCount,
          perSlot: table.perSlot,
          tokenLength: ProximityIdentity.tokenLength,
        );
      } else {
        _recognition = null;
      }
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
