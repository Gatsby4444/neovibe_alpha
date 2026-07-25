import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import '../cards/native_camera.dart';
import '../cards/saved_items_screen.dart';
import '../connections/connections_repository.dart';
import '../library/library_repository.dart';
import 'camera_log_screen.dart';
import 'gl_preview_test_screen.dart';
import 'storage_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final profile = ref.watch(myProfileProvider).value;
    final client = ref.watch(supabaseProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        children: [
          const _Header('Waves — "le presque"'),
          SwitchListTile(
            title: const Text('Notifications en temps réel'),
            subtitle: const Text(
              'Par défaut, tu es prévenu après coup. Active pour savoir sur le moment.',
            ),
            value: profile?.realtimeWaves ?? false,
            onChanged: (v) async {
              await client
                  .from('profiles')
                  .update({'realtime_waves': v})
                  .eq('id', me);
              ref.invalidate(myProfileProvider);
            },
          ),
          const ListTile(
            dense: true,
            leading: Icon(Icons.waving_hand, size: 18),
            title: Text(
              'L\'historique des croisements manqués vit dans Profil → ♥',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          const Divider(),
          const _Header('Caméra'),
          SwitchListTile(
            title: const Text('Miroir de la caméra frontale'),
            subtitle: const Text(
              'Activé : tu te vois comme dans un miroir. Désactivé : comme les '
              'autres te voient (les lettres sont lisibles). Ne change que '
              'l\'aperçu, jamais la photo enregistrée.',
            ),
            value: ref.watch(selfieMirrorProvider),
            onChanged: (v) => ref.read(selfieMirrorProvider.notifier).set(v),
          ),
          const Divider(),
          const _Header('Cards'),
          SwitchListTile(
            title: const Text('Inverser le sens de retournement'),
            subtitle: const Text(
              'Change le sens dans lequel le swipe retourne une Card',
            ),
            value: ref.watch(flipDirectionInvertedProvider),
            onChanged: (v) =>
                ref.read(flipDirectionInvertedProvider.notifier).set(v),
          ),
          const _CardDefaultsSection(),
          const _Divulgation(),
          ListTile(
            leading: const Icon(Icons.bookmark),
            title: const Text('Enregistrements'),
            subtitle: const Text(
              'Ta bibliothèque privée — visible de toi seul',
            ),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SavedItemsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.storage),
            title: const Text('Stockage des Cards'),
            subtitle: const Text('Copies locales, cache et espace alloué'),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const StorageScreen())),
          ),
          const Divider(),
          const _Header('Ma bibliothèque'),
          RadioGroup<LibraryVisibility>(
            groupValue: profile?.libraryVisibility,
            onChanged: (v) async {
              if (v == null) return;
              await ref.read(libraryRepositoryProvider).setVisibility(v);
              ref.invalidate(myProfileProvider);
            },
            child: const Column(
              children: [
                RadioListTile<LibraryVisibility>(
                  value: LibraryVisibility.connections,
                  title: Text('Visible par toutes mes connexions'),
                ),
                RadioListTile<LibraryVisibility>(
                  value: LibraryVisibility.restricted,
                  title: Text('Accès restreint (liste choisie)'),
                ),
              ],
            ),
          ),
          if (profile?.libraryVisibility == LibraryVisibility.restricted)
            const _AccessListEditor(),
          const Divider(),
          const _Header('Développeur (mode test — sera retiré)'),
          SwitchListTile(
            dense: true,
            title: const Text('Anti-capture (FLAG_SECURE)'),
            subtitle: const Text(
              'DÉSACTIVÉ pendant le dev : les captures d\'écran sont '
              'possibles. Active pour tester le blocage des screenshots et '
              'du partage d\'écran. À réactiver par défaut avant la prod.',
            ),
            value: ref.watch(devSecureEnabledProvider),
            onChanged: (v) async {
              await ref.read(devSecureEnabledProvider.notifier).set(v);
              await NativeCameraController.setSecure(v);
            },
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Diagnostic caméra sur l\'aperçu'),
            subtitle: const Text(
              'Affiche résolution, rotation et état du double flux — pour '
              'diagnostiquer un aperçu distordu.',
            ),
            value: ref.watch(devCameraHudProvider),
            onChanged: (v) => ref.read(devCameraHudProvider.notifier).set(v),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Forcer la vue simple Oneshot'),
            subtitle: const Text(
              'Le Oneshot ouvre le double flux (les deux caméras) PAR DÉFAUT '
              'pour capturer les deux faces au même instant. Activer cet '
              'interrupteur force la vue simple (une caméra à la fois, prises '
              'séquentielles) — utile si le double flux se comporte mal sur '
              'l\'appareil.',
            ),
            value: ref.watch(devDualOneshotProvider),
            onChanged: (v) => ref.read(devDualOneshotProvider.notifier).set(v),
          ),
          const _DualProbeTile(),
          ListTile(
            dense: true,
            leading: const Icon(Icons.view_in_ar),
            title: const Text('Aperçu GPU (étape 1)'),
            subtitle: const Text(
              'Nouveau rendu OpenGL, testé sur UNE caméra. À vérifier : '
              'fluide ? bon sens (pas pivoté ni en miroir) ? Base du futur '
              'double flux GPU.',
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const GlPreviewTestScreen()),
            ),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.receipt_long),
            title: const Text('Journal caméra'),
            subtitle: const Text(
              'Trace détaillée (natif + Dart), conservée même après un crash. '
              'Bouton Copier pour me l\'envoyer.',
            ),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const CameraLogScreen())),
          ),
          const _DevBerealSection(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Se déconnecter'),
            onTap: () async {
              await client.auth.signOut();
              if (context.mounted) {
                Navigator.of(context).popUntil((r) => r.isFirst);
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Défauts appliqués aux nouvelles Cards (modifiables card par card à l'envoi).
class _CardDefaultsSection extends ConsumerWidget {
  const _CardDefaultsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final views = ref.watch(defaultMaxViewsProvider);
    final duration = ref.watch(defaultViewDurationProvider);
    final unlimited = duration == DefaultViewDuration.unlimited;
    final durationSlider = unlimited ? 21 : duration;

    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text('Visionnages par défaut : $views'),
          subtitle: Slider(
            value: views.toDouble(),
            min: 1,
            max: 5,
            divisions: 4,
            label: '$views',
            onChanged: (v) =>
                ref.read(defaultMaxViewsProvider.notifier).set(v.round()),
          ),
        ),
        ListTile(
          dense: true,
          title: Text(
            unlimited
                ? 'Durée de lecture par défaut : illimitée'
                : 'Durée de lecture par défaut : $duration s',
          ),
          subtitle: Slider(
            value: durationSlider.toDouble(),
            min: 1,
            max: 21,
            divisions: 20,
            label: unlimited ? '∞' : '$duration s',
            onChanged: (v) {
              final rounded = v.round();
              ref
                  .read(defaultViewDurationProvider.notifier)
                  .set(rounded == 21 ? DefaultViewDuration.unlimited : rounded);
            },
          ),
        ),
      ],
    );
  }
}

