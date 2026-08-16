import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/diagnostics/app_updater.dart';
import '../../../core/diagnostics/dev_report.dart';
import '../../../core/theme.dart';

/// Mise à jour depuis l'app, et envoi des rapports au serveur.
///
/// Deux demandes de Jay du 2026-08-16, dans le même écran parce qu'elles
/// servent la même chose : **raccourcir la boucle de test**.
///
/// ⚠️ **Outils de développement** — à retirer avec la section Développeur avant
/// la prod, avec la permission `REQUEST_INSTALL_PACKAGES` et la table
/// `dev_reports` (`RAPPELS.md`).
class DeveloperUpdateScreen extends ConsumerStatefulWidget {
  const DeveloperUpdateScreen({super.key});

  @override
  ConsumerState<DeveloperUpdateScreen> createState() =>
      _DeveloperUpdateScreenState();
}

class _DeveloperUpdateScreenState extends ConsumerState<DeveloperUpdateScreen> {
  String _installed = '…';
  LatestBuild? _latest;
  String? _erreur;
  var _busy = false;
  double _progress = 0;

  /// L'APK déjà téléchargé, s'il l'est.
  ///
  /// ⚠️ **Le garder rend l'installation RÉESSAYABLE.** Fondre téléchargement et
  /// installation en un geste obligeait à retélécharger 30 Mo à chaque refus
  /// d'Android — et le refus est fréquent la première fois, puisqu'il faut
  /// d'abord autoriser l'app.
  File? _apk;
  String? _dansTelechargements;
  final _note = TextEditingController();
  final _token = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _note.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final v = await AppUpdater.installedVersion();
    final t = await AppUpdater.token();
    if (!mounted) return;
    setState(() {
      _installed = v;
      _token.text = t ?? '';
    });
    await _check();
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _erreur = null;
    });
    try {
      final latest = await AppUpdater.latest();
      if (mounted) setState(() => _latest = latest);
    } catch (e) {
      if (mounted) {
        setState(() => _erreur = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Étape 1 — télécharger, et **déposer une copie dans les Téléchargements**.
  Future<void> _telecharger() async {
    final build = _latest;
    if (build == null) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _erreur = null;
      _apk = null;
      _dansTelechargements = null;
    });
    try {
      final apk = await AppUpdater.download(
        build,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      // Le dépôt dans les Téléchargements ne doit JAMAIS faire échouer le
      // téléchargement : c'est un filet, pas le chemin principal.
      String? nom;
      try {
        nom = await AppUpdater.publishToDownloads(apk);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _apk = apk;
          _dansTelechargements = nom;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _erreur = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Étape 2 — lancer l'installateur système sur le fichier déjà téléchargé.
  Future<void> _installer() async {
    final apk = _apk;
    if (apk == null) return;
    try {
      await AppUpdater.install(apk);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            // ⚠️ On dit « Android va demander », jamais « installé » : rien ne
            // nous revient après le lancement de l'installateur, et annoncer un
            // succès qu'on ne constate pas serait un mensonge une fois sur deux.
            content: Text('Android va te demander de confirmer.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _erreur = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> _envoyer(String kind) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(devReportProvider)
          .sendEverything(note: _note.text.trim().isEmpty ? null : _note.text);
      messenger.showSnackBar(
        const SnackBar(content: Text('Rapport envoyé, daté et versionné.')),
      );
      _note.clear();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Échec : ${e.toString()}')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    final aJour =
        latest != null && !AppUpdater.isNewer(latest.version, _installed);

    return Scaffold(
      appBar: AppBar(title: const Text('Mise à jour et rapports')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------------------------------------------------- mise à jour
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Mise à jour',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Installée : $_installed',
                    style: TextStyle(color: context.muted),
                  ),
                  if (latest != null)
                    Text(
                      'Disponible : ${latest.version} · '
                      '${(latest.sizeBytes / 1048576).toStringAsFixed(1)} Mo',
                      style: TextStyle(color: context.muted),
                    ),
                  if (_erreur != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _erreur!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  if (_busy && _progress > 0) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: _progress),
                  ],
                  if (_dansTelechargements != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Déposé dans tes Téléchargements : $_dansTelechargements\n'
                      'Tu peux aussi l\'ouvrir depuis là, comme un fichier '
                      'téléchargé avec Chrome.',
                      style: TextStyle(color: context.muted, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: _busy ? null : _check,
                        child: const Text('Vérifier'),
                      ),
                      // ⚠️ **Jamais grisé.** La première version désactivait ce
                      // bouton quand l'app était à jour, en le renommant « À
                      // jour » — Jay a donc conclu qu'il n'existait pas. Un
                      // bouton grisé au libellé changé est indiscernable d'une
                      // fonction absente. Il reste donc toujours actionnable,
                      // et c'est son LIBELLÉ qui dit ce qu'il fera.
                      FilledButton.icon(
                        onPressed: _busy || latest == null
                            ? null
                            : _telecharger,
                        icon: const Icon(Icons.download),
                        label: Text(
                          latest == null
                              ? 'Télécharger'
                              : aJour
                              ? 'Retélécharger ${latest.version}'
                              : 'Télécharger ${latest.version}',
                        ),
                      ),
                      if (_apk != null)
                        FilledButton.icon(
                          onPressed: _busy ? null : _installer,
                          icon: const Icon(Icons.android),
                          label: const Text('Installer'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Deux étapes séparées : le fichier reste téléchargé si '
                    'l\'installation échoue, et « Installer » se réessaie sans '
                    'retélécharger 30 Mo. Android affichera toujours sa propre '
                    'confirmation — aucune app ne peut en installer une autre '
                    'sans elle.',
                    style: TextStyle(color: context.faint, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),

          // ------------------------------------------------------- le jeton
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Jeton GitHub (facultatif)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Inutile tant que le dépôt est public. Il le redeviendra '
                    'privé après tes tests à deux appareils : colle alors un '
                    'jeton en LECTURE SEULE. Il est rangé dans le Keystore de '
                    'cet appareil — jamais dans le dépôt, jamais dans l\'APK.',
                    style: TextStyle(color: context.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _token,
                    obscureText: true,
                    decoration: const InputDecoration(
                      hintText: 'github_pat_…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () async {
                        await AppUpdater.setToken(_token.text.trim());
                        await _check();
                      },
                      child: const Text('Enregistrer et vérifier'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ----------------------------------------------------- rapports
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Envoyer le diagnostic',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Le même contenu que « Tout copier », mais déposé sur le '
                    'serveur avec sa date, sa version et son appareil. Rien ne '
                    'part jamais tout seul.',
                    style: TextStyle(color: context.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _note,
                    decoration: const InputDecoration(
                      labelText: 'Note (ce que tu testais)',
                      hintText: 'test 6 — la tablette ne voit rien',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _envoyer('all'),
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('Tout envoyer'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
