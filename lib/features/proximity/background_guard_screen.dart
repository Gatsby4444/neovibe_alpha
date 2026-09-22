import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'background_guard.dart';

/// **« Pour que NeoVibe te voie écran éteint. »**
///
/// La vue de [BackgroundGuard] : elle seule sait quand déranger l'utilisateur
/// et comment lui parler. Trois étapes, dans l'ordre où elles comptent :
///
/// 1. l'exemption d'optimisation batterie d'Android — **lisible**, donc
///    affichée avec son état et un bouton qui ouvre la boîte de dialogue
///    standard ;
/// 2. sur MIUI, « Démarrage automatique » — **pas lisible** : on ouvre la
///    page et on dit quoi regarder ;
/// 3. sur MIUI, « Économiseur de batterie → Pas de restriction ».
///
/// ⚠️ On relit l'état à chaque retour dans l'app (`didChangeAppLifecycleState`)
/// : l'utilisateur revient des réglages, et l'écran doit dire la vérité du
/// moment, pas celle d'avant son départ.
class BackgroundGuardScreen extends ConsumerStatefulWidget {
  const BackgroundGuardScreen({super.key});

  @override
  ConsumerState<BackgroundGuardScreen> createState() =>
      _BackgroundGuardScreenState();
}

class _BackgroundGuardScreenState extends ConsumerState<BackgroundGuardScreen>
    with WidgetsBindingObserver {
  static const _guard = BackgroundGuard();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(backgroundGuardProvider);
    }
  }

  Future<void> _ouvre(Future<bool> Function() action, String sinon) async {
    final ok = await action();
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(sinon)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final etat = ref.watch(backgroundGuardProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Écran éteint')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Pour que NeoVibe te voie écran éteint',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'NeoVibe reconnaît tes amis à côté de toi même quand ton téléphone '
            'est dans ta poche. Pour ça, il doit rester allumé en arrière-plan '
            '— et certains téléphones arrêtent d\'eux-mêmes les apps qu\'ils '
            'ne connaissent pas. Un ou deux réglages suffisent, une seule '
            'fois.',
            style: TextStyle(color: context.muted),
          ),
          const SizedBox(height: 20),

          _Etape(
            numero: 1,
            titre: 'Optimisation de la batterie',
            detail: etat == null
                ? 'Lecture…'
                : etat.batteryExempt
                ? 'NeoVibe est autorisée à rester active. Rien à faire.'
                : 'Android peut mettre NeoVibe en sommeil. Autorise-la à '
                      'rester active : une boîte de dialogue va s\'ouvrir.',
            fait: etat?.batteryExempt,
            action: etat == null || etat.batteryExempt
                ? null
                : (
                    'Autoriser',
                    () => _ouvre(
                      _guard.requestBatteryExemption,
                      'Impossible d\'ouvrir la boîte de dialogue. Va dans '
                      'Réglages › Applis › NeoVibe › Batterie.',
                    ),
                  ),
          ),

          if (etat != null && etat.miui) ...[
            _Etape(
              numero: 2,
              titre: 'Démarrage automatique',
              detail:
                  'Sur Xiaomi, active « Démarrage automatique en arrière-plan » '
                  'pour NeoVibe. Sans ça, le téléphone interdit à NeoVibe de '
                  'redémarrer après l\'avoir arrêtée.\n'
                  'NeoVibe ne peut pas vérifier ce réglage : c\'est à toi de '
                  'regarder l\'interrupteur.',
              fait: null,
              action: etat.autostartPage
                  ? (
                      'Ouvrir',
                      () => _ouvre(
                        _guard.openAutostart,
                        'Page introuvable. Va dans Réglages › Applis › Gérer '
                        'les applis › NeoVibe.',
                      ),
                    )
                  : null,
            ),
            _Etape(
              numero: 3,
              titre: 'Économiseur de batterie',
              detail:
                  'Choisis « Pas de restriction » pour NeoVibe. Le mode '
                  '« recommandé » arrête les apps qu\'il ne connaît pas.',
              fait: etat.batteryExempt ? true : null,
              action: (
                'Ouvrir',
                () => _ouvre(
                  () async =>
                      await _guard.openBatterySaver() ||
                      await _guard.openAppDetails(),
                  'Page introuvable. Va dans Réglages › Applis › Gérer les '
                  'applis › NeoVibe › Économiseur de batterie.',
                ),
              ),
            ),
          ] else if (etat != null && !etat.batteryExempt) ...[
            const SizedBox(height: 8),
            Text(
              'Certaines marques (Huawei, Oppo, OnePlus, Samsung…) ont un '
              'réglage de plus, dans la fiche de l\'app.',
              style: TextStyle(color: context.faint, fontSize: 12),
            ),
            TextButton(
              onPressed: () => _ouvre(
                _guard.openAppDetails,
                'Impossible d\'ouvrir la fiche de l\'app.',
              ),
              child: const Text('Ouvrir la fiche de l\'app'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Etape extends StatelessWidget {
  const _Etape({
    required this.numero,
    required this.titre,
    required this.detail,
    required this.fait,
    required this.action,
  });

  final int numero;
  final String titre;
  final String detail;

  /// `true` = fait, `false` = à faire, `null` = on ne peut pas savoir.
  final bool? fait;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final icone = switch (fait) {
      true => Icon(Icons.check_circle, color: Colors.green.shade600),
      false => const Icon(Icons.error_outline, color: Colors.orange),
      null => Icon(Icons.help_outline, color: context.faint),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '$numero. $titre',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                icone,
              ],
            ),
            const SizedBox(height: 6),
            Text(detail, style: TextStyle(color: context.muted, fontSize: 13)),
            if (action != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: action!.$2,
                  child: Text(action!.$1),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Le bandeau de l'écran Ping : n'apparaît que si quelque chose de
/// **lisible** manque. Une fois l'exemption accordée il disparaît ; l'écran
/// complet reste joignable depuis Réglages pour les étapes qu'on ne peut pas
/// vérifier.
class BackgroundGuardBanner extends ConsumerWidget {
  const BackgroundGuardBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final etat = ref.watch(backgroundGuardProvider).value;
    if (etat == null || etat.ok) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: ListTile(
        leading: const Icon(Icons.battery_alert_outlined),
        title: const Text('Pour que NeoVibe te voie écran éteint'),
        subtitle: const Text(
          'Ton téléphone peut arrêter NeoVibe en arrière-plan. Un réglage '
          'suffit.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BackgroundGuardScreen()),
        ),
      ),
    );
  }
}