/// Règles de confidentialité des Cards, énoncées noir sur blanc (consigne Jay).
class _Divulgation extends StatelessWidget {
  const _Divulgation();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        'Dans les chats, tes Cards apparaissent comme des containers '
        'cliquables et se voient un nombre de fois et une durée limités '
        '(que tu choisis). Le container reste 24 h et le replay ne se fait '
        'qu\'avec ton accord. La Hot se voit une seule fois : son contenu '
        'disparaît, son container reste bloqué. En bibliothèque, la lecture '
        'est illimitée.',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Colors.white54),
      ),
    );
  }
}

/// Sonde double flux (dev) : ouvre les DEUX caméras de force en Camera2
/// brut, en ignorant la déclaration d'Android que CameraX respecte. Dit si le
/// matériel accepte vraiment deux flux simultanés — ou s'il évince le premier
/// (le « gel » silencieux qu'on avait en v0.5.0).
class _DualProbeTile extends StatefulWidget {
  const _DualProbeTile();

  @override
  State<_DualProbeTile> createState() => _DualProbeTileState();
}

class _DualProbeTileState extends State<_DualProbeTile> {
  var _running = false;
  Map<String, dynamic>? _result;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = null;
    });
    try {
      final res = await NativeCameraController.probeDual();
      if (mounted) setState(() => _result = res);
    } catch (e) {
      if (mounted) setState(() => _result = {'error': e.toString()});
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final works = r?['works'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          leading: _running
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.switch_camera),
          title: const Text('Tester le double flux (Camera2 brut)'),
          subtitle: const Text(
            'Ouvre les deux caméras de force, sans passer par la '
            'déclaration d\'Android. ~3 s.',
          ),
          onTap: _running ? null : _run,
        ),
        if (r != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.containsKey('error')
                        ? 'Erreur : ${r['error']}'
                        : works
                        ? 'DOUBLE FLUX POSSIBLE ✓ — le matériel accepte'
                        : 'DOUBLE FLUX REFUSÉ par le matériel',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: works ? Colors.greenAccent : Colors.redAccent,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'images arrière seule : ${r['backAlone'] ?? '—'}\n'
                    'images arrière APRÈS ouverture frontale : '
                    '${r['backAfterFront'] ?? '—'}\n'
                    'images frontale : ${r['frontFrames'] ?? '—'}\n'
                    'arrière évincée : ${r['backEvicted'] == true ? 'OUI' : 'non'}\n'
                    '${(r['errors'] as String?)?.isNotEmpty == true ? r['errors'] : ''}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Mode test développeur (temporaire) : déclenche ou programme la
/// notification BeReal, en attendant le déclenchement serveur aléatoire.
class _DevBerealSection extends ConsumerWidget {
  const _DevBerealSection();

  static const _title = 'C\'est le moment. Sois vrai.';
  static const _body = 'Tu as 5 minutes pour capturer ton instant.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifs = ref.watch(notificationServiceProvider);
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.bolt),
          title: const Text('Déclencher la notification BeReal maintenant'),
          onTap: () async {
            await notifs.show(
              NotifChannel.bereal,
              _title,
              _body,
              payload: 'bereal',
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Notification BeReal envoyée')),
              );
            }
          },
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.schedule),
          title: const Text('Programmer la notification BeReal'),
          subtitle: const Text('À la seconde près'),
          onTap: () async {
            final controller = TextEditingController(text: '30');
            final seconds = await showDialog<int>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Dans combien de secondes ?'),
                content: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: const InputDecoration(suffixText: 's'),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Annuler'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      int.tryParse(controller.text.trim()),
                    ),
                    child: const Text('Programmer'),
                  ),
                ],
              ),
            );
            if (seconds == null || seconds <= 0) return;
            await notifs.schedule(
              NotifChannel.bereal,
              _title,
              _body,
              DateTime.now().add(Duration(seconds: seconds)),
              payload: 'bereal',
              exact: true,
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Notification BeReal dans $seconds s')),
              );
            }
          },
        ),
      ],
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

/// Liste d'accès restreint : cocher les connexions autorisées.
class _AccessListEditor extends ConsumerWidget {
  const _AccessListEditor();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);
    final granted = ref.watch(libraryAccessProvider).value ?? [];

    return Column(
      children: [
        for (final connection in connections)
          _AccessTile(
            peerId: connection.peerIdFor(me),
            granted: granted.contains(connection.peerIdFor(me)),
          ),
      ],
    );
  }
}

class _AccessTile extends ConsumerWidget {
  const _AccessTile({required this.peerId, required this.granted});
  final String peerId;
  final bool granted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByIdProvider(peerId)).value;
    return CheckboxListTile(
      dense: true,
      value: granted,
      title: Text(profile?.displayName ?? '…'),
      onChanged: (v) async {
        final repo = ref.read(libraryRepositoryProvider);
        if (v == true) {
          await repo.grantAccess(peerId);
        } else {
          await repo.revokeAccess(peerId);
        }
        ref.invalidate(libraryAccessProvider);
      },
    );
  }
}
