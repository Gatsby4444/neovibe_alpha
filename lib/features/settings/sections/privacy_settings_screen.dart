import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import '../blocked_screen.dart';
import '../settings_common.dart';
import '../../profile/profile_repository.dart';
import '../../proximity/net/proximity_supervisor.dart';

/// Sécurité, blocages et notifications de croisement.
class PrivacySettingsScreen extends ConsumerWidget {
  const PrivacySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final runtime = ref.watch(proximitySupervisorProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sécurité et confidentialité')),
      body: ListView(
        children: [
          // ⚠️ **Ajouté le 2026-08-28, et il manquait.** Un seul interrupteur
          // commandait les deux fonctions : couper « Visible à proximité » sur
          // l'écran Ping coupait aussi le croisement des amis, donc les streaks
          // et le « presque ». Ce sont deux choses différentes (consigne de
          // Jay), elles ont maintenant deux réglages.
          const SettingsHeader('Proximité'),
          SwitchListTile(
            title: const Text('Croiser mes amis'),
            subtitle: const Text(
              'Ton téléphone reconnaît tes amis quand vous vous croisez, même '
              'application fermée. Rien n\'est envoyé à personne d\'autre : le '
              'code émis n\'est lisible que par tes amis. Nécessaire aux '
              'streaks et au « presque ».',
            ),
            value: runtime.wantsFriends,
            // Inerte tant que l'intention n'est pas relue du disque : sinon
            // l'interrupteur s'affiche éteint puis saute, et qui voit ça le
            // rebascule — donc coupe ce qu'il voulait garder.
            onChanged: runtime.intentLoaded
                ? (v) => ref
                      .read(proximitySupervisorProvider.notifier)
                      .setFriendCrossing(v)
                : null,
          ),
          const SettingsNote(
            'Être découvrable par des INCONNUS est un réglage séparé, sur '
            'l\'écran Ping. Celui-ci ne concerne que tes amis.',
          ),
          const Divider(),
          const SettingsHeader('Personnes'),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Personnes bloquées'),
            subtitle: const Text(
              'Coupe la visibilité des contenus dans les deux sens, et empêche '
              'tout partage de vous relier',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const BlockedScreen())),
          ),
          const Divider(),
          // 🔴 **Réécrit le 2026-08-30, et le texte d'avant était devenu FAUX.**
          //
          // Il annonçait « Waves — le presque » et « par défaut tu es prévenu
          // après coup ». Cet interrupteur ne commande plus le presque depuis la
          // refonte du même jour : il commande **« Tout près »**, et le presque
          // est différé d'une heure quoi qu'il arrive (`WaveRules.apresFenetre`).
          //
          // ⚠️ **Un libellé périmé ne lève rien et ne casse rien** — il fait
          // seulement chercher un défaut là où il n'y en a pas. C'est le cas
          // exact que vise la règle « un défaut trouvé se répare tout de suite »
          // (`CLAUDE.md`, 2026-08-30) : il ne coûte que des décisions fausses,
          // et il les coûte en silence.
          const SettingsHeader('Quand un ami est tout près'),
          SwitchListTile(
            title: const Text('Me prévenir tout de suite'),
            subtitle: const Text(
              'Sans ça, le délai dépend de ton palier d\'amitié : immédiat pour '
              'un inséparable, un quart d\'heure pour un proche, trois quarts '
              'd\'heure sinon.',
            ),
            value: profile?.realtimeWaves ?? false,
            onChanged: (v) async =>
                ref.read(profileRepositoryProvider).setRealtimeWaves(v),
          ),
          const SettingsNote(
            'Le « presque » — quand vous vous êtes vraiment ratés — arrive à '
            'part, une heure après le croisement, et ce réglage ne le change '
            'pas. Son historique vit dans Profil → ♥',
          ),
        ],
      ),
    );
  }
}
