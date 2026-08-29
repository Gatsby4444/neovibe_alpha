import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'radio_status.dart';

/// Client Dart du service de proximité natif.
///
/// ## Ce qu'il fait, et ce qu'il ne fait pas
///
/// Il **traduit**, il ne décide pas. Aucune logique de reprise, aucun état
/// dérivé, aucune connaissance de NeoVibe : il envoie des ordres et rend un
/// flux d'événements. Ce qui se passe quand la radio tombe est l'affaire du
/// superviseur, une couche plus haut.
///
/// ⚠️ **Deux canaux, et c'est volontaire** (voir `ProximityBridge.kt`) : les
/// ordres descendent par un canal de méthodes, les constats remontent par un
/// flux. L'ancienne couche mélangeait les deux sens sur un seul canal de
/// méthodes — donc un événement qui n'intéressait personne devenait un appel
/// sans destinataire, et un flux se retrouvait soumis aux règles d'un appel.
class BleRadio {
  static const _methods = MethodChannel('neovibe/proximity');
  static const _events = EventChannel('neovibe/proximity/events');

  /// Le flux des constats. Chaud : il vit tant que quelqu'un l'écoute, et le
  /// service rejoue son état courant à chaque nouvel abonnement.
  Stream<RadioEvent> events() => _events
      .receiveBroadcastStream()
      .map((raw) => RadioEvent.fromMap(raw as Map<Object?, Object?>))
      .where((e) => e != null)
      .cast<RadioEvent>();

  /// Ce que la radio POURRAIT faire, sans rien démarrer.
  ///
  /// C'est ce qui permet de proposer la bonne action **avant** que
  /// l'utilisateur bascule l'interrupteur — au lieu de le laisser l'activer
  /// pour découvrir ensuite que rien ne se passe.
  Future<RadioStatus> probe() async {
    final raw = await _methods.invokeMapMethod<Object?, Object?>('probe');
    return raw == null ? const RadioUnknown('null') : RadioStatus.fromMap(raw);
  }

  /// Démarre le service et la radio avec [advertId].
  ///
  /// ⚠️ Ne rend **pas** de succès/échec : l'état vrai arrive par le flux. Un
  /// booléen ici recréerait exactement le mensonge qu'on a supprimé — la
  /// méthode peut réussir alors que l'advertising échouera 300 ms plus tard.
  Future<void> start(Uint8List advertId) =>
      _methods.invokeMethod('start', {'advertId': advertId});

  Future<void> stop() => _methods.invokeMethod('stop');

  /// **Je suis vivant, et je veux toujours être découvrable.**
  ///
  /// ⚠️ **À poser à chaque republication réussie de la balise serveur, et
  /// nulle part ailleurs.** C'est le même geste qui rend l'identifiant public
  /// traduisible et qui prouve qu'on est là : les deux durées de vie sont donc
  /// liées par construction, au lieu d'être deux réglages à tenir d'accord.
  ///
  /// Sans lui, le service continuait de crier l'identifiant public **jusqu'à
  /// 75 minutes** après qu'Android a rangé l'app, alors que la balise qui
  /// permet de le traduire meurt au bout de cinq. Un cri que personne ne peut
  /// lire, mais que n'importe quel scanner peut suivre.
  Future<void> publicHeartbeat() => _methods.invokeMethod('publicHeartbeat');

  /// Ouvre les réglages de LOCALISATION du système — pas ceux de l'app.
  ///
  /// ⚠️ Aucune permission ne remplace cet interrupteur : sur Android 10 et 11,
  /// c'est le service de localisation lui-même qu'il faut allumer pour qu'un
  /// scan BLE rende quoi que ce soit. Rétabli le 2026-08-25 (`minSdk = 29`).
  Future<void> openLocationSettings() =>
      _methods.invokeMethod('openLocationSettings');

  // ⚠️ **`updateAdvert` a été SUPPRIMÉ le 2026-08-25** : aucun appelant depuis
  // que le plan d'annonces pilote l'émission (2026-08-20), et il ne pouvait pas
  // porter le TYPE du jeton. Un second chemin vers la radio qui en sait moins
  // que le premier finit toujours par gagner une fois, en silence.

  /// Dépose **plusieurs heures de jetons d'avance** dans le service natif.
  ///
  /// ⚠️ **C'est la correction du point H, et elle est structurelle.** Le jeton
  /// à émettre dépend du créneau de 15 min ; c'était un minuteur Dart qui
  /// poussait le suivant. Or le Dart meurt avec l'interface pendant que le
  /// service survit : l'identifiant se figeait, et l'appareil devenait
  /// invisible pour tous ses amis sans qu'aucune erreur ne soit levée.
  ///
  /// Ici le natif n'a plus besoin de nous : il lit l'heure et choisit. Les
  /// jetons ne sont **pas** des secrets — ce sont des identifiants déjà
  /// calculés, inutilisables pour en fabriquer d'autres.
  ///
  /// Les jetons voyagent **à plat** (un seul `Uint8List`) et non en liste de
  /// listes : à 48 créneaux × 50 amis, c'est 2400 objets contre un seul tampon
  /// de 38 Ko.
  ///
  /// Rend l'instant jusqu'auquel le plan tient, en millisecondes.
  /// [types] porte, dans le **même ordre**, le type de chaque jeton : public
  /// ou privé. ⚠️ **Il ne se déduit pas côté natif** — savoir lequel est
  /// l'identifiant public est une règle produit (« le mode ping est ce qui
  /// l'ajoute »), et une règle vit d'un seul côté.
  Future<int> setAdvertPlan({
    required Uint8List tokens,
    required Uint8List types,
    required int fromSlot,
    required int slotMillis,
    required int slotCount,
    required int perSlot,
    required int tokenLength,
  }) async {
    final res = await _methods
        .invokeMapMethod<String, dynamic>('setAdvertPlan', {
          'tokens': tokens,
          'types': types,
          'fromSlot': fromSlot,
          'slotMillis': slotMillis,
          'slotCount': slotCount,
          'perSlot': perSlot,
          'tokenLength': tokenLength,
        });
    return (res?['validUntil'] as num?)?.toInt() ?? 0;
  }

