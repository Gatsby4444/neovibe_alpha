import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Nature d'une entrée du journal. Sert au filtrage à l'écran et au préfixe
/// dans le texte copié.
enum AppLogLevel {
  /// Geste de l'utilisateur : appui, navigation, choix d'un réglage.
  action('ACT'),

  /// Réaction de l'app : ouverture d'écran, bascule d'état, décision interne.
  app('APP'),

  /// Échange avec le serveur : appel parti, réponse reçue, durée.
  server('SRV'),

  /// Échec, quelle qu'en soit l'origine.
  error('ERR');

  const AppLogLevel(this.tag);
  final String tag;
}

class AppLogEntry {
  AppLogEntry(this.level, this.message, this.details) : at = DateTime.now();

  final DateTime at;
  final AppLogLevel level;
  final String message;
  final String? details;

  String get line {
    final t = at.toLocal();
    final stamp =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    final suffix = details == null || details!.isEmpty ? '' : ' — $details';
    return '$stamp [${level.tag}] $message$suffix';
  }
}

/// Journal d'application (développeur) — **tout** ce que fait l'utilisateur, ce
/// que l'app en fait, ce que le serveur répond, et les erreurs.
///
/// Demandé par Jay le 2026-08-10, sur le modèle du journal caméra : il teste
/// sur un téléphone sans PC branché, donc sans `logcat`. Le journal survit au
/// crash — il suffit de rouvrir l'app, d'aller dans Réglages → Développeur →
/// Journal de l'app, et de copier.
///
/// ─── Ce qui est capté sans rien instrumenter ────────────────────────────────
///
/// - les **échecs de providers** (`AppLogProviderObserver`) : comme presque tous
///   les appels serveur passent par un `FutureProvider` ou un `StreamProvider`,
///   cela couvre l'essentiel des erreurs réseau et de permissions ;
/// - la **navigation** (`AppLogNavigatorObserver`) : le parcours de l'utilisateur ;
/// - les **erreurs Flutter et Dart non rattrapées** (branchées dans `main`).
///
/// Le reste s'ajoute au fil de l'eau avec [action], [app], [server] et [error] —
/// une ligne par point d'intérêt.
///
/// ⚠️ **Ne jamais y écrire de secret** : ni jeton, ni clé de chiffrement, ni mot
/// de passe. Ce journal est fait pour être copié-collé dans une conversation.
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  /// Ce que l'écran affiche. Plafonné : un journal qui gonfle sans fin finit
  /// par peser sur la mémoire d'une app caméra, déjà à l'étroit.
  static const _maxEntries = 2000;

  /// Au-delà, le fichier est réduit de moitié à l'ouverture suivante.
  static const _maxFileBytes = 1024 * 1024;

  final _entries = ListQueue<AppLogEntry>();
  final _pending = <AppLogEntry>[];
  Timer? _flush;
  File? _file;

  /// Notifie l'écran sans imposer de dépendance à Riverpod ici.
  final _listeners = <void Function()>[];

  UnmodifiableListView<AppLogEntry> get entries =>
      UnmodifiableListView(_entries);

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);

  void action(String message, [String? details]) =>
      _add(AppLogLevel.action, message, details);
  void app(String message, [String? details]) =>
      _add(AppLogLevel.app, message, details);
  void server(String message, [String? details]) =>
      _add(AppLogLevel.server, message, details);
  void error(String message, [String? details]) =>
      _add(AppLogLevel.error, message, details);

  void _add(AppLogLevel level, String message, String? details) {
    final entry = AppLogEntry(level, message, details);
    _entries.addLast(entry);
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    _pending.add(entry);
    for (final l in List.of(_listeners)) {
      l();
    }

    // Une erreur peut être suivie d'un crash : elle part sur le disque tout de
    // suite, sans attendre le regroupement.
    if (level == AppLogLevel.error) {
      unawaited(_writePending());
    } else {
      _flush ??= Timer(const Duration(seconds: 2), () {
        _flush = null;
        unawaited(_writePending());
      });
    }
  }

  Future<File> _openFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/neovibe_app.log');
    if (!await file.exists()) {
      await file.create(recursive: true);
    } else if (await file.length() > _maxFileBytes) {
      // On garde la MOITIÉ LA PLUS RÉCENTE : c'est ce qui précède le bug qu'on
      // cherche, jamais le début de session.
      final text = await file.readAsString();
      await file.writeAsString(text.substring(text.length ~/ 2));
    }
    return _file = file;
  }

  Future<void> _writePending() async {
    if (_pending.isEmpty) return;
    final batch = List.of(_pending);
    _pending.clear();
    try {
      final file = await _openFile();
      await file.writeAsString(
        '${batch.map((e) => e.line).join('\n')}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Un journal qui échoue ne doit JAMAIS faire tomber l'app : c'est un
      // outil de diagnostic, pas une fonctionnalité.
    }
  }

  /// Le journal complet, disque compris — donc ce qui précède le dernier
  /// démarrage, seul moyen de lire ce qui a mené à un crash.
  Future<String> readAll() async {
    await _writePending();
    try {
      final file = await _openFile();
      return (await file.readAsString()).trim();
    } catch (e) {
      return _entries.map((e) => e.line).join('\n');
    }
  }

  Future<void> clear() async {
    _entries.clear();
    _pending.clear();
    try {
      final file = await _openFile();
      await file.writeAsString('');
    } catch (_) {}
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// Marque de début de session, pour repérer les redémarrages dans une trace
  /// longue — un journal couvre plusieurs lancements.
  ///
  /// Pas de numéro de version : le seul moyen fiable de le lire serait
  /// `package_info_plus`, un plugin **natif** qu'il faudrait porter sur iOS et
  /// inscrire au catalogue `docs/parties-natives-par-os.md`. Cher pour une
  /// ligne de confort — la version se déduit de l'APK installé.
  void sessionStart() {
    _add(
      AppLogLevel.app,
      '——— démarrage de l\'app ———',
      DateTime.now().toLocal().toString(),
    );
  }
}
