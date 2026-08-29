import 'dart:async';
import 'dart:math';
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
///
/// ## 🔴 DEUX intentions depuis le 2026-08-28, et il en manquait une
///
/// Il n'y avait qu'un booléen, `wantsVisible`, et `setVisible(false)` appelait
/// `_radio.stop()` : **couper « Visible à proximité » coupait aussi le
/// croisement de ses amis.**
///
/// ⚠️ **Le code affirmait pourtant le contraire à trois endroits** — *« les
/// jetons d'amis, eux, partent toujours »*, *« deux fonctions distinctes qui
/// partagent la même radio »*, et le contrat de `AdvertPlanner.plan` qui prévoit
/// une graine publique **nulle**. La séparation avait été **conçue** ; elle
/// n'avait jamais été **branchée**, et les commentaires décrivaient l'intention
/// au lieu du code.
///
/// ⚠️ **Ce que ça coûtait à l'utilisateur** : refuser d'être découvrable par des
/// inconnus — le réglage le plus naturel qui soit — lui faisait perdre ses
/// croisements d'amis, donc ses streaks et ses « presque ». Alors que le
/// croisement d'amis marche **app fermée** et ne demande **aucune permission de
/// localisation** sur Android 12+.
///
/// Décision de Jay, 2026-08-28 : *« il est temps de vraiment tout séparer, on
/// met un autre interrupteur juste pour les amis »*.
class ProximityRuntime {
  const ProximityRuntime({
    required this.wantsFriends,
    required this.wantsDiscovery,
    required this.status,
    this.intentLoaded = false,
  });

  /// **Croiser mes amis.** Réglage de `Sécurité et confidentialité`.
  ///
  /// N'exige aucune permission de localisation sur Android 12+, ne publie
  /// aucune balise au serveur, et fonctionne app fermée. C'est le cœur du
  /// produit : les streaks et le « presque » en dépendent.
  final bool wantsFriends;

  /// **Être visible des inconnus.** L'interrupteur de l'écran Ping.
  ///
  /// C'est lui, et lui seul, qui ajoute l'identifiant PUBLIC au plan d'émission
  /// et qui fait publier une balise au serveur.
  final bool wantsDiscovery;

  /// Ce que la radio fait réellement, publié par le natif.
  final RadioStatus status;

  /// Faux pendant les quelques millisecondes de lecture des préférences.
  /// Sans lui, l'interrupteur s'afficherait éteint puis sauterait — et un
  /// utilisateur qui le voit sauter le rebascule, donc coupe sa visibilité.
  final bool intentLoaded;

  /// **La radio doit-elle tourner ?** L'une OU l'autre suffit.
  ///
  /// ⚠️ C'est la seule question que la radio a le droit de poser : elle ne sait
  /// pas *pourquoi* on l'allume, et elle n'a pas à le savoir. Ce qui distingue
  /// les deux modes vit dans le **plan** (avec ou sans identifiant public), pas
  /// dans le démarrage.
  bool get radioNeeded => wantsFriends || wantsDiscovery;

  /// Vrai quand la DÉCOUVERTE marche : l'utilisateur veut être visible des
  /// inconnus **et** la radio scanne. C'est la seule condition sous laquelle
  /// « personne à proximité » veut dire « personne ».
  bool get isLive => wantsDiscovery && status.isDetecting;

  ProximityRuntime copyWith({
    bool? wantsFriends,
    bool? wantsDiscovery,
    RadioStatus? status,
    bool? intentLoaded,
  }) => ProximityRuntime(
    wantsFriends: wantsFriends ?? this.wantsFriends,
    wantsDiscovery: wantsDiscovery ?? this.wantsDiscovery,
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
  /// L'intention « visible des inconnus ». Nom historique conservé : le
  /// renommer ferait repartir tout le monde à zéro sans rien gagner.
  static const prefsKey = 'proximity_visible';

  /// L'intention « croiser mes amis », ajoutée le 2026-08-28.
  static const prefsKeyFriends = 'proximity_friends';

  BleRadio get _radio => ref.read(bleRadioProvider);

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

  /// Vrai pendant qu'un plan se calcule. **Deux sources peuvent demander en
  /// même temps** — le carnet qui change et le minuteur horaire — et un plan
  /// coûte 48 créneaux de HMAC par ami : les laisser se superposer paierait le
  /// calcul deux fois pour un résultat identique.
  bool _planEnCours = false;

  /// Une demande arrivée pendant qu'un plan se calculait. On la rejoue **une
  /// fois** à la fin : la dernière demande gagne, et elle n'est jamais perdue.
  bool _planADemander = false;

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
    _ecouteLesSourcesDuPlan();
    _restore();
    return const ProximityRuntime(
      wantsFriends: false,
      wantsDiscovery: false,
      status: RadioIdle(),
    );
  }

