import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Identité cryptographique locale du ping.
///
/// - ~~**Clé d'appareil Ed25519**~~ : retirée le 2026-08-27. Elle signait les
///   certificats de croisement, les
///   demandes d'amis co-signées, la poignée de main et le mini-profil. Le seed
///   vit dans le Keystore Android.
/// - **Clé X25519** : elle ne sert jamais à chiffrer directement. Elle sert à
///   DÉRIVER, avec chaque ami, un secret propre à la paire :
///
///       S_AB = X25519(ma privée, sa publique) = X25519(sa privée, ma publique)
///
///   Les deux appareils obtiennent le même secret **sans que le secret ne
///   circule jamais**. Le serveur ne transporte que des clés publiques.
///
/// ## ⚠️ Ce qui a disparu le 2026-08-20, et pourquoi (décision de Jay)
///
/// Il y avait ici une **clé de diffusion** : un secret unique, partagé avec
/// **tous** les amis à la fois, qui engendrait l'ID rotatif diffusé en BLE.
/// Tout le reste en découlait mécaniquement — il fallait la distribuer (serveur
/// + synchronisation), la remplacer quand un ami partait (rotation), et
/// attendre que tout le monde l'apprenne (**le trou**).
///
/// Trois défauts en sont nés : le trou de 7 jours, une `broadcast_key_prev` qui
/// ne changeait **aucun** résultat de reconnaissance (audit du 2026-08-18,
/// point A), et une révocation qui aveuglait tous les autres amis.
///
/// Un secret par paire supprime la cause : il n'y a plus rien à distribuer,
/// donc plus rien à rater. Retirer un ami devient une opération **locale** —
/// on efface son secret, on cesse d'émettre son jeton — sans effet sur
/// personne d'autre.
///
/// ## ⚠️ Deux défauts corrigés le 2026-08-18
///
/// **1. Cinq instances, cinq caches, et une course au premier lancement.**
/// Cette classe se construisait avec `new` dans le superviseur, le contrôleur,
/// la synchro, `PeerNetwork` et **chaque canal chiffré**. `_ensureLoaded`
/// n'avait aucun verrou : au tout premier démarrage, deux instances lancées en
/// parallèle ne trouvaient rien en stockage, **généraient chacune leur clé** et
/// l'écrivaient toutes les deux. On pouvait donc diffuser un ID dérivé de la
/// clé A pendant que le serveur recevait la clé B — nos amis ne nous
/// reconnaissaient jamais — ou signer la poignée de main avec une clé
/// d'appareil et le profil avec une autre, ce qui fait échouer
/// `isPeerDeviceKey` et renvoie « profil non authentifié ». Intermittent,
/// uniquement au premier lancement, indiscernable d'un vrai refus.
///
/// C'est **exactement** le défaut déjà corrigé pour le carnet d'amis le
/// 2026-08-17 ; le raisonnement n'avait simplement jamais été appliqué à
/// l'identité elle-même. D'où [proximityIdentityProvider] et le verrou de
/// [_ensureLoaded].
///
/// **2. La clé de diffusion ne tournait JAMAIS.** Défaut réel, corrigé le
/// 2026-08-18 par une rotation de 7 jours — puis rendu **sans objet** le
/// 2026-08-20 : il n'y a plus de secret partagé à faire tourner.
class ProximityIdentity {
  ProximityIdentity();

  static const _storage = FlutterSecureStorage();

  /// ⚠️ **Vestige.** La clé de signature Ed25519 a été retirée le 2026-08-27 :
  /// ce qu'elle signait voyageait par la radio, et la radio ne transporte plus
  /// rien. Sa graine reste listée ici pour être **effacée** du Keystore — un
  /// secret orphelin reste un secret. Voir [_deadKeys].
  static const _seedKey = 'nv_ed25519_seed';

  /// Graine de la clé X25519 (secret par paire).
  static const _x25519Key = 'nv_x25519_seed';

