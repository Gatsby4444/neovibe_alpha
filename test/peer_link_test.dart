import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/net/peer_link.dart';

/// Deux liens branchés l'un sur l'autre : ce qui sort de l'un entre dans
/// l'autre. C'est le seul montage qui prouve quelque chose — un test qui
/// n'exercerait que l'émission passerait avec un réassembleur cassé.
({PeerLink a, PeerLink b, List<Uint8List> recuA, List<Uint8List> recuB}) paire({
  int mtu = 23,
  bool retarde = false,
}) {
  final recuA = <Uint8List>[];
  final recuB = <Uint8List>[];
  late PeerLink a;
  late PeerLink b;

  a = PeerLink(
    linkId: 'a',
    mtu: mtu,
    sendChunk: (_, chunk) async {
      // `retarde` simule une pile BLE lente : c'est dans ce cas que
      // l'entrelacement se produisait.
      if (retarde) await Future<void>.delayed(const Duration(milliseconds: 1));
      b.receive(chunk);
    },
    onFrame: (_, frame) => recuA.add(frame),
  );
  b = PeerLink(
    linkId: 'b',
    mtu: mtu,
    sendChunk: (_, chunk) async {
      if (retarde) await Future<void>.delayed(const Duration(milliseconds: 1));
      a.receive(chunk);
    },
    onFrame: (_, frame) => recuB.add(frame),
  );
  return (a: a, b: b, recuA: recuA, recuB: recuB);
}

Uint8List motif(int taille, int graine) =>
    Uint8List.fromList(List.generate(taille, (i) => (i + graine) % 256));

void main() {
  test('une trame plus petite qu\'un morceau passe telle quelle', () async {
    final p = paire();
    final frame = motif(5, 0);
    await p.a.send(frame);
    expect(p.recuB, [frame]);
  });

  test(
    'une trame de plusieurs morceaux est réassemblée à l\'identique',
    () async {
      final p = paire(mtu: 23); // 20 octets utiles par morceau
      final frame = motif(500, 7);
      await p.a.send(frame);
      expect(p.recuB.single, frame);
    },
  );

  test('DEUX trames envoyées en même temps ne s\'entrelacent pas', () async {
    // C'est le défaut réel de l'ancienne couche : sans file, les morceaux des
    // deux trames se mélangeaient et le réassembleur collait les moitiés sans
    // rien détecter. Le retard de la pile est ce qui le déclenchait.
    final p = paire(mtu: 23, retarde: true);
    final une = motif(300, 1);
    final deux = motif(300, 200);

    await Future.wait([p.a.send(une), p.a.send(deux)]);

    expect(p.recuB.length, 2);
    expect(p.recuB[0], une);
    expect(p.recuB[1], deux);
  });

  test('un morceau à cheval sur deux trames ne décale pas le flux', () async {
    // Le natif peut livrer un morceau contenant la fin d'une trame ET le début
    // de la suivante. Jeter ce reste décalerait toutes les trames à venir.
    final recu = <Uint8List>[];
    final link = PeerLink(
      linkId: 'x',
      mtu: 512,
      sendChunk: (_, _) async {},
      onFrame: (_, frame) => recu.add(frame),
    );

    final une = motif(4, 1);
    final deux = motif(6, 9);
    final flux = BytesBuilder();
    for (final frame in [une, deux]) {
      final entete = ByteData(4)..setUint32(0, frame.length, Endian.little);
      flux.add(entete.buffer.asUint8List());
      flux.add(frame);
    }
    link.receive(flux.takeBytes());

    expect(recu, [une, deux]);
  });

  test('une longueur aberrante est refusée sans allouer', () {
    final rejets = <String>[];
    final link = PeerLink(
      linkId: 'x',
      mtu: 512,
      sendChunk: (_, _) async {},
      onFrame: (_, _) => fail('aucune trame ne devrait sortir'),
      onDropped: (_, reason) => rejets.add(reason),
    );

    final entete = ByteData(4)..setUint32(0, 900 * 1024, Endian.little);
    link.receive(Uint8List.fromList([...entete.buffer.asUint8List(), 1, 2, 3]));

    expect(rejets.single, contains('aberrante'));
  });

  test('fermer un lien fait échouer les envois en attente', () async {
    final link = PeerLink(
      linkId: 'x',
      mtu: 23,
      // N'aboutit jamais : la trame reste en vol.
      sendChunk: (_, _) => Completer<void>().future,
      onFrame: (_, _) {},
    );
    final envoi = link.send(motif(100, 0));
    link.close();
    // Sans ce contrat, un appelant attendrait pour toujours la fin d'un envoi
    // sur un lien mort.
    await expectLater(envoi, throwsA(isA<StateError>()));
  });
}
