import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_repository.dart';
import 'evidence_view.dart';

/// **La console** : connexion, puis quatre onglets — Signalements, Comptes,
/// Événements, Journal — et une ligne de compteurs. Sobre : des tables, des
/// boutons, un motif obligatoire à chaque geste. Tout geste laisse une ligne
/// au journal (le serveur s'en charge).
class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NeoVibe — Administration',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF444444),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      home: const _Gate(),
    );
  }
}

class _Gate extends ConsumerWidget {
  const _Gate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) return const _Login();
        final admin = ref.watch(amIAdminProvider);
        return admin.when(
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (e, _) => _Message('Erreur : $e'),
          data: (ok) => ok
              ? const _Console()
              : const _Message(
                  'Ce compte n\'est pas administrateur.',
                  signOut: true,
                ),
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.signOut = false});
  final String text;
  final bool signOut;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text),
          if (signOut) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => Supabase.instance.client.auth.signOut(),
              child: const Text('Se déconnecter'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _Login extends StatefulWidget {
  const _Login();

  @override
  State<_Login> createState() => _LoginState();
}

class _LoginState extends State<_Login> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  var _busy = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'NeoVibe — Administration',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _email,
                    decoration: const InputDecoration(labelText: 'E-mail'),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _password,
                    decoration: const InputDecoration(
                      labelText: 'Mot de passe',
                    ),
                    obscureText: true,
                    onSubmitted: (_) => _go(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _go,
                    child: const Text('Entrer'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Console extends ConsumerWidget {
  const _Console();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(adminStatsProvider).value;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('NeoVibe — Administration'),
          actions: [
            if (stats != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: Text(
                    '${stats['users']} comptes · ${stats['suspended']} suspendus · '
                    '${stats['open_reports']} signalements ouverts · '
                    '${stats['open_events']} événements en cours · '
                    '${stats['contents']} contenus · '
                    '${stats['actions_24h']} actions / 24 h',
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Se déconnecter',
              onPressed: () => Supabase.instance.client.auth.signOut(),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Signalements'),
              Tab(text: 'Comptes'),
              Tab(text: 'Événements'),
              Tab(text: 'Journal'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_Reports(), _Users(), _Events(), _Journal()],
        ),
      ),
    );
  }
}

/// Demande un motif ; nul si l'admin renonce.
Future<String?> _motif(BuildContext context, String titre) async {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(titre),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Motif (journalisé)'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, c.text.trim()),
          child: const Text('Confirmer'),
        ),
      ],
    ),
  );
}

void _erreur(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
}

// ---------------------------------------------------------------------------
// Signalements
// ---------------------------------------------------------------------------

class _Reports extends ConsumerStatefulWidget {
  const _Reports();

  @override
  ConsumerState<_Reports> createState() => _ReportsState();
}

class _ReportsState extends ConsumerState<_Reports> {
  var _status = 'open';

