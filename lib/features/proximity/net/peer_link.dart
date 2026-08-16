import 'dart:async';
import 'dart:typed_data';

/// Découpage et réassemblage des trames sur un lien BLE.
///
/// ## Le contrat
///
/// Une **trame logique** est un bloc d'octets de taille quelconque. Le lien BLE,
/// lui, ne transporte que des **morceaux** de `MTU - 3` octets. Cette classe
/// fait la conversion dans les deux sens, et rien d'autre : elle ne sait pas ce
/// que les octets veulent dire.
///
/// Format du fil : `[longueur : 4 octets, little-endian][charge utile]`.
///
/// ## Les deux défauts qu'elle corrige
///
/// **1. L'entrelacement.** L'ancien code envoyait les morceaux d'une trame par
/// `await` successifs, sans file. Deux trames émises en même temps sur le même
/// lien — un message pendant qu'un certificat part, ce qui est le cas normal —
/// entrelaçaient leurs morceaux. Le réassembleur d'en face ne voyant qu'un flux
/// d'octets, il **collait les deux moitiés sans rien détecter**. Ici, une seule
/// trame est en vol à la fois par lien : [send] fait la queue.
///
/// **2. Le réassemblage sans garde-fou.** Un morceau perdu — et le natif en
/// perdait, faute de file côté notification — laissait le tampon en attente
/// **pour toujours** d'octets qui n'arriveraient jamais, et la trame suivante
/// venait s'y ajouter. Ici, un réassemblage a une **échéance** : passée
/// [reassemblyTimeout] sans progrès, on jette et on repart propre.
class PeerLink {
  PeerLink({
    required this.linkId,
    required this.mtu,
    required this.sendChunk,
    required this.onFrame,
    this.onDropped,
  });

  final String linkId;

  /// MTU négocié. Trois octets sont pris par l'en-tête ATT.
  final int mtu;

  final Future<void> Function(String linkId, Uint8List chunk) sendChunk;
  final void Function(String linkId, Uint8List frame) onFrame;

  /// Appelé quand un réassemblage est abandonné. Sert au diagnostic : une perte
  /// silencieuse est exactement ce qu'on cherche à ne plus avoir.
  final void Function(String linkId, String reason)? onDropped;

  /// Au-delà, on refuse : une longueur aberrante est le signe d'un flux
  /// désynchronisé, et allouer ce qu'elle demande serait la meilleure façon de
  /// transformer une trame corrompue en plantage mémoire.
  static const maxFrameBytes = 256 * 1024;

  /// Un réassemblage qui ne progresse plus est abandonné.
  static const reassemblyTimeout = Duration(seconds: 20);

  int get chunkSize => (mtu - 3).clamp(20, 512);

  // ---------------------------------------------------------------- émission

  final _outbox = <({Uint8List frame, Completer<void> done})>[];
  var _sending = false;
  var _closed = false;

  /// Met une trame en file. Rend quand **cette** trame est partie.
  Future<void> send(Uint8List frame) {
    if (_closed) return Future.error(StateError('lien $linkId fermé'));
    final done = Completer<void>();
    _outbox.add((frame: frame, done: done));
    unawaited(_drain());
    return done.future;
  }

  /// ⚠️ La trame en cours reste **en tête de la file** jusqu'à ce qu'elle soit
  /// vraiment partie. La retirer avant d'attendre la rendait invisible à
  /// [close] : l'appelant attendait alors pour toujours la fin d'un envoi sur un
  /// lien mort. Attrapé par `test/peer_link_test.dart`.
  Future<void> _drain() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_outbox.isNotEmpty && !_closed) {
        final entry = _outbox.first;
        try {
          await _writeFrame(entry.frame);
          if (!entry.done.isCompleted) entry.done.complete();
        } catch (e) {
          if (!entry.done.isCompleted) entry.done.completeError(e);
        }
        if (_outbox.isNotEmpty && identical(_outbox.first, entry)) {
          _outbox.removeAt(0);
        }
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> _writeFrame(Uint8List frame) async {
    final full = Uint8List(4 + frame.length);
    ByteData.sublistView(full).setUint32(0, frame.length, Endian.little);
    full.setAll(4, frame);
    final size = chunkSize;
    for (var offset = 0; offset < full.length; offset += size) {
      final end = (offset + size) > full.length ? full.length : offset + size;
      await sendChunk(linkId, Uint8List.sublistView(full, offset, end));
    }
  }

  // -------------------------------------------------------------- réception

  BytesBuilder? _buffer;
  var _expected = 0;
  DateTime? _startedAt;

  /// Reçoit un morceau venu de la radio.
  void receive(Uint8List chunk) {
    final started = _startedAt;
    if (started != null &&
        DateTime.now().difference(started) > reassemblyTimeout) {
      _reset('réassemblage expiré');
    }

    var buffer = _buffer;
    if (buffer == null) {
      if (chunk.length < 4) {
        onDropped?.call(linkId, 'morceau plus court que l\'en-tête');
        return;
      }
      final expected = ByteData.sublistView(chunk).getUint32(0, Endian.little);
      if (expected <= 0 || expected > maxFrameBytes) {
        onDropped?.call(linkId, 'longueur annoncée aberrante ($expected)');
        return;
      }
      buffer = BytesBuilder();
      _buffer = buffer;
      _expected = expected;
      _startedAt = DateTime.now();
      buffer.add(chunk.sublist(4));
    } else {
      buffer.add(chunk);
    }

    if (buffer.length < _expected) return;

    final bytes = buffer.takeBytes();
    final expected = _expected;
    _buffer = null;
    _expected = 0;
    _startedAt = null;
    onFrame(linkId, Uint8List.sublistView(bytes, 0, expected));

    // Reste des octets : un morceau a chevauché deux trames. Ne PAS le jeter —
    // c'est le début de la trame suivante, et la jeter décalerait tout le flux
    // pour toujours.
    if (bytes.length > expected) {
      receive(Uint8List.sublistView(bytes, expected));
    }
  }

  void _reset(String reason) {
    if (_buffer == null) return;
    _buffer = null;
    _expected = 0;
    _startedAt = null;
    onDropped?.call(linkId, reason);
  }

  /// Le lien tombe : ce qui était en cours n'arrivera jamais.
  ///
  /// **Tout envoi en attente échoue**, y compris celui qui est déjà parti sur le
  /// fil — son sort est de toute façon inconnu, et laisser espérer est pire que
  /// dire non.
  void close() {
    _closed = true;
    _reset('lien fermé');
    for (final entry in _outbox) {
      if (!entry.done.isCompleted) {
        entry.done.completeError(StateError('lien $linkId fermé'));
      }
    }
    _outbox.clear();
  }
}
