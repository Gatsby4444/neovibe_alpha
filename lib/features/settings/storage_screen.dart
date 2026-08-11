import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/prefs.dart';
import '../cards/card_media_cache.dart';
import '../../core/content/content_media_cache.dart';

/// Gestion du stockage local des cards (consigne Jay 2026-07-13, C4 option
/// a) : occupation, espace alloué réglable, emplacement affiché, vidage —
/// le stockage réel reste dans l'espace PRIVÉ de l'app, illisible par les
/// autres applications.
class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  ({int ownBytes, int othersBytes, String path})? _usage;
  ({int ownBytes, int othersBytes})? _spineUsage;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final usage = await ref.read(cardMediaCacheProvider).usage();
    final stories = await ref.read(contentMediaCacheProvider).usage();
    if (mounted) {
      setState(() {
        _usage = usage;
        _spineUsage = stories;
      });
    }
  }

  String _fmt(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} Go';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} Ko';
  }

  String _fmtQuota(int mb) =>
      mb >= 1024 ? '${(mb / 1024).toStringAsFixed(0)} Go' : '$mb Mo';

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(ownCardsQuotaMbProvider);
    final usage = _usage;
    final quotaBytes = quota * 1024 * 1024;

    return Scaffold(
      appBar: AppBar(title: const Text('Stockage des Vibes')),
      body: ListView(
        children: [
          const _Header('Mes Vibes (copies locales)'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.style),
            title: Text(
              usage == null
                  ? 'Calcul…'
                  : '${_fmt(usage.ownBytes)} sur ${_fmtQuota(quota)} alloués',
            ),
            subtitle: usage == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (usage.ownBytes / quotaBytes).clamp(0.0, 1.0),
                        minHeight: 6,
                      ),
                    ),
                  ),
          ),
          ListTile(
            dense: true,
            title: Text('Espace alloué : ${_fmtQuota(quota)}'),
            subtitle: Slider(
              value: OwnCardsQuotaMb.choices
                  .indexOf(quota)
                  .clamp(0, OwnCardsQuotaMb.choices.length - 1)
                  .toDouble(),
              min: 0,
              max: (OwnCardsQuotaMb.choices.length - 1).toDouble(),
              divisions: OwnCardsQuotaMb.choices.length - 1,
              label: _fmtQuota(quota),
              onChanged: (v) => ref
                  .read(ownCardsQuotaMbProvider.notifier)
                  .set(OwnCardsQuotaMb.choices[v.round()]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Tes cards sont gardées sur ton téléphone pour s\'ouvrir '
              'instantanément, sans réseau. Au-delà de l\'espace alloué, les '
              'plus anciennes repassent en cloud (re-téléchargées au besoin).',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
          ),
          const Divider(),
          const _Header('Cache des Vibes reçues'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.cached),
            title: Text(
              usage == null
                  ? 'Calcul…'
                  : '${_fmt(usage.othersBytes)} sur 200 Mo max',
            ),
            subtitle: const Text(
              'Préchargement des faces pour un retournement fluide. Purgé '
              'automatiquement : cards épuisées immédiatement, le reste au '
              'plus tard après 24 h.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const Divider(),
          const _Header('Stories et publications'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.auto_awesome),
            title: Text(
              _spineUsage == null
                  ? 'Calcul…'
                  : '${_fmt(_spineUsage!.ownBytes)} pour les miennes · '
                        '${_fmt(_spineUsage!.othersBytes)} en cache',
            ),
            subtitle: const Text(
              'Espace séparé de celui des Vibes envoyées : ces contenus n\'ont '
              'pas de budget de vues. Les stories y sont effacées à leur '
              'expiration, les publications restent.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (_spineUsage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton(
                onPressed: () async {
                  await ref.read(contentMediaCacheProvider).clear();
                  await _refresh();
                },
                child: const Text(
                  'Vider le stockage des stories et publications',
                ),
              ),
            ),
          const Divider(),
          if (usage != null)
            ListTile(
              dense: true,
              leading: const Icon(Icons.folder, size: 18),
              title: const Text('Emplacement', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                '${usage.path}\n(stockage privé de l\'app — illisible par '
                'les autres applications)',
                style: TextStyle(color: context.muted, fontSize: 11),
              ),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await ref.read(cardMediaCacheProvider).clearOwn();
                      await _refresh();
                    },
                    child: const Text('Vider mes copies locales'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await ref.read(cardMediaCacheProvider).clearOthers();
                      await _refresh();
                    },
                    child: const Text('Vider le cache'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Vider ne supprime aucune card : tout reste disponible depuis '
              'le cloud.',
              style: TextStyle(color: context.faint, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}
