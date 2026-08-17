import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../ping_store.dart';

/// Une demande d'ami reçue en proximité, **en attente de réponse**.
class PendingFriendRequest {
  const PendingFriendRequest({
    required this.fromUserId,
    required this.snapshot,
    required this.payload,
    required this.receivedAt,
  });

  final String fromUserId;
  final PingPeerSnapshot snapshot;

  /// La trame d'origine, conservée telle quelle : c'est elle qu'il faudra
  /// contresigner, et la recomposer de mémoire serait une occasion de
  /// divergence.
  final Map<String, dynamic> payload;

  final DateTime receivedAt;

  /// Au-delà, la demande est périmée. Une demande de proximité qui traîne
  /// plusieurs jours n'a plus de sens : la rencontre est passée.
  static const ttl = Duration(hours: 24);

  bool get isExpired => DateTime.now().difference(receivedAt) > ttl;

  Map<String, dynamic> toJson() => {
    'fromUserId': fromUserId,
    'snapshot': {
      'userId': snapshot.userId,
      'username': snapshot.username,
      'tagName': snapshot.tagName,
    },
    'payload': payload,
    'receivedAt': receivedAt.toUtc().toIso8601String(),
  };

  factory PendingFriendRequest.fromJson(Map<String, dynamic> json) {
    final snap = (json['snapshot'] as Map).cast<String, dynamic>();
    return PendingFriendRequest(
      fromUserId: json['fromUserId'] as String,
      snapshot: PingPeerSnapshot(
        userId: snap['userId'] as String,
        username: snap['username'] as String,
        tagName: snap['tagName'] as String?,
        verified: true,
      ),
      payload: (json['payload'] as Map).cast<String, dynamic>(),
      receivedAt: DateTime.parse(json['receivedAt'] as String).toLocal(),
    );
  }
}

/// Une demande d'ami **que NOUS avons envoyée**, et où elle en est.
///
/// ⚠️ **Rien ne la retenait avant le 2026-08-17, et ça se voyait.** Jay a
/// cliqué plusieurs fois sur « demander à se connecter » et lu « Demande
/// envoyée » à chaque fois : l'app n'avait aucun moyen de savoir qu'elle venait
/// déjà de le faire, ni de le lui dire.
///
/// Pire, le **refus** n'aboutissait nulle part. À la réception d'un
/// `FriendDeclineMessage`, le code retirait une demande **entrante** — le
/// mauvais magasin. Celui qui avait demandé n'apprenait donc jamais qu'on lui
/// avait dit non, et si le pair lui avait *aussi* écrit, c'est sa demande à lui
/// qui disparaissait.
///
/// Une action doit aboutir à un état **nommé**. Il y en a trois ici, et pas un
/// de plus : envoyée, refusée, (acceptée → l'entrée disparaît, on est amis).
class OutgoingFriendRequest {
  const OutgoingFriendRequest({
    required this.toUserId,
    required this.snapshot,
    required this.sentAt,
    this.declinedAt,
  });

  final String toUserId;
  final PingPeerSnapshot snapshot;
  final DateTime sentAt;

  /// Non nul si le pair a dit non. L'entrée reste, pour que l'utilisateur le
  /// **voie** — une demande qui disparaît sans un mot est indiscernable d'une
  /// demande perdue.
  final DateTime? declinedAt;

  bool get isDeclined => declinedAt != null;

  /// Même durée que les demandes entrantes : au-delà, la rencontre est passée.
  static const ttl = Duration(hours: 24);

  bool get isExpired => DateTime.now().difference(declinedAt ?? sentAt) > ttl;

  OutgoingFriendRequest declined() => OutgoingFriendRequest(
    toUserId: toUserId,
    snapshot: snapshot,
    sentAt: sentAt,
    declinedAt: DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'toUserId': toUserId,
    'snapshot': {
      'userId': snapshot.userId,
      'username': snapshot.username,
      'tagName': snapshot.tagName,
    },
    'sentAt': sentAt.toUtc().toIso8601String(),
    'declinedAt': declinedAt?.toUtc().toIso8601String(),
  };

