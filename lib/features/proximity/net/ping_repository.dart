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

  /// Le plafond que **le client** demande.
  ///
  /// ⚠️ **Il est passé explicitement, et ce n'est pas cosmétique.** Il valait le
  /// défaut du serveur : le client recevait donc une liste éventuellement
  /// **coupée sans le savoir**, et l'écran affichait « 500 personnes » comme un
  /// fait alors que c'était la limite de l'instrument. Une limite subie doit
  /// être connue de celui qui la subit.
  static const shortlistLimit = 500;

  /// La liste des jetons à écouter.
  ///
  /// ⚠️ **Des jetons, jamais des profils.** Sans être physiquement à portée BLE
  /// de l'un d'eux, cette liste n'apprend rigoureusement rien : ni qui, ni
  /// combien de personnes distinctes, ni où. C'est une liste de choses à
  /// écouter, pas une liste de gens.
  Future<PingShortlist> shortlist({int limit = shortlistLimit}) async {
    final rows = await ref
        .read(supabaseProvider)
        .rpc('ping_shortlist', params: {'p_limit': limit});
    final tokens = {
      for (final row in (rows as List? ?? const []))
        (row as Map)['token'] as String,
    };
    // ⚠️ **On ne devine pas la troncature, on borne ce qu'on affirme.**
    // Recevoir exactement ce qu'on a demandé ne prouve pas qu'il y en avait
    // plus — mais faire porter le total par chaque ligne coûterait ~7 Ko de
    // réseau sur les 48 Ko mesurés. « Au moins N » est vrai dans les deux cas ;
    // « N » ne l'est que dans l'un des deux.
    return PingShortlist(tokens: tokens, atLeast: tokens.length >= limit);
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

/// La liste des jetons a ecouter, **et si elle a ete coupee**.
///
/// ⚠️ **Deux faits distincts, donc deux champs.** Le nombre de jetons rendus et
/// « y en avait-il plus ? » ne répondent pas à la même question, et les
/// confondre fait afficher une limite comme si c'était une mesure.
class PingShortlist {
  const PingShortlist({required this.tokens, required this.atLeast});

  final Set<String> tokens;

  /// Vrai quand le serveur a rendu **au moins** autant qu'on lui en demandait :
  /// le compte affiche est alors un plancher, pas un total.
  final bool atLeast;

  int get length => tokens.length;
}

/// Quelqu'un dont la proximité a été **prouvée des deux côtés**.
class NearbyPerson {
  const NearbyPerson({
    required this.userId,
    required this.displayName,
    required this.lastSeenAt,
    this.tagName,
    this.avatarUrl,
  });

  final String userId;
  final String displayName;
  final String? tagName;
  final String? avatarUrl;

  /// Dernier instant où la proximité mutuelle a été constatée.
  ///
  /// ⚠️ **C'est un FAIT, pas un état d'affichage.** « Est-il encore là ? » se
  /// décide en aval, contre une horloge.
  final DateTime lastSeenAt;

  factory NearbyPerson.fromJson(Map<String, dynamic> json) => NearbyPerson(
    userId: json['user_id'] as String,
    displayName: json['display_name'] as String? ?? '',
    tagName: json['tag_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    lastSeenAt: DateTime.parse(json['last_seen_at'] as String),
  );

  @override
  bool operator ==(Object other) =>
      other is NearbyPerson &&
      other.userId == userId &&
      other.displayName == displayName &&
      other.tagName == tagName &&
      other.avatarUrl == avatarUrl &&
      other.lastSeenAt == lastSeenAt;

  @override
  int get hashCode =>
      Object.hash(userId, displayName, tagName, avatarUrl, lastSeenAt);
}

final pingRepositoryProvider = Provider(PingRepository.new);
