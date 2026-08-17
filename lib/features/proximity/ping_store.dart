import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'proximity_identity.dart';

/// Stockage 100 % LOCAL du module ping (décision Jay 2026-07-13 :
/// séparation totale d'avec la messagerie d'amis — ces données ne touchent
/// JAMAIS le serveur).
///
/// - Conversations ping : un fichier JSON par pair, TTL **12 h** par
///   message (consigne Jay), purge au chargement et à l'écriture.
/// - Croisements : liste locale (profil du croisé + certificat co-signé).
/// - Outbox : ce qui doit remonter au serveur au retour d'internet
///   (croisements certifiés, demandes d'amis co-signées, waves).
class PingStore extends ChangeNotifierBase {
  PingStore();

  static const messageTtl = Duration(hours: 12);

  /// Règle anti-spam (côté RÉCEPTEUR, consigne Jay) : au-delà de 3 messages
  /// consécutifs sans réponse, les messages entrants sont refusés.
  ///
  /// ⚠️ **Ne s'applique qu'aux INCONNUS depuis le 2026-08-16.**
  ///
  /// Elle existe pour empêcher un inconnu croisé dans la rue de harceler
  /// quelqu'un qui ne lui répond pas. Entre **amis**, elle n'a aucun sens : ils
  /// ont déjà franchi la barrière que tout le produit sert à protéger, et une
  /// conversation normale comporte évidemment plusieurs messages d'affilée.
  ///
  /// Constaté par Jay au test : *« la limite se remet à chaque fois […] la
  /// discussion est déjà en cours et en plus ils sont amis […] maintenant les
  /// deux chats sont bloqués »*. Les deux appareils s'étaient enfermés — l'un
  /// refusait de recevoir, l'autre d'envoyer, et **plus rien ne pouvait les
  /// débloquer** puisque le déblocage exigeait précisément le message que la
  /// règle interdisait.
  static const unansweredLimit = 3;

  Directory? _dir;

  Future<Directory> _root() async {
    if (_dir != null) return _dir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}ping');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<File> _chatFile(String peerId) async =>
      File('${(await _root()).path}${Platform.pathSeparator}chat_$peerId.json');

  /// Efface TOUT le local du ping : conversations, croisements, file d'envoi.
  ///
  /// ⚠️ **Appelé au changement de compte.** Ces fichiers ne portent pas
  /// d'identifiant de propriétaire : sans effacement, le compte suivant
  /// hériterait des conversations et des croisements du précédent.
  Future<void> wipe() async {
    final dir = await _root();
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        if (entry is File) await entry.delete();
      }
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Conversations
  // ------------------------------------------------------------------

  Future<PingConversation?> conversation(String peerId) async {
    try {
      final file = await _chatFile(peerId);
      if (!await file.exists()) return null;
      final conv = PingConversation.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      final pruned = conv.pruned(messageTtl);
      if (pruned.messages.length != conv.messages.length) {
        await _write(pruned);
      }
      return pruned;
    } catch (_) {
      return null;
    }
  }