  @override
  Widget build(BuildContext context) {
    final reports = ref.watch(adminReportsProvider(_status));
    final repo = ref.read(adminRepositoryProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'open', label: Text('Ouverts')),
              ButtonSegment(value: 'resolved', label: Text('Traités')),
              ButtonSegment(value: 'dismissed', label: Text('Sans suite')),
            ],
            selected: {_status},
            onSelectionChanged: (s) => setState(() => _status = s.first),
          ),
        ),
        Expanded(
          child: reports.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) => list.isEmpty
                ? const Center(child: Text('Rien.'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final r = list[i];
                      final kind = r['kind'] as String;
                      final open = r['status'] == 'open';
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: ListTile(
                          leading: Icon(switch (kind) {
                            'content' => Icons.image_outlined,
                            // Vibe du Drop / Vibe envoyée (2026-09-25).
                            'drop_vibe' || 'sent_vibe' => Icons.style_outlined,
                            _ => Icons.person_outline,
                          }),
                          title: Text(
                            '${r['reason']} — '
                            '${switch (kind) {
                              'content' => 'contenu (${r['content_context'] ?? 'supprimé'}) de',
                              'drop_vibe' => 'Vibe du Drop${r['content_id'] == null ? ' (supprimée)' : ''} de',
                              'sent_vibe' => 'Vibe envoyée${r['content_id'] == null ? ' (supprimée)' : ''} de',
                              _ => 'compte',
                            }} '
                            '${r['target_name'] ?? '?'}'
                            '${r['target_suspended'] == true ? ' · SUSPENDU' : ''}',
                          ),
                          subtitle: Text(
                            'Par ${r['reporter_name']} · ${r['created_at']}'
                            '${(r['details'] as String?)?.isNotEmpty == true ? '\n${r['details']}' : ''}',
                          ),
                          isThreeLine: true,
                          trailing: open
                              ? Wrap(
                                  spacing: 4,
                                  children: [
                                    // Le média signalé, sous scellé tant
                                    // que le signalement est ouvert — même
                                    // supprimé par son auteur (2026-09-25).
                                    if (kind != 'profile')
                                      TextButton(
                                        onPressed: () => showEvidence(
                                          context,
                                          kind: kind,
                                          reportId: r['id'] as String,
                                        ),
                                        child: const Text('Voir la preuve'),
                                      ),
                                    if (kind == 'content' &&
                                        r['content_id'] != null)
                                      TextButton(
                                        onPressed: () async {
                                          final m = await _motif(
                                            context,
                                            'Retirer ce contenu ?',
                                          );
                                          if (m == null) return;
                                          try {
                                            await repo.deleteContent(
                                              r['content_id'] as String,
                                              m,
                                            );
                                          } catch (e) {
                                            if (context.mounted) {
                                              _erreur(context, e);
                                            }
                                          }
                                        },
                                        child: const Text('Retirer'),
                                      ),
                                    if (r['target_user'] != null &&
                                        r['target_suspended'] != true)
                                      TextButton(
                                        onPressed: () async {
                                          final m = await _motif(
                                            context,
                                            'Suspendre ${r['target_name']} ?',
                                          );
                                          if (m == null) return;
                                          try {
                                            await repo.suspend(
                                              r['target_user'] as String,
                                              m,
                                            );
                                            await repo.resolveReport(
                                              kind,
                                              r['id'] as String,
                                              dismiss: false,
                                              note: m,
                                            );
                                          } catch (e) {
                                            if (context.mounted) {
                                              _erreur(context, e);
                                            }
                                          }
                                        },
                                        child: const Text('Suspendre'),
                                      ),
                                    TextButton(
                                      onPressed: () async {
                                        final m = await _motif(
                                          context,
                                          'Classer sans suite ?',
                                        );
                                        if (m == null) return;
                                        try {
                                          await repo.resolveReport(
                                            kind,
                                            r['id'] as String,
                                            dismiss: true,
                                            note: m,
                                          );
                                        } catch (e) {
                                          if (context.mounted) {
                                            _erreur(context, e);
                                          }
                                        }
                                      },
                                      child: const Text('Sans suite'),
                                    ),
                                  ],
                                )
                              : null,
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Comptes
// ---------------------------------------------------------------------------

class _Users extends ConsumerStatefulWidget {
  const _Users();

  @override
  ConsumerState<_Users> createState() => _UsersState();
}

class _UsersState extends ConsumerState<_Users> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(adminUsersProvider(_query));
    final repo = ref.read(adminRepositoryProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Pseudo ou tag',
            ),
            onSubmitted: (v) => setState(() => _query = v.trim()),
          ),
        ),
        Expanded(
          child: users.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) => ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final u = list[i];
                final suspended = u['suspended_at'] != null;
                return ListTile(
                  leading: Icon(
                    suspended ? Icons.block : Icons.person_outline,
                    color: suspended
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                  title: Text(
                    '${u['display_name']}'
                    '${u['tag_name'] != null ? ' · @${u['tag_name']}' : ''}'
                    '${u['is_admin'] == true ? ' · admin' : ''}',
                  ),
                  subtitle: Text(
                    'Créé ${u['created_at']} · ${u['reports']} signalement(s)'
                    '${suspended ? ' · suspendu ${u['suspended_at']} — ${u['suspended_reason'] ?? ''}' : ''}',
                  ),
                  trailing: suspended
                      ? TextButton(
                          onPressed: () async {
                            final m = await _motif(context, 'Rétablir ?');
                            if (m == null) return;
                            try {
                              await repo.unsuspend(u['id'] as String, m);
                            } catch (e) {
                              if (context.mounted) _erreur(context, e);
                            }
                          },
                          child: const Text('Rétablir'),
                        )
                      : TextButton(
                          onPressed: () async {
                            final m = await _motif(
                              context,
                              'Suspendre ${u['display_name']} ?',
                            );
                            if (m == null) return;
                            try {
                              await repo.suspend(u['id'] as String, m);
                            } catch (e) {
                              if (context.mounted) _erreur(context, e);
                            }
                          },
                          child: const Text('Suspendre'),
                        ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Événements
// ---------------------------------------------------------------------------

class _Events extends ConsumerWidget {
  const _Events();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(adminEventsProvider);
    final repo = ref.read(adminRepositoryProvider);
    return events.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) => list.isEmpty
          ? const Center(child: Text('Aucun événement en cours.'))
          : ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final e = list[i];
                return ListTile(
                  leading: Icon(
                    e['auto_created'] == true
                        ? Icons.auto_awesome
                        : e['kind'] == 'venue'
                        ? Icons.storefront
                        : e['kind'] == 'open'
                        ? Icons.celebration
                        : Icons.group,
                  ),
                  title: Text('${e['title']} (${e['kind']})'),
                  subtitle: Text(
                    'Par ${e['creator_name'] ?? '?'} · ouvert ${e['opened_at']}'
                    '${e['scheduled_end_at'] != null ? ' · ferme ${e['scheduled_end_at']}' : ''}'
                    ' · ${e['present_count']} présents · ${e['vibe_count']} Vibes',
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      final m = await _motif(context, 'Fermer cet événement ?');
                      if (m == null) return;
                      try {
                        await repo.closeEvent(e['id'] as String, m);
                      } catch (err) {
                        if (context.mounted) _erreur(context, err);
                      }
                    },
                    child: const Text('Fermer'),
                  ),
                );
              },
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Journal
// ---------------------------------------------------------------------------

class _Journal extends ConsumerWidget {
  const _Journal();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.watch(adminActionsProvider);
    return actions.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) => list.isEmpty
          ? const Center(child: Text('Aucune action.'))
          : ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final a = list[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.history),
                  title: Text(
                    '${a['action']}'
                    '${a['target_name'] != null ? ' — ${a['target_name']}' : ''}'
                    '${a['target_content'] != null ? ' — contenu ${a['target_content']}' : ''}'
                    '${a['target_event'] != null ? ' — événement ${a['target_event']}' : ''}',
                  ),
                  subtitle: Text(
                    '${a['admin_name']} · ${a['created_at']}'
                    '${(a['reason'] as String?)?.isNotEmpty == true ? ' · ${a['reason']}' : ''}',
                  ),
                );
              },
            ),
    );
  }
}