  /// ⚠️ **Vestiges de la clé de diffusion, effacés au chargement.**
  /// Ce ne sont plus des clés, ce sont des secrets orphelins : les laisser dans
  /// le Keystore, c'est garder un secret que plus rien ne protège ni ne fait
  /// tourner. On les supprime, on ne se contente pas de les ignorer.
  /// Les secrets que plus rien n'utilise, et qu'on **efface** au lieu de les
  /// ignorer.
  ///
  /// ⚠️ **Ignorer un secret n'est pas le supprimer.** Une graine qui dort dans
  /// le Keystore n'est ni tournée, ni révoquée, ni protégée par quoi que ce
  /// soit — elle attend juste que quelqu'un la retrouve.
  ///
  /// - `nv_broadcast_key` / `nv_broadcast_v2` : la clé de diffusion partagée,
  ///   remplacée par le secret de paire le 2026-08-20.
  /// - `nv_ed25519_seed` : le tampon de signature de l'appareil, retiré le
  ///   2026-08-27 avec le transport BLE.
  static const _deadKeys = ['nv_broadcast_key', 'nv_broadcast_v2', _seedKey];

  /// Durée d'un créneau de rotation des jetons diffusés (~15 min).
  ///
  /// ⚠️ **Le créneau reste, même sans clé partagée.** Un jeton sans créneau
  /// serait constant à vie, donc un identifiant fixe — exactement le mouchard
  /// que tout ce mécanisme existe pour éviter. C'est aussi pourquoi le
  /// « point H » (l'identifiant qui se fige quand Android tue l'activité)
  /// survit au changement d'architecture : il vient du créneau, pas de la clé.
  static const slotDuration = Duration(minutes: 15);

  // ⚠️ **`protocolVersion` a été SUPPRIMÉ d'ici le 2026-08-28.**
  //
  // Il valait **3**, n'avait **aucun lecteur**, et surtout il en contredisait
  // un autre : la version réellement portée par chaque annonce est
  // `BleConstants.PROTOCOL_VERSION`, côté Kotlin, qui vaut **5** — c'est elle
  // qu'écrit `advertDataFor`, elle que compare `onScanResult`, et elle que le
  // diagnostic affiche.
  //
  // Deux constantes du même nom avec deux valeurs différentes, dont une seule
  // compte : le jour où quelqu'un aurait lu celle-ci pour raisonner sur la
  // compatibilité, elle aurait menti sans jamais lever d'erreur. La version
  // vit là où elle est écrite sur le fil, et nulle part ailleurs.

  SimpleKeyPair? _x25519Pair;

  /// Secrets de paire déjà dérivés, indexés par clé publique de l'ami (hex).
  ///
  /// ⚠️ **Indexé par la CLÉ, pas par l'identifiant de l'ami.** C'est ce qui rend
  /// la réinstallation d'un ami indolore : sa nouvelle clé publique est une
  /// autre entrée, donc le secret se redérive tout seul. Rien à invalider,
  /// rien à penser à mettre à jour — un cache indexé par l'identifiant aurait
  /// servi l'ancien secret pour toujours, en silence.
  final _pairSecrets = <String, Uint8List>{};

  /// ⚠️ **Le verrou, et c'est tout le correctif de la course.**
  ///
  /// Un booléen `_loaded` ne suffit pas : entre le moment où l'on constate
  /// qu'il est faux et celui où on l'écrit, il y a deux `await`. Mémoriser la
  /// **promesse** fait attendre le second appelant au lieu de le laisser
  /// refaire le travail.
  Future<void>? _loading;

  Future<void> _ensureLoaded() {
    final pending = _loading;
    if (pending != null) return pending;
    final started = _load();
    _loading = started;
    // Un échec ne doit pas figer l'objet dans un état inutilisable : on rouvre
    // la porte pour la tentative suivante.
    return started.catchError((Object e) {
      _loading = null;
      throw e;
    });
  }

  Future<void> _load() async {
    final x = X25519();
    final storedX = await _storage.read(key: _x25519Key);
    if (storedX != null) {
      _x25519Pair = await x.newKeyPairFromSeed(base64Decode(storedX));
    } else {
      final pair = await x.newKeyPair();
      final seed = await pair.extractPrivateKeyBytes();
      await _storage.write(key: _x25519Key, value: base64Encode(seed));
      _x25519Pair = pair;
    }

    // Les secrets qui n'ont plus d'usage : voir [_deadKeys].
    for (final dead in _deadKeys) {
      await _storage.delete(key: dead);
    }
  }

