import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import '../geo/coarse_location.dart';

/// **Le seul chemin vers le serveur pour le ping de proximité.**
///
/// ⚠️ **Aucun écran n'appelle Supabase directement** (règle de Jay du
/// 2026-08-25). Tout passe par ici, et ce dépôt ne décide de rien d'autre que
/// de la forme de l'appel : il ne filtre pas, ne trie pas, ne juge pas de la
/// fraîcheur. Ce sont des décisions d'affichage, elles appartiennent aux vues.
///
/// Détail de l'architecture : `docs/proximite-v2-gps-et-ble.md`.
class PingRepository {
  PingRepository(this.ref);

  final Ref ref;

  /// Publie ma balise : ma position, son incertitude, et le jeton que je crie.
  ///
  /// ⚠️ **La position exacte est envoyée ET conservée** — décision de Jay du
  /// 2026-08-26. Le serveur en tire le carreau (une seule définition de la
  /// grille, chez lui), mais garde la valeur : c'est elle qui permet le filtre
  /// par distance réelle et la barrière anti-relais de `confirm_ping`.
  ///
  /// ⚠️ **L'incertitude part avec, et ce n'est pas décoratif.** Sans elle, le
  /// serveur appliquerait un rayon fixe à une position dont il ignore la
  /// qualité — et ferait disparaître de la liste des gens réellement à portée,
  /// sans que rien ne le dise. Voir `private.ping_reach`.
  Future<void> publishBeacon({
    required CoarseFix fix,
    required Uint8List token,
    required int slot,
  }) => ref
      .read(supabaseProvider)
      .rpc(
        'publish_ping_beacon',
        params: {
          'p_lat': fix.latitude,
          'p_lon': fix.longitude,
          'p_acc': fix.accuracy,
          'p_token': _hex(token),
          'p_slot': slot,
        },
      );

  /// Cesse de s'annoncer.
  ///
  /// ⚠️ **Supprime la ligne, ne pose pas un drapeau.** Un drapeau laisserait la
  /// position en base après que l'utilisateur a coupé le ping — c'est-à-dire
  /// exactement ce qu'il vient de refuser.
  Future<void> retireBeacon() =>
      ref.read(supabaseProvider).rpc('retire_ping_beacon');

  /// **Combien de balises fraîches dans le voisinage. Un entier, rien d'autre.**
  ///
  /// ## 🔴 Ce qui a remplacé la liste d'écoute, le 2026-08-28
  ///
  /// Cette méthode s'appelait `shortlist()` et rapatriait **jusqu'à 500 jetons**
  /// — 30 Ko par minute et par appareil — dont le client ne faisait qu'une
  /// chose : filtrer, **en logiciel**, les annonces que la radio lui avait déjà
  /// livrées. Le seul de ces jetons visible à l'écran était… leur **nombre**.
  ///
  /// ⚠️ **Elle était dimensionnée par la mauvaise chose** : le carreau GPS
  /// (1 à 3 km, des centaines de personnes) alors que ce qu'on entend est
  /// dimensionné par la portée BLE (~30 m, une poignée). On téléchargeait des
  /// centaines de jetons pour en reconnaître trois.
  ///
  /// ⚠️ **Et elle créait le trou du changement de créneau** : tous les jetons
  /// tournent en même temps toutes les 15 minutes, la liste avait jusqu'à 60 s
  /// de retard, et **tout le monde devenait aveugle quatre fois par heure**.
  ///
  /// Ce qui a été vérifié avant de la retirer, en base et dans le code natif :
  /// le filtre de scan BLE accepte **tout** (`ScanFilter.Builder().build()`), il
  /// n'y a **aucune connexion GATT** dans le ping, et la liste n'avait **qu'un
  /// seul lecteur** en Dart. Elle ne protégeait donc aucune limite radio.
  Future<int> neighbourCount() async {
    final n = await ref.read(supabaseProvider).rpc('ping_neighbour_count');
    return (n as num?)?.toInt() ?? 0;
  }

  /// Dépose ce que j'ai **entendu**. Rend le nombre de constats retenus.
  ///
  /// ⚠️ **Un dépôt unilatéral ne produit rien** : ni paire, ni profil, ni
  /// conversation. C'est le serveur qui exige le miroir, et c'est ce qui rend
  /// l'anti-traque structurel plutôt que déclaratif.
  Future<int> confirm({
    required Iterable<String> tokensHex,
    required int slot,
  }) async {
    final list = tokensHex.toList(growable: false);
    if (list.isEmpty) return 0;
    final n = await ref
        .read(supabaseProvider)
        .rpc('confirm_ping', params: {'p_tokens': list, 'p_slot': slot});
    return (n as num?)?.toInt() ?? 0;
  }

  /// Qui est là, avec son profil — uniquement les proximités **mutuelles**.
  ///
  /// ⚠️ **La fraîcheur n'est PAS décidée ici.** Le serveur rend le fait
  /// (`last_seen_at`), la vue décide de ce qu'elle affiche — y compris les 30 s
  /// d'indulgence voulues par Jay quand quelqu'un sort de portée.
  Future<List<NearbyPerson>> nearby() async {
    final rows = await ref.read(supabaseProvider).rpc('ping_nearby');
    return [
      for (final row in (rows as List? ?? const []))
        NearbyPerson.fromJson(row as Map<String, dynamic>),
    ];
  }

