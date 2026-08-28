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
      case 'locationOff':
        return const RadioLocationOff();
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

  /// Vrai si les autres peuvent nous voir.
  ///
  /// ⚠️ **Distinct de [isDetecting], et il faut les deux.** La proximité est
  /// symétrique : détecter sans être annoncé donne un appareil qui voit tout le
  /// monde sans que personne ne le voie — exactement l'asymétrie constatée par
  /// Jay le 2026-08-16 entre son téléphone et sa tablette.
  bool get isBroadcasting =>
      this is RadioRunning && (this as RadioRunning).advertising;

  /// Vrai quand les deux sens fonctionnent. C'est le seul « tout va bien ».
  bool get isHealthy => isDetecting && isBroadcasting;
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

/// Le service de localisation de l'appareil est éteint.
///
/// ⚠️ **Sur Android 10 et 11 seulement, et ça suffit à tout aveugler.** Le
/// système considère alors qu'écouter les identifiants Bluetooth des environs
/// revient à se localiser : sans le service allumé, `startScan` réussit et ne
/// renvoie **jamais** de résultat, sans la moindre erreur.
///
/// La permission accordée ne remplace pas le service allumé — ce sont deux
/// choses distinctes, et les confondre a coûté une journée le 2026-08-16.
///
/// ⚠️ **Retiré le 2026-08-20 (`minSdk = 31`), rétabli le 2026-08-25
/// (`minSdk = 29`).** C'est le natif qui garantit qu'il reste inatteignable
/// au-dessus d'Android 11 : au-delà, `evaluateRadio` ne l'émet pas.
class RadioLocationOff extends RadioStatus {
  const RadioLocationOff();
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
          txPower: map['txPower'] as int? ?? RadioScan.txPowerUnknown,
          type: AdvertType.fromWire(map['advertType'] as int?),
          at: DateTime.fromMillisecondsSinceEpoch(
            (map['atMillis'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          ),
        );
      // ⚠️ **`link` et `frame` ont été RETIRÉS le 2026-08-27**, avec le
      // transport BLE. Le natif ne les émet plus. Une trame reçue d'un appareil
      // resté sur une version antérieure retombe donc dans `default` et vaut
      // `null` — écartée, sans erreur : c'est exactement le contrat de cette
      // méthode pour tout ce qu'elle ne comprend pas.
      default:
        return null;
    }
  }
}

class RadioStatusEvent extends RadioEvent {
  const RadioStatusEvent(this.status);
  final RadioStatus status;
}

/// **Ce qu'une annonce EST : publique, ou privée.**
///
/// ⚠️ **Consigne de Jay, 2026-08-25 : deux formats, deux chemins.** Jusqu'au
/// protocole v3, l'identifiant public du mode ping et les jetons privés d'amis
/// partaient comme 16 octets indifférenciés. Un ami recevait donc les jetons
/// destinés aux **autres** amis de l'émetteur sans pouvoir les distinguer d'un
/// inconnu : avec cinq amis, un seul appareil apparaissait une fois comme ami
/// et **cinq fois comme un inconnu**.
enum AdvertType {
  /// Destiné aux inconnus. **Reconnu par personne, et c'est son rôle.**
  public,

  /// Destiné à **un** ami précis.
  ///
  /// ⚠️ Un jeton de ce type qu'on ne reconnaît pas **n'est pas un inconnu** :
  /// c'est le jeton privé de quelqu'un d'autre. Il se jette.
  friend;

  static AdvertType fromWire(int? value) =>
      value == 2 ? AdvertType.friend : AdvertType.public;
}

class RadioScan extends RadioEvent {
  const RadioScan({
    required this.address,
    required this.advertId,
    required this.rssi,
    required this.type,
    required this.at,
    this.txPower = txPowerUnknown,
  });

  /// **Quand cette annonce a été entendue.**
  ///
  /// ⚠️ **Obligatoire, et ce n'est pas une commodité.** Le service natif met de
  /// côté ce qu'il capte pendant que l'interface est absente, et le rejoue à son
  /// retour. Sans cette date, un consommateur prend un souvenir vieux de
  /// plusieurs heures pour une observation faite maintenant : le pair
  /// réapparaissait « à portée », et une notification « Le presque… » partait
  /// pour quelqu'un de parti depuis longtemps (défaut du 2026-08-28).
  ///
  /// ⚠️ **L'acquisition la publie, elle ne juge pas.** Ce que « trop vieux »
  /// veut dire appartient à chaque consommateur : le réseau de pairs et le
  /// service de balise n'ont pas la même définition, et c'est normal.
  final DateTime at;

  /// Publique ou privée — voir [AdvertType].
  final AdvertType type;

  /// Valeur d'Android quand l'émetteur n'annonce pas sa puissance.
  static const txPowerUnknown = 127;

  final String address;
  final Uint8List advertId;

  /// Puissance **reçue**, en dBm. Toujours négative en pratique.
  final int rssi;

  /// Puissance **émise** annoncée par le pair, en dBm.
  ///
  /// ⚠️ Sans elle, on ne connaît que ce qui arrive et il faut deviner ce qui
  /// est parti — or cela varie de plusieurs dB d'un appareil à l'autre. La
  /// recevoir supprime une inconnue ; elle n'en supprime pas les autres.
  final int txPower;

  // ⚠️ **`hasTxPower` a été RETIRÉ le 2026-08-28** : aucun appelant. La
  // question « la puissance est-elle annoncée ? » se pose une seule fois, dans
  // `DistanceModel.estimate`, qui compare directement à [txPowerUnknown] — un
  // second endroit où la poser aurait été un second seuil à tenir d'accord.
}