  /// Graine aléatoire de l'identifiant PUBLIC du mode ping.
  ///
  /// ⚠️ **En mémoire seulement, et c'est délibéré.** Elle ne se persiste pas :
  /// un redémarrage change donc tous les identifiants publics émis, ce qui
  /// coupe net toute tentative de suivi d'une session à l'autre. Personne n'a
  /// besoin de la retrouver — l'identifiant public n'est justement reconnu par
  /// personne. Il sert à se faire découvrir : le serveur, lui, sait relier ce
  /// jeton à un compte, et ne le fait que si la proximité est prouvée des deux
  /// côtés. (Avant le 2026-08-27, c'était une poignée de main BLE qui révélait
  /// l'identité — le jeton, lui, n'a pas changé de rôle.)
  Uint8List? _pingSeed;

  /// Ma clé PUBLIQUE X25519 — celle qui part au serveur et à mes amis.
  Future<Uint8List> x25519PublicKey() async {
    await _ensureLoaded();
    final pub = await _x25519Pair!.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// Le secret que je partage avec CET ami, et lui seul.
  ///
  /// Ni lui ni moi ne l'avons jamais envoyé : chacun le calcule de son côté à
  /// partir de sa propre clé privée et de la clé publique de l'autre. Un
  /// observateur qui a vu passer les deux clés publiques ne peut pas le
  /// retrouver — c'est toute la propriété de Diffie-Hellman.
  ///
  /// Le passage par HKDF n'est pas décoratif : le résultat brut d'un X25519
  /// n'est pas uniformément distribué, et on ne dérive jamais un jeton
  /// directement dessus.
  Future<Uint8List> pairSecret(Uint8List friendX25519Pub) async {
    await _ensureLoaded();
    final key = hex(friendX25519Pub);
    final cached = _pairSecrets[key];
    if (cached != null) return cached;

    final shared = await X25519().sharedSecretKey(
      keyPair: _x25519Pair!,
      remotePublicKey: SimplePublicKey(
        friendX25519Pub,
        type: KeyPairType.x25519,
      ),
    );
    final derived = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: shared, info: utf8.encode('nv-pair-v3'));
    final bytes = Uint8List.fromList(await derived.extractBytes());
    return _pairSecrets[key] = bytes;
  }

  /// Les secrets de tous mes amis, en un passage.
  ///
  /// ⚠️ **C'est ici que se paie la dérivation, et nulle part ailleurs.** Les
  /// jetons se calculent ensuite par HMAC, qui est bon marché ; un X25519 par
  /// créneau et par ami serait, lui, hors de prix. D'où le cache — voir
  /// [_pairSecrets] pour pourquoi il est indexé par la clé et non par l'ami.
  Future<Map<String, Uint8List>> pairSecrets(
    Map<String, Uint8List> friendPublicKeys,
  ) async {
    final out = <String, Uint8List>{};
    for (final entry in friendPublicKeys.entries) {
      out[entry.key] = await pairSecret(entry.value);
    }
    return out;
  }

  /// La graine de l'identifiant public du mode ping, créée à la demande.
  ///
  /// [renew] à l'activation du mode ping : on repart d'une graine neuve, donc
  /// d'une identité publique sans lien avec la précédente.
  Uint8List pingSeed({bool renew = false}) {
    if (renew || _pingSeed == null) {
      final rnd = Random.secure();
      _pingSeed = Uint8List.fromList(
        List.generate(32, (_) => rnd.nextInt(256)),
      );
    }
    return _pingSeed!;
  }