  /// Ouvre la messagerie de proximité. ⚠️ Le serveur **refuse** si la proximité
  /// n'a pas été constatée mutuellement, et si les deux sont déjà amis.
  Future<String> openConversation(String peerId) async {
    final id = await ref
        .read(supabaseProvider)
        .rpc('get_or_create_proximity_conversation', params: {'peer': peerId});
    return id as String;
  }

  /// Demande en ami quelqu'un dont la proximité vient d'être prouvée.
  ///
  /// ⚠️ **La barrière fondatrice est vérifiée par le SERVEUR** depuis le
  /// 2026-08-27. Elle était tenue par la portée de la radio : la demande
  /// voyageait dans un canal BLE chiffré, donc il fallait être là. Maintenant
  /// qu'elle est un appel réseau, `request_connection_from_proximity` exige la
  /// preuve que le BLE vient de produire — sans paire mutuelle fraîche, la
  /// demande est refusée. **Le BLE reste la barrière ; il ne transporte
  /// simplement plus le message.**
  Future<String> requestConnection(String peerId) async {
    final id = await ref
        .read(supabaseProvider)
        .rpc('request_connection_from_proximity', params: {'peer': peerId});
    return id as String;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// ⚠️ **`PingShortlist` a été SUPPRIMÉE le 2026-08-28**, avec la liste d'écoute.
//
// Elle portait deux champs — le nombre de jetons rendus, et « y en avait-il
// plus ? » — parce qu'un plafond de 500 pouvait tronquer la réponse sans le
// dire. `ping_neighbour_count` rend un `count(*)`, donc **le vrai nombre** :
// la question de la troncature n'a plus de sujet.
//
// ⚠️ La règle qu'elle défendait — *un plafond n'est pas une mesure* — n'est pas
// abandonnée, elle est sans objet ici. Elle reste vraie partout où un
// instrument coupe (`listeningTruncated` était son seul porteur dans ce
// module).

/// Quelqu'un dont la proximité a été **prouvée des deux côtés**.
class NearbyPerson {
  const NearbyPerson({
    required this.userId,
    required this.displayName,
    required this.lastSeenAt,
    this.tagName,
    this.avatarUrl,
    this.token,
    this.specialMention,
  });

  final String userId;
  final String displayName;
  final String? tagName;
  final String? avatarUrl;

  /// Dernier instant où la proximité mutuelle a été constatée **par le
  /// serveur**.
  ///
  /// ⚠️ **C'est un FAIT, pas un état d'affichage.** « Est-il encore là ? » se
  /// décide en aval — et, depuis le 2026-08-27, **en local** dès qu'on connaît
  /// son [token]. Cette date ne sert plus que de filet.
  final DateTime lastSeenAt;

  /// Le jeton qu'il crie **en ce moment**, ou `null` si sa balise a expiré.
  ///
  /// ⚠️ **C'est ce qui rend l'écran autonome.** Sans lui, le téléphone entendait
  /// « le jeton X » sans savoir que X était Bob : il devait redemander au
  /// serveur toutes les dix secondes si Bob était encore là, alors que sa radio
  /// le lui criait déjà. Avec lui, la question « est-il encore là ? » se répond
  /// **sans réseau**.
  ///
  /// ⚠️ **Il change de créneau en créneau** (15 min). Quand il devient nul ou
  /// périmé, on retombe sur [lastSeenAt] le temps de le réapprendre.
  final String? token;

  /// La **mention spéciale** — la deuxième bio, écrite pour les gens qu'on
  /// croise sans les connaître.
  ///
  /// ⚠️ **Nulle ne veut pas dire « vide », ça veut dire « pas pour toi ».** Le
  /// serveur ne l'envoie que si la personne a ouvert son interrupteur : ce
  /// n'est donc pas à l'app de décider de la montrer, elle ne reçoit rien à
  /// cacher. Voir la migration du 2026-08-30.
  final String? specialMention;

  factory NearbyPerson.fromJson(Map<String, dynamic> json) => NearbyPerson(
    userId: json['user_id'] as String,
    displayName: json['display_name'] as String? ?? '',
    tagName: json['tag_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    lastSeenAt: DateTime.parse(json['last_seen_at'] as String),
    token: json['token'] as String?,
    specialMention: json['special_mention'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is NearbyPerson &&
      other.userId == userId &&
      other.displayName == displayName &&
      other.tagName == tagName &&
      other.avatarUrl == avatarUrl &&
      other.lastSeenAt == lastSeenAt &&
      other.token == token &&
      other.specialMention == specialMention;

  @override
  int get hashCode => Object.hash(
    userId,
    displayName,
    tagName,
    avatarUrl,
    lastSeenAt,
    token,
    specialMention,
  );
}

final pingRepositoryProvider = Provider(PingRepository.new);
