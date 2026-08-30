import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'wave_rules.dart';

/// Un contact terminé, tel qu'on s'en souvient.
///
/// ⚠️ **[juge] est ici, et pas dans un second fichier.** C'est de l'état de la
/// fonctionnalité « presque » posé sur une donnée d'acquisition, et on pourrait
/// vouloir les séparer. Deux fichiers voudraient dire **deux vérités à tenir
/// d'accord** — un contact effacé d'un côté et pas de l'autre, et un presque
/// qui repart en boucle. Un chemin, une donnée.
class ContactEnregistre {
  const ContactEnregistre({
    required this.debut,
    required this.fin,
    required this.detections,
    required this.juge,
  });

  final DateTime debut;
  final DateTime fin;

  /// Combien de fois la radio l'a entendu. Voir [WaveRules.presDetectionsMin].
  final int detections;

  /// Le verdict du presque a-t-il déjà été rendu pour ce contact ?
  final bool juge;

  Presence get presence => Presence(debut: debut, fin: fin);

  ContactEnregistre juger() => ContactEnregistre(
    debut: debut,
    fin: fin,
    detections: detections,
    juge: true,
  );

  Map<String, dynamic> toJson() => {
    'd': debut.toUtc().toIso8601String(),
    'f': fin.toUtc().toIso8601String(),
    'n': detections,
    'j': juge,
  };

  static ContactEnregistre fromJson(Map<String, dynamic> j) =>
      ContactEnregistre(
        debut: DateTime.parse(j['d'] as String).toLocal(),
        fin: DateTime.parse(j['f'] as String).toLocal(),
        detections: (j['n'] as num?)?.toInt() ?? 0,
        juge: j['j'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is ContactEnregistre &&
      other.debut == debut &&
      other.fin == fin &&
      other.detections == detections &&
      other.juge == juge;

  @override
  int get hashCode => Object.hash(debut, fin, detections, juge);
}

/// **La mémoire des présences passées, par ami.**
///
/// ## 🔴 Pourquoi ce fichier existe
///
/// Les règles décidées par Jay le 2026-08-30 ne se prononcent plus sur une
/// présence isolée : elles regardent **deux heures avant et une heure après**.
/// Or l'app ne gardait *rien* — `PresqueLedger` n'était qu'un ensemble
/// d'identifiants en mémoire vive, sans durée, sans date, effacé à chaque
/// redémarrage. Il n'y avait donc aucun moyen de répondre à *« avez-vous passé
/// un vrai moment ensemble tout à l'heure ? »*.
///
/// ## ⚠️ Sur le DISQUE, et ce n'est pas du confort
///
/// La fenêtre d'après dure une heure : le verdict du presque se rend donc
/// **après** que l'app a eu toutes les chances d'être fermée et rouverte. Une
/// mémoire vive aurait perdu exactement les contacts qu'elle doit juger.
///
/// ## ⚠️ Ce que ce carnet ne fait PAS
///
/// Il ne décide de rien. Il ne connaît ni les seuils, ni les notifications, ni
/// la radio : il range des contacts et les oublie quand ils sont trop vieux.
/// La décision vit dans [WaveRules], qui est pure. C'est ce qui rend les deux
/// éprouvables séparément.
class PresenceBook {
  PresenceBook({Directory? directory, DateTime Function()? clock})
    : _override = directory,
      _clock = clock ?? DateTime.now;

  final Directory? _override;
  final DateTime Function() _clock;

  Directory? _root;
  Map<String, List<ContactEnregistre>>? _cache;

  static const _fichier = 'presences.json';

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

  Future<File> _file() async =>
      File('${(await _dir()).path}${Platform.pathSeparator}$_fichier');

  Future<Map<String, List<ContactEnregistre>>> _lire() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      final file = await _file();
      if (!await file.exists()) return _cache = {};
      final raw = (jsonDecode(await file.readAsString()) as Map)
          .cast<String, dynamic>();
      return _cache = raw.map(
        (k, v) => MapEntry(k, [
          for (final e in (v as List))
            ContactEnregistre.fromJson((e as Map).cast<String, dynamic>()),
        ]),
      );
    } catch (_) {
      // Un carnet illisible ne doit pas empêcher la proximité de tourner : on
      // repart d'une mémoire vide, ce qui rend au pire un presque de trop.
      return _cache = {};
    }
  }

