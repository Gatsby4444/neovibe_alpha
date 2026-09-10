import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/notification_service.dart';
import '../../proximity/net/advert_capacity.dart';
import '../../proximity/net/ble_radio.dart';
import '../../proximity/net/proximity_controller.dart';
import '../gl_preview_test_screen.dart';
import '../settings_common.dart';

/// Bancs d'essai et déclencheurs manuels.
class DeveloperToolsScreen extends ConsumerWidget {
  const DeveloperToolsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Outils')),
      body: ListView(
        children: const [
          SettingsHeader('Caméra'),
          SettingsCategoryTile(
            icon: Icons.view_in_ar,
            title: 'Aperçu GPU (étape 1)',
            subtitle:
                'Rendu OpenGL testé sur UNE caméra. À vérifier : fluide ? '
                'bon sens (pas pivoté ni en miroir) ?',
            builder: _glPreview,
          ),
          Divider(),
          SettingsHeader('Ping'),
          _RemiseAZeroPing(),
          Divider(),
          SettingsHeader('Radio'),
          SettingsNote(
            'Combien de jeux d\'annonces cette puce accepte en même temps. '
            'Au-delà du plafond, chaque ami n\'est annoncé qu\'une fraction du '
            'temps — et quelqu\'un croisé trois secondes peut ne jamais être vu.\n\n'
            'L\'appareil l\'apprend tout seul, la première fois que la puce '
            'refuse. Ce bouton ne fait que provoquer l\'essai maintenant, au '
            'calme, plutôt que le jour où tu auras assez d\'amis.',
          ),
          _SondePlafondAnnonces(),
          Divider(),
          SettingsHeader('BeReal'),
          SettingsNote('En attendant le déclenchement serveur aléatoire.'),
          _DevBerealSection(),
        ],
      ),
    );
  }

  static Widget _glPreview(BuildContext _) => const GlPreviewTestScreen();
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

/// Remise à zéro du local du ping — **outil de test**.
///
/// ⚠️ Supprimer une amitié en base ne suffit pas à revenir à « ils ne se sont
/// jamais vus » : le carnet, les conversations ping, les croisements, les
/// demandes et le cooldown des waves vivent **sur l'appareil**. Sans ce bouton,
/// un test de première rencontre repart avec la moitié de la mémoire de la
/// précédente — et ce qu'on observe n'est alors pas une première rencontre.
class _RemiseAZeroPing extends ConsumerWidget {
  const _RemiseAZeroPing();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.restart_alt),
      title: const Text('Remettre le ping à zéro (local)'),
      subtitle: const Text(
        "Carnet d'amis, conversations ping, croisements, demandes et "
        'cooldown des waves. Ne touche pas au serveur.',
      ),
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remettre le ping à zéro ?'),
            content: const Text(
              'Tout ce que le ping garde sur CET appareil est effacé. Les '
              'amitiés reviendront à la prochaine synchronisation, celles '
              'qui existent encore côté serveur.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Annuler'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Effacer'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        try {
          await ref.read(proximityControllerProvider.notifier).resetLocalPing();
        } catch (_) {
          messenger.showSnackBar(
            const SnackBar(content: Text('Échec de la remise à zéro.')),
          );
          return;
        }
        messenger.showSnackBar(
          const SnackBar(content: Text('Ping remis à zéro sur cet appareil.')),
        );
      },
    );
  }
}

/// 📏 **La mesure du plafond d'annonces simultanées** (`RAPPELS.md` #113).
///
/// Le mode « parallèle » donne à chaque ami son propre jeu d'annonces, en l'air
/// tout le temps. Au-delà d'un certain nombre la puce refuse, et l'app retombe
/// en mode « cycle » : chaque jeton n'est alors en l'air que 1/N du temps.
/// Ce nombre était **supposé** (6), faute d'API pour le demander.
///
/// ⚠️ **Cet écran n'appelle pas la puce : il demande.** La mesure vit dans
/// `AdvertCapacityProbe`, côté natif ; ici on affiche ce qu'elle a constaté.
class _SondePlafondAnnonces extends ConsumerStatefulWidget {
  const _SondePlafondAnnonces();

  @override
  ConsumerState<_SondePlafondAnnonces> createState() =>
      _SondePlafondAnnoncesState();
}

class _SondePlafondAnnoncesState extends ConsumerState<_SondePlafondAnnonces> {
  var _busy = false;
  AdvertCapacityResult? _resultat;

  Future<void> _mesurer() async {
    setState(() => _busy = true);
    AdvertCapacityResult resultat;
    try {
      resultat = await ref.read(bleRadioProvider).advertCapacity();
    } catch (e) {
      // ⚠️ Un échec de canal n'est pas un zéro : il se dit.
      resultat = AdvertCapacityRefus('la mesure a échoué : $e');
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultat = resultat;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.straighten),
          title: const Text('Mesurer le plafond d\'annonces'),
          subtitle: const Text(
            'Coupe le ping d\'abord : une mesure prise pendant que la radio '
            'émet donne la place restante, pas le plafond.',
          ),
          onTap: _busy ? null : _mesurer,
        ),
        if (_resultat != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _Constat(_resultat!),
          ),
      ],
    );
  }
}

/// Ce que la sonde a constaté, tel quel. **Aucun verdict** : rapprocher le
/// chiffre mesuré du plafond de l'app est une décision produit.
class _Constat extends StatelessWidget {
  const _Constat(this.resultat);

  final AdvertCapacityResult resultat;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final r = resultat;
    if (r is AdvertCapacityRefus) {
      return Text('Pas de mesure — ${r.raison}', style: style);
    }
    r as AdvertCapacity;
    final lignes = <String>[
      'jeux acceptés     : ${r.acceptes} sur ${r.demandes} demandés',
      if (r.plafondRetenu > 0)
        'retenu pour cet appareil : ${r.plafondRetenu}'
      else
        'rien de retenu — l\'app part de ${r.plafondCourant}',
      if (r.borneParLaSonde)
        '⚠️ la sonde s\'est arrêtée d\'elle-même : la puce en tient '
            'peut-être davantage',
      if (r.expire)
        '⚠️ la pile n\'a pas répondu — absence de réponse, pas refus',
      if (r.codeRefus != null) 'code du refus     : ${r.codeRefus}',
      'annonce étendue   : ${r.extendedSupporte ? 'oui' : 'non'}',
      'taille max        : ${r.tailleMaxAnnonce} octets',
      '${r.appareil} · Android SDK ${r.sdk}',
    ];
    return SelectableText(lignes.join('\n'), style: style);
  }
}
