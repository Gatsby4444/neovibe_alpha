import 'dart:async';

import 'package:flutter/services.dart';

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

  Future<void> updateAdvert(Uint8List advertId) =>
      _methods.invokeMethod('updateAdvert', {'advertId': advertId});

  /// Ouvre un lien sortant. Rend le MTU négocié, ou lève.
  Future<int> connect(String address) async {
    final res = await _methods.invokeMapMethod<String, dynamic>('connect', {
      'address': address,
    });
    return res?['mtu'] as int? ?? 23;
  }

  Future<void> disconnect(String linkId) =>
      _methods.invokeMethod('disconnect', {'linkId': linkId});

  /// Ouvre les réglages de LOCALISATION du système.
  ///
  /// Pas ceux de l'app : sur Android ≤ 11, c'est le **service** qu'il faut
  /// allumer, et aucune permission accordée ne le remplace.
  Future<void> openLocationSettings() =>
      _methods.invokeMethod('openLocationSettings');

  /// Ce que la radio a reçu depuis le dernier démarrage.
  ///
  /// ⚠️ **`rawScans` compte TOUTES les annonces BLE**, pas seulement les
  /// nôtres. C'est ce qui permet de distinguer « je n'entends rien » de
  /// « personne ne parle » — deux pannes que l'état « détection active »
  /// confondait.
  Future<Map<String, dynamic>> stats() async =>
      await _methods.invokeMapMethod<String, dynamic>('stats') ?? const {};

  /// Envoie un **morceau** brut. Le découpage est l'affaire du transport.
  Future<void> send(String linkId, Uint8List data) =>
      _methods.invokeMethod('send', {'linkId': linkId, 'data': data});
}