  Future<void> _ecrire(Map<String, List<ContactEnregistre>> map) async {
    _cache = map;
    final file = await _file();
    await file.writeAsString(
      jsonEncode(
        map.map((k, v) => MapEntry(k, [for (final c in v) c.toJson()])),
      ),
    );
  }

  /// Jette ce qui est trop vieux pour que [WaveRules] ait encore à le lire.
  ///
  /// ⚠️ **Le seuil vient de la règle, il n'est pas recopié ici.** Un carnet qui
  /// taille plus court que la fenêtre de la règle la rendrait fausse en
  /// silence : elle lirait un historique amputé et conclurait « rien avant ».
  Map<String, List<ContactEnregistre>> _elaguer(
    Map<String, List<ContactEnregistre>> map,
  ) {
    final limite = _clock().subtract(WaveRules.memoire);
    final out = <String, List<ContactEnregistre>>{};
    for (final entry in map.entries) {
      final gardes = [
        for (final c in entry.value)
          if (c.fin.isAfter(limite)) c,
      ];
      if (gardes.isNotEmpty) out[entry.key] = gardes;
    }
    return out;
  }

  /// L'historique des présences avec [userId], **sans** [sauf].
  ///
  /// [sauf] : le contact qu'on est en train de juger. Le laisser dedans le
  /// ferait se disqualifier lui-même dès qu'il dépasse un seuil.
  Future<List<Presence>> historique(String userId, {Presence? sauf}) async {
    final map = await _lire();
    return [
      for (final c in map[userId] ?? const <ContactEnregistre>[])
        if (sauf == null || c.presence != sauf) c.presence,
    ];
  }

  /// Enregistre un contact terminé.
  Future<void> noter(
    String userId, {
    required Presence contact,
    required int detections,
  }) async {
    final map = Map<String, List<ContactEnregistre>>.from(await _lire());
    final liste = [...?map[userId]]
      ..removeWhere((c) => c.presence == contact)
      ..add(
        ContactEnregistre(
          debut: contact.debut,
          fin: contact.fin,
          detections: detections,
          juge: false,
        ),
      );
    map[userId] = liste;
    await _ecrire(_elaguer(map));
  }

  /// Les contacts dont le verdict du presque est **mûr** et pas encore rendu.
  ///
  /// ⚠️ **Rendu avec l'historique de chacun**, pour que l'appelant n'ait pas à
  /// relire le carnet une fois par contact — et surtout pour qu'il ne puisse
  /// pas le relire avec une autre définition de « l'historique de ce contact ».
  Future<List<({String userId, Presence contact, List<Presence> historique})>>
  aJuger() async {
    final map = await _lire();
    final maintenant = _clock();
    final out =
        <({String userId, Presence contact, List<Presence> historique})>[];
    for (final entry in map.entries) {
      for (final c in entry.value) {
        if (c.juge) continue;
        if (!WaveRules.verdictPret(c.presence, maintenant)) continue;
        out.add((
          userId: entry.key,
          contact: c.presence,
          historique: [
            for (final autre in entry.value)
              if (autre.presence != c.presence) autre.presence,
          ],
        ));
      }
    }
    return out;
  }

  /// Ce contact a reçu son verdict : on ne le rejugera plus.
  ///
  /// ⚠️ **Marqué quel que soit le verdict.** « Pas de presque » est une réponse
  /// aussi définitive que « presque » : sans cette marque, un contact refusé
  /// serait rejugé à chaque tour, pour toujours.
  Future<void> marquerJuge(String userId, Presence contact) async {
    final map = Map<String, List<ContactEnregistre>>.from(await _lire());
    final liste = map[userId];
    if (liste == null) return;
    map[userId] = [
      for (final c in liste)
        if (c.presence == contact) c.juger() else c,
    ];
    await _ecrire(_elaguer(map));
  }

  /// Oublie tout — bascule de compte, ou remise à zéro.
  Future<void> clear() async {
    _cache = null;
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
