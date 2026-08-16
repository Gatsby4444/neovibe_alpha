import 'dart:typed_data';

/// L'état RÉEL de la radio, tel que le natif le publie.
///
/// Miroir exact de `RadioStatus.kt`. ⚠️ **Les deux doivent bouger ensemble** :
/// le discriminant est la chaîne `type`, et un cas ajouté d'un seul côté tombe
/// silencieusement dans [RadioUnknown] — jamais dans une exception.
///
/// ## Pourquoi ce type existe
///
/// Avant la reconstruction du 2026-08-16, la visibilité était un simple
/// booléen `visible`. Il disait ce que l'utilisateur avait **demandé**, et
/// l'interface le présentait comme ce que le matériel **faisait**. Les deux
/// n'ont rien à voir : le Bluetooth peut être éteint, une permission
/// manquante, l'advertising refusé par la pile. Le diagnostic du 2026-08-16 a
/// montré que ces trois cas affichaient tous « Personne à proximité », donc
/// qu'aucun test n'était interprétable.
sealed class RadioStatus {
  const RadioStatus();

  factory RadioStatus.fromMap(Map<Object?, Object?> map) {
    switch (map['type']) {
      case 'unsupported':
        return const RadioUnsupported();
      case 'permissionsMissing':
        return RadioPermissionsMissing(
          (map['missing'] as List?)?.map((e) => '$e').toList() ?? const [],
        );
      case 'adapterOff':
        return const RadioAdapterOff();
      case 'idle':
        return const RadioIdle();
      case 'starting':
        return const RadioStarting();
      case 'running':
        return RadioRunning(
          advertising: map['advertising'] == true,
          scanning: map['scanning'] == true,
        );
      case 'failed':
        return RadioFailed('${map['code']}', '${map['message']}');
      default:
        return RadioUnknown('${map['type']}');
    }
  }

  /// Vrai si la radio détecte réellement. **C'est la seule question qui compte**
  /// pour savoir si une liste vide veut dire « personne » ou « rien ne tourne ».
  bool get isDetecting =>
      this is RadioRunning && (this as RadioRunning).scanning;

  /// Vrai si l'utilisateur peut y faire quelque chose (allumer le Bluetooth,
  /// accorder une permission). Sert à décider si l'on propose une action.
  bool get isActionable =>
      this is RadioAdapterOff || this is RadioPermissionsMissing;
}

class RadioUnsupported extends RadioStatus {
  const RadioUnsupported();
}

class RadioPermissionsMissing extends RadioStatus {
  const RadioPermissionsMissing(this.missing);
  final List<String> missing;
}

class RadioAdapterOff extends RadioStatus {
  const RadioAdapterOff();
}

class RadioIdle extends RadioStatus {
  const RadioIdle();
}

class RadioStarting extends RadioStatus {
  const RadioStarting();
}

class RadioRunning extends RadioStatus {
  const RadioRunning({required this.advertising, required this.scanning});

  /// Les autres peuvent nous voir.
  final bool advertising;

  /// Nous pouvons voir les autres.
  ///
  /// ⚠️ Les deux sont **indépendants** : l'advertising peut échouer seul (pile
  /// saturée, trop d'annonceurs) pendant que le scan tourne. On détecterait
  /// alors sans être détecté — une asymétrie invisible avec un simple booléen,
  /// et qui explique parfaitement « il me voit mais je ne le vois pas ».
  final bool scanning;
}

class RadioFailed extends RadioStatus {
  const RadioFailed(this.code, this.message);
  final String code;
  final String message;
}

/// Cas inconnu — le natif a publié un état que ce Dart ne connaît pas.
///
/// Existe pour qu'une divergence de version **se voie** au lieu de faire
/// planter, ou pire, d'être avalée par un `default:` silencieux.
class RadioUnknown extends RadioStatus {
  const RadioUnknown(this.type);
  final String type;
}

/// Ce que la radio constate. Séparé des ORDRES qu'on lui donne.
sealed class RadioEvent {
  const RadioEvent();

  static RadioEvent? fromMap(Map<Object?, Object?> map) {
    switch (map['event']) {
      case 'status':
        return RadioStatusEvent(RadioStatus.fromMap(map));
      case 'scan':
        return RadioScan(
          address: '${map['address']}',
          advertId: map['advertId'] as Uint8List,
          rssi: map['rssi'] as int,
        );
      case 'link':
        return RadioLink(
          linkId: '${map['linkId']}',
          connected: map['connected'] == true,
          mtu: map['mtu'] as int? ?? 23,
          incoming: map['incoming'] == true,
        );
      case 'frame':
        return RadioFrame('${map['linkId']}', map['data'] as Uint8List);
      default:
        return null;
    }
  }
}

class RadioStatusEvent extends RadioEvent {
  const RadioStatusEvent(this.status);
  final RadioStatus status;
}

class RadioScan extends RadioEvent {
  const RadioScan({
    required this.address,
    required this.advertId,
    required this.rssi,
  });
  final String address;
  final Uint8List advertId;
  final int rssi;
}

class RadioLink extends RadioEvent {
  const RadioLink({
    required this.linkId,
    required this.connected,
    required this.mtu,
    required this.incoming,
  });
  final String linkId;
  final bool connected;
  final int mtu;
  final bool incoming;
}

class RadioFrame extends RadioEvent {
  const RadioFrame(this.linkId, this.data);
  final String linkId;
  final Uint8List data;
}