  Future<List<PingConversation>> conversations() async {
    final root = await _root();
    final result = <PingConversation>[];
    await for (final entity in root.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('chat_')) continue;
      final peerId = name.substring(5, name.length - 5);
      final conv = await conversation(peerId);
      if (conv != null && conv.messages.isNotEmpty) result.add(conv);
    }
    result.sort((a, b) => b.lastAt.compareTo(a.lastAt));
    return result;
  }

  /// Ajoute un message. Pour un message ENTRANT, applique la règle
  /// anti-spam : retourne false si le message est refusé (non stocké,
  /// jamais affiché — l'app émettrice modifiée peut envoyer, personne ne
  /// reçoit, consigne Jay).
  /// Range un message. Rend `false` si la règle anti-spam l'a refusé.
  ///
  /// ⚠️ **L'appelant DOIT regarder ce retour.** Un `false` ignoré, c'est un
  /// message détruit en silence — et c'est très exactement ce qui s'est passé
  /// le 2026-08-16 : `ProximityController` jetait la valeur, l'émetteur croyait
  /// avoir parlé, le destinataire ne voyait rien, et personne ne pouvait
  /// comprendre pourquoi.
  Future<bool> append(
    String peerId, {
    required PingPeerSnapshot peer,
    required PingMessage message,
    bool fromFriend = false,
  }) async {
    final existing =
        await conversation(peerId) ??
        PingConversation(peerId: peerId, peer: peer, messages: const []);
    // Les amis sont exemptés : la règle vise l'inconnu insistant, pas une
    // conversation en cours entre deux personnes qui se sont choisies.
    if (!message.mine && !fromFriend) {
      final unanswered = existing.unansweredIncoming;
      if (unanswered >= unansweredLimit) return false;
    }
    if (existing.messages.any((m) => m.id == message.id)) return true;
    final updated = existing
        .copyWith(peer: peer, messages: [...existing.messages, message])
        .pruned(messageTtl);
    await _write(updated);
    notifyListeners();
    return true;
  }

  Future<void> _write(PingConversation conv) async {
    final file = await _chatFile(conv.peerId);
    await file.writeAsString(jsonEncode(conv.toJson()));
  }

  /// Purge périodique globale (TTL 12 h) — appelée au démarrage du module.
  Future<void> sweep() async {
    final root = await _root();
    await for (final entity in root.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('chat_')) continue;
      final peerId = name.substring(5, name.length - 5);
      final conv = await conversation(peerId); // prune à la lecture
      if (conv == null || conv.messages.isEmpty) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Croisements locaux
  // ------------------------------------------------------------------

  Future<File> _encountersFile() async =>
      File('${(await _root()).path}${Platform.pathSeparator}encounters.json');

  Future<List<LocalEncounter>> encounters() async {
    try {
      final file = await _encountersFile();
      if (!await file.exists()) return [];
      final list = (jsonDecode(await file.readAsString()) as List)
          .map((e) => LocalEncounter.fromJson(e as Map<String, dynamic>))
          .toList();
      list.sort((a, b) => b.at.compareTo(a.at));
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<void> addEncounter(LocalEncounter encounter) async {
    final list = await encounters();
    list.removeWhere((e) => e.peer.userId == encounter.peer.userId);
    list.insert(0, encounter);
    final file = await _encountersFile();
    await file.writeAsString(jsonEncode(list.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Outbox serveur (au retour d'internet)
  // ------------------------------------------------------------------

  Future<File> _outboxFile() async =>
      File('${(await _root()).path}${Platform.pathSeparator}outbox.json');

  Future<List<Map<String, dynamic>>> outbox() async {
    try {
      final file = await _outboxFile();
      if (!await file.exists()) return [];
      return (jsonDecode(await file.readAsString()) as List)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> enqueue(Map<String, dynamic> item) async {
    final list = await outbox();
    list.add(item);
    await (await _outboxFile()).writeAsString(jsonEncode(list));
  }

  Future<void> replaceOutbox(List<Map<String, dynamic>> items) async {
    await (await _outboxFile()).writeAsString(jsonEncode(items));
  }
}

/// ChangeNotifier minimal sans dépendre de Flutter (testable en pur Dart).
class ChangeNotifierBase {
  final _listeners = <void Function()>[];
  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void notifyListeners() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }
}

class PingConversation {
  const PingConversation({
    required this.peerId,
    required this.peer,
    required this.messages,
  });

  final String peerId;
  final PingPeerSnapshot peer;
  final List<PingMessage> messages;

  DateTime get lastAt => messages.isEmpty
      ? DateTime.fromMillisecondsSinceEpoch(0)
      : messages.last.at;

  /// Messages entrants consécutifs sans réponse de ma part (anti-spam).
  int get unansweredIncoming {
    var count = 0;
    for (final m in messages.reversed) {
      if (m.mine) break;
      count++;
    }
    return count;
  }

  /// Mes messages consécutifs sans réponse du pair (blocage émetteur).
  int get unansweredOutgoing {
    var count = 0;
    for (final m in messages.reversed) {
      if (!m.mine) break;
      count++;
    }
    return count;
  }

  PingConversation pruned(Duration ttl) {
    final cutoff = DateTime.now().subtract(ttl);
    return copyWith(
      messages: messages.where((m) => m.at.isAfter(cutoff)).toList(),
    );
  }

  PingConversation copyWith({
    PingPeerSnapshot? peer,
    List<PingMessage>? messages,
  }) => PingConversation(
    peerId: peerId,
    peer: peer ?? this.peer,
    messages: messages ?? this.messages,
  );

  Map<String, dynamic> toJson() => {
    'peerId': peerId,
    'peer': peer.toJson(),
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory PingConversation.fromJson(Map<String, dynamic> json) =>
      PingConversation(
        peerId: json['peerId'] as String,
        peer: PingPeerSnapshot.fromJson(json['peer'] as Map<String, dynamic>),
        messages: (json['messages'] as List)
            .map((m) => PingMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}

/// Instantané du profil d'un pair, reçu en BLE (mini-profil).
class PingPeerSnapshot {
  const PingPeerSnapshot({
    required this.userId,
    required this.username,
    this.tagName,
    this.verified = false,
  });

  final String userId;
  final String username;
  final String? tagName;

  /// Identité vérifiée côté serveur (sinon « profil non vérifié » : hors
  /// ligne, rien n'empêche techniquement d'usurper un username — signalé à
  /// Jay, l'attestation serveur signée est une amélioration future).
  final bool verified;

  String get displayName =>
      (tagName != null && tagName!.isNotEmpty) ? tagName! : username;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    'tagName': tagName,
    'verified': verified,
  };

  factory PingPeerSnapshot.fromJson(Map<String, dynamic> json) =>
      PingPeerSnapshot(
        userId: json['userId'] as String,
        username: json['username'] as String,
        tagName: json['tagName'] as String?,
        verified: json['verified'] as bool? ?? false,
      );
}

class PingMessage {
  const PingMessage({
    required this.id,
    required this.mine,
    required this.text,
    required this.at,
  });

  final String id;
  final bool mine;
  final String text;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'id': id,
    'mine': mine,
    'text': text,
    'at': at.toIso8601String(),
  };

  factory PingMessage.fromJson(Map<String, dynamic> json) => PingMessage(
    id: json['id'] as String,
    mine: json['mine'] as bool,
    text: json['text'] as String,
    at: DateTime.parse(json['at'] as String),
  );
}

/// Croisement local : profil + certificat co-signé (10 s de contact
/// continu). Le certificat remonte au serveur via l'outbox.
class LocalEncounter {
  const LocalEncounter({
    required this.peer,
    required this.at,
    required this.certificate,
  });

  final PingPeerSnapshot peer;
  final DateTime at;
  final Map<String, dynamic> certificate;

  Map<String, dynamic> toJson() => {
    'peer': peer.toJson(),
    'at': at.toIso8601String(),
    'certificate': certificate,
  };

  factory LocalEncounter.fromJson(Map<String, dynamic> json) => LocalEncounter(
    peer: PingPeerSnapshot.fromJson(json['peer'] as Map<String, dynamic>),
    at: DateTime.parse(json['at'] as String),
    certificate: (json['certificate'] as Map).cast<String, dynamic>(),
  );
}

final pingStoreProvider = Provider((ref) => PingStore());

/// **LE** carnet d'amis de l'app. Un seul, et c'est tout l'intérêt.
///
/// ⚠️ **Ne jamais écrire `FriendKeyBook()` ailleurs que dans un test.**
///
/// Le 2026-08-17, trois instances coexistaient — contrôleur, synchronisation, et
/// le défaut de `PeerNetwork` — chacune avec son cache mémoire. La
/// synchronisation écrivait les clés téléchargées du serveur avec la sienne ;
/// les deux autres avaient déjà chargé le fichier et ne le relisaient jamais.
/// **Un ami s'affichait donc comme un inconnu**, avec un bouton « demander à se
/// connecter », jusqu'au prochain lancement de l'app.
///
/// Le cache n'était pas le défaut : le défaut était qu'un objet à état partagé
/// se construisait avec `new` à trois endroits. Un provider supprime la cause ;
/// une règle de relecture ne l'aurait qu'écartée.
final friendBookProvider = Provider<FriendKeyStore>((ref) => FriendKeyBook());

/// Suis-je ami avec cette personne ?
///
/// ⚠️ **Le seul endroit de l'app qui répond à cette question.**
///
/// Elle se **dérive** du carnet, elle ne se **recopie** nulle part. C'est la
/// différence qui a coûté la panne du 2026-08-17 : `PeerNetwork` calculait
/// `isFriend`, l'émettait dans `PeerIdentified`, et `markIdentified` ne le
/// rangeait pas dans l'entrée de présence — que le bouton lisait. La réponse
/// était juste, et personne ne la lisait au bon endroit.
///
/// La règle qui en sort, et qui rend le défaut impossible plutôt que corrigé :
/// **la présence dit OÙ et À QUELLE DISTANCE, jamais QUI.**
final isFriendProvider = StreamProvider.family<bool, String>((ref, userId) {
  final book = ref.watch(friendBookProvider);
  final controller = StreamController<bool>();

  Future<void> emit() async {
    if (controller.isClosed) return;
    controller.add((await book.all()).containsKey(userId));
  }

  book.changes.addListener(emit);
  ref.onDispose(() {
    book.changes.removeListener(emit);
    controller.close();
  });
  unawaited(emit());
  return controller.stream;
});