  /// Oublie **toute** l'identité de cet appareil.
  ///
  /// ⚠️ **Indispensable au changement de compte, et personne ne le faisait.**
  /// La clé de diffusion ne dépendait pas du compte connecté : après une
  /// déconnexion, l'appareil continuait de diffuser l'ID rotatif du compte
  /// précédent. Les amis de A voyaient donc « A est là » alors que B utilisait
  /// le téléphone — la même fuite que le carnet d'amis non effacé, corrigée le
  /// 2026-08-17, mais un cran plus bas et jamais vue.
  Future<void> forget() async {
    // ⚠️ On attend un chargement déjà lancé avant d'effacer : sinon il finirait
    // APRÈS nous et réinstallerait en mémoire des clés que le stockage n'a plus.
    try {
      await _loading;
    } catch (_) {
      // Un chargement en échec n'a rien laissé derrière lui.
    }
    _loading = null;
    _x25519Pair = null;
    _pingSeed = null;
    // ⚠️ Les secrets dérivés aussi : ils valent les clés dont ils sortent.
    _pairSecrets.clear();
    await _storage.delete(key: _x25519Key);
    for (final dead in _deadKeys) {
      await _storage.delete(key: dead);
    }
  }

  // ⚠️ **`edPublicKey`, `sign` et `verify` ont été SUPPRIMÉES le 2026-08-27**,
  // avec la clé Ed25519 elle-même.
  //
  // Elles signaient et vérifiaient ce qui voyageait **par la radio** : poignée
  // de main, mini-profil, certificat de croisement, demande d'ami co-signée.
  // La radio ne transporte plus rien depuis ce jour-là.
  //
  // ⚠️ **L'argument qui les gardait en vie est tombé.** Je les avais conservées
  // pour l'attestation contre l'usurpation de pseudo hors ligne
  // (`RAPPELS.md` #2) — chantier qui n'existait que parce qu'un pseudo pouvait
  // être annoncé en BLE. Le BLE ne crie plus que des jetons opaques que seul le
  // serveur sait nommer : **il n'y a plus de pseudo à usurper hors ligne.**
  // C'est la règle 6 de `CLAUDE.md`, appliquée à une décision que j'avais moi
  // même justifiée douze heures plus tôt.

  static int slotIndex(DateTime at) =>
      at.toUtc().millisecondsSinceEpoch ~/ slotDuration.inMilliseconds;

  /// Longueur d'un jeton diffusé, en octets.
  static const tokenLength = 16;

  /// Le jeton **qu'[emitter] crie** à l'autre membre de la paire, pour ce
  /// créneau.
  ///
  /// ⚠️ **`nv-pair-` et `nv-ping-` ne sont pas décoratifs.** Deux usages
  /// différents d'une même fonction doivent partir de textes différents, sinon
  /// rien n'interdit qu'un jeton d'un contexte soit accepté dans l'autre. Ce
  /// n'est pas une précaution théorique : c'est ce qui garantit qu'un jeton
  /// d'ami ne pourra jamais être confondu avec un identifiant public.
  ///
  /// ## ⚠️ Pourquoi [emitter] — la panne du 2026-08-26
  ///
  /// Jusqu'au 2026-08-26 ce jeton valait `HMAC(secret, "nv-pair-$slot")`, donc
  /// **la même valeur des deux côtés** : le secret de paire est symétrique par
  /// construction. Conséquence : le jeton que j'émets pour un ami est
  /// exactement celui que j'attends de lui, et « c'est moi » devient
  /// **indiscernable de « c'est lui » par la valeur**.
  ///
  /// Le natif, qui doit écarter ses propres annonces (réflexion, relais, puce
  /// qui les remonte), jetait donc **toutes** les annonces de l'ami — comptées
  /// en `selfScans`. Relevé sur les deux appareils de Jay : 317 contre 321 sur
  /// le téléphone, 710 contre 721 sur la tablette, soit très exactement une
  /// annonce sur deux. Le croisement d'amis en BLE était **structurellement
  /// impossible**, sans qu'aucune erreur ne soit levée.
  ///
  /// Le nom de l'émetteur dans le message HMAC rend les deux sens distincts :
  /// chacun émet le sien, écoute celui de l'autre, et les deux restent
  /// calculables des deux côtés — c'est la même clé. Le filtre anti-soi
  /// redevient alors **exact** au lieu d'être destructeur. On supprime la
  /// cause, on ne garde pas le garde-fou (règle 1 de `CLAUDE.md`).
  ///
  /// ⚠️ [emitter] est l'identifiant de compte de **celui qui crie**, pas de
  /// celui qui écoute. Une inversion ici ne lève aucune erreur : elle rend
  /// simplement les deux appareils sourds l'un à l'autre. Le sens est vérifié
  /// par `test/advert_plan_test.dart`.
  static Future<Uint8List> pairToken(
    Uint8List secret,
    int slot, {
    required String emitter,
  }) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode('nv-pair-$slot|$emitter'),
      secretKey: SecretKey(secret),
    );
    return Uint8List.fromList(mac.bytes.sublist(0, tokenLength));
  }

  /// L'identifiant PUBLIC du mode ping pour ce créneau.
  ///
  /// ⚠️ **Il n'est reconnu par personne, et c'est son rôle.** Le mode ping sert
  /// à se rendre découvrable d'inconnus ; l'identité se révèle ensuite dans la
  /// poignée de main chiffrée, pas dans l'annonce. Le faire dériver d'un secret
  /// partagé n'apporterait rien et rendrait l'émetteur traçable.
  static Future<Uint8List> publicPingId(Uint8List seed, int slot) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode('nv-ping-$slot'),
      secretKey: SecretKey(seed),
    );
    return Uint8List.fromList(mac.bytes.sublist(0, tokenLength));
  }

  /// Mon identifiant public pour le créneau courant.
  Future<Uint8List> currentPublicPingId() async {
    await _ensureLoaded();
    return publicPingId(pingSeed(), slotIndex(DateTime.now()));
  }

  static String hex(List<int> bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
}