  /// **Le plan d'émission suit ses sources.**
  ///
  /// ## 🔴 Le défaut que ceci corrige — relevé à l'audit du 2026-08-28
  ///
  /// [refreshPlan] n'avait que **deux** déclencheurs : `_engage()` et un
  /// minuteur d'une heure. **Rien n'écoutait le carnet d'amis.** Or tous les
  /// jetons émis viennent du plan : accepter un ami ne le faisait donc entrer
  /// ni dans ce qu'on crie, ni dans la table de reconnaissance déposée au
  /// natif, **pendant jusqu'à une heure — et des deux côtés**. Aucune distance,
  /// aucun constat, aucun croisement, sans qu'une seule erreur soit levée.
  ///
  /// Le contournement trouvé par Jay disait exactement cela : *« j'ai désactivé
  /// et réactivé le ping sur chaque appareil et là ça remarche »* — rebasculer
  /// l'interrupteur appelle `_engage()`.
  ///
  /// ⚠️ **Deux sources, deux abonnements, aucun `watch` sur ce notifieur.**
  /// Surveiller l'identifiant de compte dans `build()` ré-exécuterait tout le
  /// superviseur — donc rouvrirait le flux natif et relirait les préférences —
  /// pour une donnée dont seul le plan dépend. `ref.listen` observe sans
  /// reconstruire : le consommateur choisit ce qui l'intéresse, l'acquisition
  /// n'en sait rien.
  void _ecouteLesSourcesDuPlan() {
    final carnet = ref.read(friendBookProvider);
    carnet.changes.addListener(_replanifier);
    ref.onDispose(() => carnet.changes.removeListener(_replanifier));

    // ⚠️ **Le compte fait partie du plan** : un jeton d'ami porte le nom de
    // celui qui l'émet (`ProximityIdentity.pairToken`). Tant qu'il est nul,
    // `AdvertPlanner.plan` n'émet aucun jeton d'ami — donc se connecter après
    // le démarrage de la radio laissait l'appareil muet pour ses amis.
    ref.listen(currentUserIdProvider, (_, _) => _replanifier());
  }