  factory OutgoingFriendRequest.fromJson(Map<String, dynamic> json) {
    final snap = (json['snapshot'] as Map).cast<String, dynamic>();
    final declined = json['declinedAt'] as String?;
    return OutgoingFriendRequest(
      toUserId: json['toUserId'] as String,
      snapshot: PingPeerSnapshot(
        userId: snap['userId'] as String,
        username: snap['username'] as String,
        tagName: snap['tagName'] as String?,
        verified: true,
      ),
      sentAt: DateTime.parse(json['sentAt'] as String).toLocal(),
      declinedAt: declined == null ? null : DateTime.parse(declined).toLocal(),
    );
  }
}

/// Ce que la proximité doit retenir **entre deux lancements de l'app**.
///
/// ## Les deux défauts que ce fichier supprime
///
/// **1. Une demande d'ami n'existait qu'en mémoire, et à un seul exemplaire.**
/// `state.incomingFriendRequest` était un emplacement unique : une deuxième
/// demande écrasait la première sans laisser de trace, et fermer l'app les
/// perdait toutes. Pire, accepter alors que le lien BLE était tombé effaçait la
/// demande **et ne faisait rien** — sans copie serveur, elle était
/// irrécupérable (défauts A3 et B2 du diagnostic).
///
/// **2. Le cooldown des waves vivait en mémoire.** Redémarrer l'app remettait à
/// zéro la fenêtre de 2 h : la notification « le presque » pouvait repartir à
/// chaque relance, pour la même personne (défaut C4).
class ProximityJournal {
  ProximityJournal({Directory? directory}) : _override = directory;

  final Directory? _override;
  Directory? _root;