/// **L'** identité de l'appareil. Une seule, comme le carnet d'amis.
///
/// ⚠️ **Ne jamais écrire `ProximityIdentity()` ailleurs que dans un test.**
/// Voir l'en-tête de la classe : cinq instances coexistaient, avec une course
/// au premier lancement qui pouvait faire diverger la clé diffusée de la clé
/// publiée au serveur.
final proximityIdentityProvider = Provider<ProximityIdentity>(
  (ref) => ProximityIdentity(),
);

/// Ce dont le réseau a besoin d'un carnet d'amis — et rien de plus.
abstract class FriendKeyStore {
  Future<Map<String, FriendKeys>> all();

  // ⚠️ **`put` et `remove` ont été RETIRÉS le 2026-08-28** : aucun appelant.
  //
  // Le carnet est **remplacé en bloc** par ce que le serveur renvoie
  // (`replace`), et c'est la seule façon correcte de le tenir : `put` seul
  // n'ajoute que, donc une amitié rompue serait restée vraie sur l'appareil
  // pour toujours. Les garder aurait laissé, à côté du chemin juste, deux
  // chemins partiels qu'un futur appel aurait pu croire suffisants.

  /// ⚠️ **Le carnet RANGE, il ne CALCULE pas.** `rotatingIndex` vivait ici :
  /// le magasin dérivait lui-même les identifiants attendus, donc il fallait
  /// lui donner accès à l'identité de l'appareil, et toute évolution du format
  /// d'annonce venait modifier un magasin de fichiers. C'est la règle de
  /// dissociation de Jay (2026-08-20) : la table de reconnaissance se calcule
  /// dans `advert_plan.dart`, à partir de ce que ce carnet expose.

  /// Remplace **tout** le carnet.
  ///
  /// ⚠️ **Indispensable pour qu'un ami retiré cesse d'en être un.** `put` seul
  /// n'ajoute que : sans remplacement, une amitié rompue côté serveur resterait
  /// vraie sur l'appareil pour toujours. Un carnet qui ne sait qu'ajouter n'est
  /// pas une source de vérité, c'est une archive.
  Future<void> replace(Iterable<FriendKeys> friends);

  /// Prévient quand le carnet change — sans quoi l'index rotatif du réseau ne
  /// verrait jamais les clés téléchargées après son démarrage.
  Listenable get changes;

  /// Oublie TOUT (changement de compte).
  Future<void> clear();
}

