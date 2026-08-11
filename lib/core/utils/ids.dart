import 'dart:math';

/// UUID v4, sans dépendance supplémentaire — le paquet `uuid` n'est pas au
/// pubspec et ne se justifierait pas pour une douzaine de lignes.
///
/// Fabriqué **côté client** parce que l'identifiant nomme les fichiers avant
/// leur téléversement : il faut le connaître avant que le serveur ne voie
/// quoi que ce soit. C'est aussi le **Content ID** du contenu créé.
///
/// `Random.secure` et non `Random()` : un générateur prévisible rendrait les
/// identifiants devinables, donc les chemins de stockage énumérables.
String newUuid() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variante RFC 4122
  String hex(int from, int to) => bytes
      .sublist(from, to)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