  /// Dépose la table de reconnaissance : le natif voit alors **par lui-même**.
  ///
  /// ⚠️ **C'est ce qui rend le croisement possible app fermée.** Le plan
  /// d'émission avait rendu le natif autonome pour *diffuser* ; il restait
  /// aveugle, parce que l'appariement jeton → ami vivait en Dart. L'appareil
  /// était donc **vu sans voir** — or le cas qui compte pour un croisement,
  /// c'est le téléphone dans la poche.
  ///
  /// ⚠️ **La table ne contient AUCUNE identité** : des jetons et des rangs
  /// (0, 1, 2…). Seul le Dart sait à qui correspond le rang 3, et il le sait
  /// pour **cette** table — d'où [tableId], renvoyé avec chaque constat. Si le
  /// carnet a changé entre-temps, les constats de l'ancienne table sont jetés
  /// au lieu d'être attribués à la mauvaise personne.
  Future<void> setRecognitionTable({
    required int tableId,
    required Uint8List tokens,
    required int fromSlot,
    required int slotMillis,
    required int slotCount,
    required int perSlot,
    required int tokenLength,
  }) => _methods.invokeMethod('setRecognitionTable', {
    'tableId': tableId,
    'tokens': tokens,
    'fromSlot': fromSlot,
    'slotMillis': slotMillis,
    'slotCount': slotCount,
    'perSlot': perSlot,
    'tokenLength': tokenLength,
  });

  /// Récupère ce que le service a constaté **pendant que le Dart était absent**.
  ///
  /// Vide le tampon natif au passage : à partir de là, le Dart en est seul
  /// responsable. Garder une copie des deux côtés ferait deux vérités à
  /// réconcilier.
  Future<List<Map<String, dynamic>>> takeSightings() async {
    final raw = await _methods.invokeListMethod<Object?>('takeSightings');
    return [
      for (final item in raw ?? const [])
        Map<String, dynamic>.from(item as Map),
    ];
  }

  // ⚠️ **`advertCapabilities` a été SUPPRIMÉ le 2026-08-28**, avec le cas du
  // pont natif et la méthode du service. Aucun appelant : `stats()` fusionne la
  // map entière des capacités depuis le 2026-08-26. Deux chemins vers la même
  // mesure, c'est deux réponses possibles à une question qui n'en a qu'une.

  // ⚠️ **`connect`, `disconnect` et `send` ont été SUPPRIMÉS le 2026-08-27**,
  // avec tout le transport BLE. Ils ouvraient un lien GATT, le refermaient, et
  // y poussaient des morceaux de trame. Plus rien ne transporte de contenu par
  // la radio : le BLE ne fait que **prouver** la proximité, et tout ce qui
  // circule passe par le serveur (décision de Jay du 2026-08-27).
  //
  // Les trois méthodes natives correspondantes sont parties dans le même geste
  // — `ProximityBridge.kt`, `ProximityService.kt`, `BleEngine.kt`. Un canal de
  // méthodes qui répond encore à un ordre que plus personne ne donne est une
  // porte ouverte, pas une compatibilité.

  /// Ce que la radio a reçu depuis le dernier démarrage.
  ///
  /// ⚠️ **`rawScans` compte TOUTES les annonces BLE**, pas seulement les
  /// nôtres. C'est ce qui permet de distinguer « je n'entends rien » de
  /// « personne ne parle » — deux pannes que l'état « détection active »
  /// confondait.
  Future<Map<String, dynamic>> stats() async =>
      await _methods.invokeMapMethod<String, dynamic>('stats') ?? const {};
}

/// **LE** client du canal natif de proximité.
///
/// ⚠️ **Ne jamais écrire `BleRadio()` ailleurs.** Il en existait quatre
/// constructions le 2026-08-28 : le superviseur, le contrôleur, l'écran de
/// diagnostic et le collecteur de rapport. La classe est sans état, donc rien
/// ne cassait — mais deux de ces points étaient un **écran** et un collecteur
/// qui parlaient directement au natif, alors que le superviseur est censé
/// posséder la radio. Un provider rend la règle vraie au lieu de l'énoncer.
final bleRadioProvider = Provider<BleRadio>((ref) => BleRadio());
