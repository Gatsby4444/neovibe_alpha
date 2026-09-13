import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/message.dart';

/// Ce que ces tests protègent : **un vocal arrive dans le fil comme un vocal**,
/// avec sa durée, et un client qui ne connaît pas ce genre continue d'afficher
/// la conversation au lieu de la casser.
void main() {
  Map<String, dynamic> row({String kind = 'voice', Object? duration = 4200}) =>
      {
        'id': 'm1',
        'conversation_id': 'c1',
        'sender_id': 'u1',
        'kind': kind,
        'media_path': 'u1/123_voice.nvc',
        'duration_ms': duration,
        'created_at': '2026-09-13T12:00:00Z',
        'expires_at': '2026-09-14T12:00:00Z',
      };

  test('un vocal se décode avec sa durée', () {
    final m = Message.fromJson(row());
    expect(m.kind, MessageKind.voice);
    expect(m.duration, const Duration(milliseconds: 4200));
    expect(m.mediaPath, 'u1/123_voice.nvc');
    expect(MessageKind.voice.dbValue, 'voice');
  });

  test('sans durée, le vocal reste un vocal', () {
    final m = Message.fromJson(row(duration: null));
    expect(m.kind, MessageKind.voice);
    expect(m.duration, isNull);
  });

  test('un genre inconnu retombe sur le texte, jamais sur une exception', () {
    expect(MessageKind.fromDb('hologram'), MessageKind.text);
  });

  test('la durée fait partie de l\'égalité de valeur', () {
    final a = Message.fromJson(row());
    final b = Message.fromJson(row());
    final c = Message.fromJson(row(duration: 4300));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
  });
}