  Future<Directory> _dir() async {
    final existing = _root;
    if (existing != null) return existing;
    final base =
        _override ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}ping',
        );
    if (!await base.exists()) await base.create(recursive: true);
    return _root = base;
  }

  Future<File> _file(String name) async =>
      File('${(await _dir()).path}${Platform.pathSeparator}$name');

  // ----------------------------------------------------- demandes en attente

  List<PendingFriendRequest>? _requests;

  Future<List<PendingFriendRequest>> pendingRequests() async {
    final cached = _requests;
    if (cached != null) return cached;
    try {
      final file = await _file('pending_requests.json');
      if (!await file.exists()) return _requests = [];
      final raw = jsonDecode(await file.readAsString()) as List;
      final all = raw
          .map((e) => PendingFriendRequest.fromJson((e as Map).cast()))
          .where((r) => !r.isExpired)
          .toList();
      return _requests = all;
    } catch (_) {
      return _requests = [];
    }
  }

  /// Ajoute ou remplace la demande de cet émetteur.
  ///
  /// Une seule demande **par personne** : renvoyer sa demande n'en crée pas une
  /// deuxième, mais rafraîchit la première. Plusieurs personnes peuvent en
  /// revanche demander en même temps — c'est exactement le cas d'un groupe, et
  /// c'est le cas d'usage du produit.
  Future<void> putRequest(PendingFriendRequest request) async {
    final all = await pendingRequests();
    all.removeWhere((r) => r.fromUserId == request.fromUserId);
    all.add(request);
    await _saveRequests(all);
  }

  Future<void> removeRequest(String fromUserId) async {
    final all = await pendingRequests();
    if (all.any((r) => r.fromUserId == fromUserId)) {
      all.removeWhere((r) => r.fromUserId == fromUserId);
      await _saveRequests(all);
    }
  }

  Future<void> _saveRequests(List<PendingFriendRequest> all) async {
    _requests = all;
    final file = await _file('pending_requests.json');
    await file.writeAsString(jsonEncode(all.map((r) => r.toJson()).toList()));
  }

  // ------------------------------------------------------ demandes SORTANTES

  List<OutgoingFriendRequest>? _outgoing;

  Future<List<OutgoingFriendRequest>> outgoingRequests() async {
    final cached = _outgoing;
    if (cached != null) return cached;
    try {
      final file = await _file('outgoing_requests.json');
      if (!await file.exists()) return _outgoing = [];
      final raw = jsonDecode(await file.readAsString()) as List;
      return _outgoing = raw
          .map((e) => OutgoingFriendRequest.fromJson((e as Map).cast()))
          .where((r) => !r.isExpired)
          .toList();
    } catch (_) {
      return _outgoing = [];
    }
  }

  /// L'état de notre demande vers [userId], ou `null` si nous n'en avons pas.
  Future<OutgoingFriendRequest?> outgoingTo(String userId) async {
    for (final r in await outgoingRequests()) {
      if (r.toUserId == userId) return r;
    }
    return null;
  }

  /// Une seule demande **par personne** : redemander remplace, il ne double pas.
  Future<void> putOutgoing(OutgoingFriendRequest request) async {
    final all = await outgoingRequests();
    all.removeWhere((r) => r.toUserId == request.toUserId);
    all.add(request);
    await _saveOutgoing(all);
  }

  /// Marque notre demande comme **refusée**. Rend vrai si elle existait.
  ///
  /// ⚠️ On ne la supprime pas : l'utilisateur doit pouvoir **voir** qu'on lui a
  /// dit non. Une demande qui s'efface toute seule est indiscernable d'une
  /// demande perdue — et c'est exactement ce que faisait l'ancien code.
  Future<bool> markOutgoingDeclined(String userId) async {
    final all = await outgoingRequests();
    final i = all.indexWhere((r) => r.toUserId == userId);
    if (i < 0) return false;
    all[i] = all[i].declined();
    await _saveOutgoing(all);
    return true;
  }

  Future<void> removeOutgoing(String userId) async {
    final all = await outgoingRequests();
    if (all.any((r) => r.toUserId == userId)) {
      all.removeWhere((r) => r.toUserId == userId);
      await _saveOutgoing(all);
    }
  }

  Future<void> _saveOutgoing(List<OutgoingFriendRequest> all) async {
    _outgoing = all;
    final file = await _file('outgoing_requests.json');
    await file.writeAsString(jsonEncode(all.map((r) => r.toJson()).toList()));
  }

  // ------------------------------------------------------- cooldown des waves

  Map<String, DateTime>? _waves;

  Future<Map<String, DateTime>> _waveMap() async {
    final cached = _waves;
    if (cached != null) return cached;
    try {
      final file = await _file('wave_cooldown.json');
      if (!await file.exists()) return _waves = {};
      final raw = (jsonDecode(await file.readAsString()) as Map)
          .cast<String, dynamic>();
      return _waves = raw.map(
        (k, v) => MapEntry(k, DateTime.parse(v as String)),
      );
    } catch (_) {
      return _waves = {};
    }
  }

  /// Vrai si l'on peut envoyer un wave à [userId] maintenant.
  Future<bool> mayWave(String userId, Duration cooldown) async {
    final map = await _waveMap();
    final last = map[userId];
    return last == null || DateTime.now().difference(last) >= cooldown;
  }

  Future<void> noteWave(String userId) async {
    final map = await _waveMap();
    map[userId] = DateTime.now();
    _waves = map;
    final file = await _file('wave_cooldown.json');
    await file.writeAsString(
      jsonEncode(map.map((k, v) => MapEntry(k, v.toUtc().toIso8601String()))),
    );
  }

  /// Oublie tout — bascule de compte, ou remise à zéro depuis les réglages.
  Future<void> clear() async {
    _requests = null;
    _outgoing = null;
    _waves = null;
    for (final name in [
      'pending_requests.json',
      'outgoing_requests.json',
      'wave_cooldown.json',
    ]) {
      final file = await _file(name);
      if (await file.exists()) await file.delete();
    }
  }
}