/// Carnet local des clés de reconnaissance des AMIS : identifier un ami depuis
/// son ID rotatif, **hors ligne**, sans poignée de main.
class FriendKeyBook implements FriendKeyStore {
  FriendKeyBook();

  Map<String, FriendKeys>? _cache;
  final _changes = _BookNotifier();

  @override
  Listenable get changes => _changes;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    final ping = Directory('${dir.path}${Platform.pathSeparator}ping');
    if (!await ping.exists()) await ping.create(recursive: true);
    return File('${ping.path}${Platform.pathSeparator}friend_keys.json');
  }

  @override
  Future<Map<String, FriendKeys>> all() async {
    if (_cache != null) return _cache!;
    try {
      final file = await _file();
      if (!await file.exists()) return _cache = {};
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return _cache = raw.map(
        (k, v) => MapEntry(k, FriendKeys.fromJson(v as Map<String, dynamic>)),
      );
    } catch (_) {
      return _cache = {};
    }
  }

  @override
  Future<void> replace(Iterable<FriendKeys> friends) async {
    final map = {for (final f in friends) f.userId: f};
    final before = await all();
    // Rien n'a changé : ne pas réveiller tout le monde pour rien. La synchro
    // tourne à chaque croisement, et reconstruire l'index rotatif coûte deux
    // HMAC par ami et par créneau.
    if (before.length == map.length &&
        before.keys.every(map.containsKey) &&
        before.entries.every((e) => e.value.sameAs(map[e.key]!))) {
      return;
    }
    await _save(map);
  }

  Future<void> _save(Map<String, FriendKeys> map) async {
    _cache = map;
    final file = await _file();
    await file.writeAsString(
      jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))),
    );
    _changes.ping();
  }

  @override
  Future<void> clear() async {
    _cache = {};
    final file = await _file();
    if (await file.exists()) await file.delete();
    _changes.ping();
  }

  /// Représentation hexadécimale, **la seule de l'app**.
  ///
  /// Elle existait en quatre exemplaires privés (réseau, carnet, doubles de
  /// test), tous identiques. Quatre copies d'une conversion sont quatre
  /// occasions de diverger sur la casse ou le remplissage.
  static String hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// `notifyListeners` est protégée : seule une sous-classe peut l'appeler.
class _BookNotifier extends ChangeNotifier {
  void ping() => notifyListeners();
}

class FriendKeys {
  const FriendKeys({
    required this.userId,
    required this.username,
    this.tagName,
    this.avatarUrl,
    required this.x25519PublicKey,
  });

  final String userId;
  final String username;
  final String? tagName;
  final String? avatarUrl;

  /// Sa clé PUBLIQUE X25519 : avec ma privée, elle donne le secret de la paire.
  ///
  /// ⚠️ **Ce carnet ne contient plus aucun secret d'ami.** Avant, il stockait
  /// la clé de diffusion — un secret qu'il fallait obtenir, garder à jour et
  /// remplacer. Ici il n'y a que des clés publiques, et le secret se **calcule**
  /// (voir `ProximityIdentity.pairSecret`). Un carnet volé ne permet de
  /// reconnaître personne sans la clé privée de cet appareil.
  final Uint8List x25519PublicKey;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    'tagName': tagName,
    'avatarUrl': avatarUrl,
    'x25519Pub': base64Encode(x25519PublicKey),
  };

  factory FriendKeys.fromJson(Map<String, dynamic> json) => FriendKeys(
    userId: json['userId'] as String,
    username: json['username'] as String,
    tagName: json['tagName'] as String?,
    avatarUrl: json['avatarUrl'] as String?,
    x25519PublicKey: base64Decode(json['x25519Pub'] as String),
  );

  /// Même contenu ? Sert à `replace` pour ne pas annoncer un changement qui
  /// n'en est pas un.
  bool sameAs(FriendKeys other) =>
      userId == other.userId &&
      username == other.username &&
      tagName == other.tagName &&
      avatarUrl == other.avatarUrl &&
      _sameBytes(x25519PublicKey, other.x25519PublicKey);

  static bool _sameBytes(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
