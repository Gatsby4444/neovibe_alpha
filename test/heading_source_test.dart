import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/proximity/geo/heading_source.dart';

/// La flèche qui se figeait (Jay, 2026-09-26) : deux flux ouverts sur le
/// même canal se retirent l'un l'autre le récepteur. Un flux unique, partagé,
/// ne peut pas le faire.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const canal = 'neovibe/heading/events';
  final messager =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  setUp(() {
    // Le côté natif : accepte « listen » et « cancel », sans rien faire.
    messager.setMockMethodCallHandler(
      const MethodChannel(canal),
      (_) async => null,
    );
  });

  /// Une mesure de boussole, comme le natif l'envoie.
  Future<void> mesure(double deg) => messager.handlePlatformMessage(
    canal,
    codec.encodeSuccessEnvelope({'deg': deg, 'fiabilite': 3}),
    (_) {},
  );

  test("PANNE REPRODUITE : deux flux sur le canal — fermer l'ancien fige le "
      'nouveau', () async {
    const ch = EventChannel(canal);
    final recus = <Object?>[];
    final ancien = ch.receiveBroadcastStream().listen((_) {});
    await pumpEventQueue();
    final nouveau = ch.receiveBroadcastStream().listen(recus.add);
    await pumpEventQueue();
    await ancien.cancel(); // la fermeture tardive de l'ancien
    await mesure(90);
    await pumpEventQueue();
    expect(recus, isEmpty, reason: 'le récepteur du nouveau a été retiré');
    await nouveau.cancel();
  });

  test('le flux partagé survit à la fermeture tardive d’un auditeur', () async {
    final recus = <HeadingReading>[];
    final ancien = headingStream.listen((_) {});
    await pumpEventQueue();
    final nouveau = headingStream.listen(recus.add);
    await pumpEventQueue();
    await ancien.cancel();
    await mesure(90);
    await pumpEventQueue();
    expect(recus.map((r) => r.degrees), [90]);
    await nouveau.cancel();
  });
}
