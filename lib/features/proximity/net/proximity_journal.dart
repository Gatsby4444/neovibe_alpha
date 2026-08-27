import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Ce que le ping garde sur l'appareil, hors conversations et croisements.
///
/// ## ⚠️ Ce qui a été retiré le 2026-08-27
///
/// Il tenait aussi les **demandes d'amis de proximité**, reçues et envoyées :
/// deux modèles (`PendingFriendRequest`, `OutgoingFriendRequest`), deux
/// fichiers, et une dizaine de méthodes.
///
/// Elles n'existaient que parce qu'une demande d'ami voyageait **d'appareil à
/// appareil**, dans le canal BLE co-signé : sans ligne serveur, il fallait bien
/// que quelqu'un s'en souvienne localement. Depuis le 2026-08-27 une demande
/// est un appel à `request_connection_from_proximity`, donc **une ligne dans
/// `connection_requests`** — le serveur s'en souvient, et l'écran « Demandes »
/// la lisait déjà par un autre chemin.
///
/// Il ne reste ici que ce qui n'a **aucune** contrepartie serveur : le cooldown
/// des waves, qui est une décision de notification purement locale.
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

  // ⚠️ **`pendingRequests`, `putRequest`, `removeRequest`, `outgoingRequests`,
  // `outgoingTo`, `putOutgoing`, `markOutgoingDeclined` et `removeOutgoing` ont
  // été SUPPRIMÉES le 2026-08-27**, avec les deux modèles qu'elles rangeaient.
  //
  // Leurs deux fichiers restent listés dans [clear] : d'anciens appareils en
  // portent encore, et un fichier que plus aucun code ne connaît est un reste
  // mort qui survivrait à toutes les remises à zéro.

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
    _waves = null;
    for (final name in [
      'wave_cooldown.json',
      // Reliquats du chat BLE, retiré le 2026-08-27. Aucun code ne les écrit
      // plus ; les effacer reste le seul moyen de ne pas laisser dormir des
      // demandes d'amis d'un ancien compte sur l'appareil.
      'pending_requests.json',
      'outgoing_requests.json',
    ]) {
      final file = await _file(name);
      if (await file.exists()) await file.delete();
    }
  }
}
