import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/theme.dart';

/// Journal de l'app (développeur) — demandé par Jay le 2026-08-10.
///
/// Même intention que le journal caméra, mais étendu : gestes de l'utilisateur,
/// réactions de l'app, échanges serveur, erreurs. Jay teste sur téléphone sans
/// PC branché : il copie le journal et me le colle.
///
/// L'écran lit le FICHIER, pas seulement la mémoire — donc ce qui précède un
/// crash reste consultable après redémarrage.
class AppLogScreen extends StatefulWidget {
  const AppLogScreen({super.key});

  @override
  State<AppLogScreen> createState() => _AppLogScreenState();
}

class _AppLogScreenState extends State<AppLogScreen> {
  /// Niveaux affichés. Tout est coché au départ : on filtre pour chercher, pas
  /// pour découvrir.
  final _shown = AppLogLevel.values.toSet();

  String _raw = '';
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final text = await AppLog.instance.readAll();
    if (!mounted) return;
    setState(() {
      _raw = text;
      _loading = false;
    });
  }

  List<String> get _lines {
    if (_raw.isEmpty) return const [];
    final tags = _shown.map((l) => '[${l.tag}]').toSet();
    return _raw
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .where((l) => tags.any(l.contains))
        .toList();
  }

  Future<void> _copy() async {
    // On copie ce qui est AFFICHÉ : filtrer puis copier tout serait un piège.
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${_lines.length} lignes copiées — colle-les dans le chat',
        ),
      ),
    );
  }

  Future<void> _clear() async {
    await AppLog.instance.clear();
    AppLog.instance.app('journal effacé — nouveau test');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Journal de l\'app'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recharger',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copier',
            onPressed: lines.isEmpty ? null : _copy,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Effacer',
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final level in AppLogLevel.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_label(level)),
                      selected: _shown.contains(level),
                      onSelected: (on) => setState(() {
                        on ? _shown.add(level) : _shown.remove(level);
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        _raw.isEmpty
                            ? 'Journal vide. Utilise l\'app, puis reviens ici.'
                            : 'Aucune ligne pour les filtres choisis.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.muted),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: lines.length,
                    itemBuilder: (_, i) {
                      final line = lines[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            height: 1.35,
                            color: _color(context, line),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static String _label(AppLogLevel level) => switch (level) {
    AppLogLevel.action => 'Actions',
    AppLogLevel.app => 'App',
    AppLogLevel.server => 'Serveur',
    AppLogLevel.error => 'Erreurs',
  };

  /// Les erreurs doivent sauter aux yeux dans un mur de texte ; le reste se
  /// distingue sans crier.
  Color _color(BuildContext context, String line) {
    if (line.contains('[ERR]')) return Theme.of(context).colorScheme.error;
    if (line.contains('[SRV]')) return Theme.of(context).colorScheme.primary;
    if (line.contains('[ACT]')) return Theme.of(context).colorScheme.onSurface;
    return context.muted;
  }
}