  void _replanifier() => unawaited(refreshPlan());

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
    final decouverte = prefs.getBool(prefsKey);
    // ⚠️ **La migration du 2026-08-28, en une ligne.**
    //
    // - Réglage déjà posé → on le reprend tel quel : personne ne se retrouve à
    //   émettre quelque chose qu'il n'avait pas demandé.
    // - Aucune trace → nouvelle installation → **allumé**, parce que le
    //   croisement d'amis est le cœur du produit, qu'il ne demande aucune
    //   permission de localisation et qu'il n'émet que des jetons illisibles
    //   par quiconque n'est pas déjà votre ami.
    final amis = prefs.getBool(prefsKeyFriends) ?? decouverte ?? true;
    state = state.copyWith(
      wantsFriends: amis,
      wantsDiscovery: decouverte ?? false,
      intentLoaded: true,
    );
    if (!state.radioNeeded) {
      state = state.copyWith(status: await _radio.probe());
      return;
    }
    await _engage();
  }

  /// **Être visible des inconnus.** Interrupteur de l'écran Ping.
  Future<void> setDiscovery(bool wanted) async {
    if (state.wantsDiscovery == wanted && state.intentLoaded) return;
    state = state.copyWith(wantsDiscovery: wanted, intentLoaded: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, wanted);
    await _appliquerIntention();
  }

  /// **Croiser mes amis.** Réglage de `Sécurité et confidentialité`.
  Future<void> setFriendCrossing(bool wanted) async {
    if (state.wantsFriends == wanted && state.intentLoaded) return;
    state = state.copyWith(wantsFriends: wanted, intentLoaded: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKeyFriends, wanted);
    await _appliquerIntention();
  }

  /// **Un seul endroit décide d'allumer ou d'éteindre la radio.**
  ///
  /// ⚠️ **C'est ce qui empêche le défaut de revenir.** Tant que chaque
  /// interrupteur appelait lui-même `stop()`, il suffisait qu'un des deux
  /// oublie de regarder l'autre pour couper une fonction qu'il ne commande pas.
  /// Ici la question est posée une fois : *quelqu'un a-t-il encore besoin de la
  /// radio ?*
  ///
  /// ⚠️ **Et on redépose TOUJOURS le plan**, même si la radio tournait déjà :
  /// changer d'intention change ce qu'on doit crier — l'identifiant public
  /// entre ou sort du plan. Ne redémarrer que la radio laisserait l'ancien plan
  /// en place, donc continuerait de crier l'identifiant public d'un mode qu'on
  /// vient d'éteindre.
  Future<void> _appliquerIntention() async {
    if (state.radioNeeded) {
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
    if (!state.radioNeeded) return;
    await _engage();
  }

  /// Démarre la radio — **et rien d'autre**.
  ///
  /// ⚠️ **Séparé du dépôt du plan le 2026-08-28, et c'est ce qui supprime la
  /// récursion.** Le `catch` du dépôt appelait `_engage()`, qui rappelle le
  /// dépôt : un échec reproductible bouclait sans borne. La reprise a besoin de
  /// **relancer la radio**, pas de rejouer tout l'engagement — les deux gestes
  /// étaient collés dans une seule méthode, donc l'un ne pouvait pas se faire
  /// sans l'autre.
  Future<void> _demarreRadio() async {
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
    //
    // ## 🔴 Ce qui était faux jusqu'au 2026-08-28
    //
    // On passait `currentPublicPingId()` **sans condition** — donc quelqu'un
    // qui veut seulement croiser ses amis criait quand même son identifiant
    // **public de découverte** à chaque démarrage de radio.
    //
    // ⚠️ **La fenêtre n'est courte que si tout va bien.** Si le dépôt du plan
    // échoue deux fois (`_deposeOuRetablit`), l'appareil reste sur cette valeur
    // **indéfiniment** — donc il crie l'identifiant d'un mode que l'utilisateur
    // a explicitement refusé.
    //
    // ⚠️ **Et ce n'est pas anodin même quand ça se passe bien** : cette valeur
    // est celle qui deviendrait résoluble si l'utilisateur activait la
    // découverte plus tard dans la même session. Un observateur qui l'a notée
    // pourrait relier les deux moments. Une **amorce au hasard** ne se relie à
    // rien et remplit exactement le même rôle.
    await _radio.start(
      state.wantsDiscovery
          ? await _identity.currentPublicPingId()
          : _amorceAnonyme(),
    );
  }

  /// Une valeur de démarrage qui ne veut **rien dire**, et c'est son rôle.
  ///
  /// Le natif exige un identifiant pour démarrer ; le plan le remplace dans la
  /// foulée. Quand la découverte est éteinte, il n'y a aucun identifiant
  /// légitime à donner — donc on en donne un qui n'appartient à personne.
  Uint8List _amorceAnonyme() {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List.generate(ProximityIdentity.tokenLength, (_) => rnd.nextInt(256)),
    );
  }

  Future<void> _engage() async {
    await _demarreRadio();
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
    if (!state.radioNeeded) return;
    if (_planEnCours) {
      _planADemander = true;
      return;
    }
    _planEnCours = true;
    try {
      await _deposeOuRetablit();
    } finally {
      _planEnCours = false;
    }
    // Une source a bougé pendant le calcul : on rejoue **une** fois, la
    // dernière demande gagne.
    if (_planADemander) {
      _planADemander = false;
      await refreshPlan();
    }
  }

  /// Dépose le plan, et **si le service a disparu, relance la radio une fois**.
  ///
  /// ## ⚠️ Ce qui remplace la récursion du 2026-08-28
  ///
  /// Le `catch` appelait `_engage()`, qui rappelle [refreshPlan] : deux
  /// méthodes qui s'appellent l'une l'autre, **sans borne ni délai**, chacune
  /// recalculant 48 créneaux de HMAC par ami. Un service définitivement absent
  /// faisait tourner cette boucle indéfiniment, sans qu'aucune erreur ne soit
  /// levée ni affichée.
  ///
  /// Ici la reprise est **linéaire et bornée** : on relance la radio, on
  /// **retente une fois**, et si ça échoue encore on le **dit**. Il n'y a plus
  /// de cycle à interrompre — la cause est supprimée, pas surveillée.
  Future<void> _deposeOuRetablit() async {
    try {
      await _deposePlan();
      return;
    } catch (premiere) {
      if (!state.radioNeeded) return;
      // ⚠️ **L'échec dit quelque chose : le service n'est plus là.** Une
      // première version l'ignorait — l'app restait « active » sans plus aucune
      // radio, et personne ne l'aurait su avant le prochain lancement.
      try {
        await _demarreRadio();
        await _deposePlan();
        return;
      } catch (seconde) {
        state = state.copyWith(
          status: RadioFailed(
            'plan',
            "Le plan d'émission n'a pas pu être déposé : $seconde",
          ),
        );
        return;
      }
    }
  }

  /// Calcule le plan et le dépose. **Laisse remonter ce qui échoue.**
  ///
  /// ⚠️ **Aucun `catch` ici, et c'est délibéré** (2026-08-28). La politique de
  /// reprise vit dans [_deposeOuRetablit], le seul endroit qui sache combien de
  /// fois on a déjà essayé. En rattraper une part ici ferait deux politiques
  /// pour une seule panne — et c'est de ce mélange qu'était née la récursion.
  Future<void> _deposePlan() async {
    final now = DateTime.now();
    _slot = ProximityIdentity.slotIndex(now);
    final friends = await _keyBook.all();

    // 🔴 **LA MOITIÉ QUI MANQUAIT À LA SÉPARATION — relevée par Jay sur
    // appareil le 2026-08-29.**
    //
    // Ces secrets alimentent **les deux moitiés du croisement d'amis** : les
    // jetons qu'on CRIE (plus bas, dans le plan) et la table qui permet de
    // RECONNAÎTRE (tout en bas). Ils descendaient **sans condition**.
    //
    // Conséquence, constatée à deux appareils : le téléphone de Charles, dont
    // « Croiser mes amis » était **éteint**, criait quand même ses jetons
    // d'ami — et la tablette de mimi l'affichait. L'interrupteur ne cachait
    // Charles qu'à **lui-même** : l'écran masquait la liste (`ping_screen.dart`)
    // pendant que la radio continuait d'annoncer sa présence à ses amis.
    //
    // ⚠️ **Le commentaire qui vivait ici disait « les jetons d'amis, eux,
    // partent toujours », et il était juste le jour où il a été écrit**
    // (2026-08-20) : il n'y avait alors **qu'un** interrupteur, et « toujours »
    // voulait dire « tant que la radio tourne ». Le second interrupteur, né le
    // 2026-08-28, a périmé sa prémisse sans le contredire : cohérent, argumenté,
    // et faux.
    //
    // ⚠️ **Une table VIDE part quand même** (voir plus bas) : « je ne
    // reconnais plus personne » doit s'ENVOYER, sinon le natif garde l'ancienne.
    final secrets = state.wantsFriends
        ? await _identity.pairSecrets({
            for (final f in friends.values) f.userId: f.x25519PublicKey,
          })
        : const <String, Uint8List>{};

    // ⚠️ **Un interrupteur, une ligne, et les deux se lisent ensemble.**
    // `secrets` ci-dessus commande la moitié AMIS, `pingSeed` ci-dessous la
    // moitié INCONNUS. Toute règle posée sur l'une doit avoir sa jumelle sur
    // l'autre — c'est l'absence de cette symétrie qui a laissé passer le défaut
    // du 2026-08-29.
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
      // ⚠️ **C'est ICI que les deux modes deviennent réellement distincts.**
      // La graine ne descend que si l'utilisateur veut être découvrable. Le
      // planificateur prévoyait ce cas depuis le 2026-08-20 ; on lui passait la
      // graine sans condition, donc l'identifiant public partait même quand
      // seul le croisement d'amis était demandé.
      pingSeed: state.wantsDiscovery ? _identity.pingSeed() : null,
    );

    // ⚠️ **Un plan vide est possible depuis le 2026-08-28** : découverte
    // éteinte et carnet d'amis vide. Il n'y a alors rien à crier, et déposer un
    // plan sans jeton ferait taire la radio de toute façon — on le laisse
    // passer, le natif se tait tout seul (`AdvertSchedule.isEmpty`).
    final perSlot = plan.forSlot(_slot).length;
    final flat = Uint8List(plan.tokens.length * ProximityIdentity.tokenLength);
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
    //
    // ## 🔴 « Toujours » était faux, et le test de la v0.9.146 l'a chiffré
    //
    // Ce bloc était enfermé dans `if (secrets.isNotEmpty)`. Quand le **dernier
    // ami** disparaissait du carnet, le Dart mettait `_recognition = null` et
    // **ne disait rien au natif** : celui-ci gardait la table précédente,
    // continuait de reconnaître l'ex-ami, et remontait un constat toutes les
    // deux secondes que le Dart jetait un par un — faute de table pour le lire.
    //
    // Relevé sur les deux appareils : **318 et 485 incidents** en une demi-heure.
    //
    // ⚠️ **Le pire n'est pas le gaspillage, c'est l'aveuglement.** Le journal
    // d'incidents est un anneau de 200 entrées : ces rejets, à 30 par minute,
    // **chassaient du rapport tout ce qui aurait pu s'y trouver d'utile**.
    // L'instrument de diagnostic était saturé par un seul défaut.
    //
    // ⚠️ **Une table VIDE se dépose, elle ne se déduit pas.** Ne rien envoyer
    // laisse le natif sur son ancienne table — « je n'ai plus d'amis » et « je
    // ne t'ai rien dit » sont deux messages différents, et le silence était lu
    // comme le second.
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
  }
}

final proximitySupervisorProvider =
    NotifierProvider<ProximitySupervisor, ProximityRuntime>(
      ProximitySupervisor.new,
    );
