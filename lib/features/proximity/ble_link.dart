import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Pilote Dart du lien BLE natif (NativeBle.kt) : advertising à ID rotatif,
/// scan filtré, et liens GATT bidirectionnels. Les trames logiques sont
/// découpées en morceaux ≤ MTU-3 côté émission et réassemblées côté
/// réception (préfixe de longueur 4 octets little-endian).
class BleLink {
  BleLink({
    required this.onScan,
    required this.onLinkUp,
    required this.onLinkDown,
    required this.onFrame,
    required this.onError,
  }) {
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  static const _channel = MethodChannel('neovibe/ble');

  final void Function(String address, Uint8List advertId, int rssi) onScan;
  final void Function(String linkId, bool incoming) onLinkUp;
  final void Function(String linkId) onLinkDown;
  final void Function(String linkId, Uint8List frame) onFrame;
  final void Function(String message) onError;

  final _mtus = <String, int>{};
  final _rxBuffers = <String, BytesBuilder>{};
  final _rxExpected = <String, int>{};

  Future<dynamic> _onPlatformCall(MethodCall call) async {
    final args = call.arguments is Map
        ? (call.arguments as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    switch (call.method) {
      case 'onScan':
        onScan(
          args['address'] as String,
          args['advertId'] as Uint8List,
          args['rssi'] as int,
        );
      case 'onLink':
        final linkId = args['linkId'] as String;
        if (args['connected'] as bool) {
          _mtus[linkId] = args['mtu'] as int? ?? 23;
          onLinkUp(linkId, args['incoming'] as bool? ?? false);
        } else {
          _mtus.remove(linkId);
          _rxBuffers.remove(linkId);
          _rxExpected.remove(linkId);
          onLinkDown(linkId);
        }
      case 'onFrame':
        _onChunk(args['linkId'] as String, args['data'] as Uint8List);
      case 'onError':
        onError(args['message'] as String? ?? 'Erreur BLE');
    }
    return null;
  }

  /// Réassemblage : chaque trame logique commence par sa longueur (4 octets
  /// LE) ; les morceaux suivants la complètent.
  void _onChunk(String linkId, Uint8List chunk) {
    var buffer = _rxBuffers[linkId];
    if (buffer == null) {
      if (chunk.length < 4) return; // trame corrompue : ignorée
      final expected = ByteData.sublistView(chunk).getUint32(0, Endian.little);
      if (expected <= 0 || expected > 1024 * 1024) return;
      buffer = BytesBuilder();
      _rxBuffers[linkId] = buffer;
      _rxExpected[linkId] = expected;
      buffer.add(chunk.sublist(4));
    } else {
      buffer.add(chunk);
    }
    final expected = _rxExpected[linkId]!;
    if (buffer.length >= expected) {
      final bytes = buffer.takeBytes();
      _rxBuffers.remove(linkId);
      _rxExpected.remove(linkId);
      onFrame(linkId, Uint8List.sublistView(bytes, 0, expected));
    }
  }

  Future<void> start(Uint8List advertId) =>
      _channel.invokeMethod('start', {'advertId': advertId});

  Future<void> updateAdvert(Uint8List advertId) =>
      _channel.invokeMethod('updateAdvert', {'advertId': advertId});

  Future<void> stop() => _channel.invokeMethod('stop');

  Future<String?> connect(String address) async {
    final res = await _channel.invokeMapMethod<String, dynamic>('connect', {
      'address': address,
    });
    final linkId = res?['linkId'] as String?;
    if (linkId != null) _mtus[linkId] = res?['mtu'] as int? ?? 23;
    return linkId;
  }

  Future<void> disconnect(String linkId) =>
      _channel.invokeMethod('disconnect', {'linkId': linkId});

  /// Envoie une trame logique (préfixe de longueur + découpe MTU).
  Future<void> send(String linkId, Uint8List frame) async {
    final mtu = (_mtus[linkId] ?? 23) - 3;
    final header = ByteData(4)..setUint32(0, frame.length, Endian.little);
    final full = Uint8List(4 + frame.length)
      ..setAll(0, header.buffer.asUint8List())
      ..setAll(4, frame);
    for (var offset = 0; offset < full.length; offset += mtu) {
      final end = (offset + mtu).clamp(0, full.length);
      await _channel.invokeMethod('send', {
        'linkId': linkId,
        'data': Uint8List.sublistView(full, offset, end),
      });
    }
  }
}
