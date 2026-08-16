import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'net/presence_tracker.dart';
import 'net/proximity_controller.dart';
import 'net/proximity_supervisor.dart';
import 'net/radio_status.dart';

/// Diagnostic de proximité — **outil de test, à retirer avant la prod**
/// (`RAPPELS.md`, section Développeur).
///
/// ## Pourquoi cet écran existe
///
/// Le 2026-08-16, le téléphone de Jay voyait la tablette, et la tablette ne
/// voyait rien. Les deux affichaient « détection active ». Rien, dans
/// l'interface, ne permettait de dire **quel sens** était en panne — or la
/// proximité a deux sens indépendants : on **diffuse** et on **écoute**.
///
/// Cet écran sépare ce que l'interface normale résume : les deux sens de la
/// radio, l'intention de l'utilisateur, et chaque appareil vu avec son état
/// d'identification et son adresse. C'est ce qui transforme « ça ne marche
/// pas » en « c'est la diffusion de cet appareil-là qui ne part pas ».
class ProximityDiagnosticScreen extends ConsumerWidget {
  const ProximityDiagnosticScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runtime = ref.watch(proximitySupervisorProvider);
    final view = ref.watch(proximityControllerProvider).value;
    final peers = view?.peers ?? const <PresencePeer>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostic proximité')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Bloc(
            titre: 'Les deux sens de la radio',
            enfants: [
              _Ligne(
                'Diffusion (on me voit)',
                runtime.status.isBroadcasting,
                'Sans elle, personne ne peut te détecter, même si tout le '
                    'reste marche.',
              ),
              _Ligne(
                'Détection (je vois)',
                runtime.status.isDetecting,
                'Sans elle, ta liste reste vide quoi qu\'il arrive.',
              ),
            ],
          ),
          _Bloc(
            titre: 'Intention et état',
            enfants: [
              _Texte('Tu veux être visible', '${runtime.wantsVisible}'),
              _Texte('Intention relue du disque', '${runtime.intentLoaded}'),
              _Texte('État publié par le natif', _nommer(runtime.status)),
            ],
          ),
          _Bloc(
            titre: 'Appareils vus (${peers.length})',
            enfants: peers.isEmpty
                ? [
                    Text(
                      'Aucun. Si la détection est active et que tu es à côté '
                      'd\'un appareil NeoVibe visible, c\'est SA diffusion '
                      'qu\'il faut regarder, pas ta détection.',
                      style: TextStyle(color: context.muted, fontSize: 12),
                    ),
                  ]
                : [for (final peer in peers) _Pair(peer: peer)],
          ),
          const SizedBox(height: 12),
          Text(
            'Lecture : deux appareils côte à côte doivent chacun voir l\'autre. '
            'Si un seul des deux voit, c\'est la DIFFUSION de celui qui n\'est '
            'pas vu qui est en cause — pas la détection de celui qui ne voit '
            'personne.',
            style: TextStyle(color: context.faint, fontSize: 12),
          ),
        ],
      ),
    );
  }

  static String _nommer(RadioStatus status) => switch (status) {
    RadioUnsupported() => 'unsupported',
    RadioPermissionsMissing(:final missing) =>
      'permissionsMissing ${missing.join(", ")}',
    RadioAdapterOff() => 'adapterOff',
    RadioIdle() => 'idle',
    RadioStarting() => 'starting',
    RadioRunning(:final advertising, :final scanning) =>
      'running(diffusion: $advertising, détection: $scanning)',
    RadioFailed(:final code, :final message) => 'failed[$code] $message',
    RadioUnknown(:final type) => 'inconnu: $type',
  };
}

class _Bloc extends StatelessWidget {
  const _Bloc({required this.titre, required this.enfants});
  final String titre;
  final List<Widget> enfants;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titre, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          ...enfants,
        ],
      ),
    ),
  );
}

class _Ligne extends StatelessWidget {
  const _Ligne(this.nom, this.ok, this.consequence);
  final String nom;
  final bool ok;
  final String consequence;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.cancel,
          size: 18,
          color: ok ? Colors.greenAccent : Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(nom),
              if (!ok)
                Text(
                  consequence,
                  style: TextStyle(color: context.muted, fontSize: 11),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Texte extends StatelessWidget {
  const _Texte(this.nom, this.valeur);
  final String nom;
  final String valeur;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(nom, style: TextStyle(color: context.muted)),
        ),
        Expanded(
          flex: 2,
          child: Text(valeur, style: const TextStyle(fontFamily: 'monospace')),
        ),
      ],
    ),
  );
}

class _Pair extends StatelessWidget {
  const _Pair({required this.peer});
  final PresencePeer peer;

  @override
  Widget build(BuildContext context) {
    final etat = switch (peer.stage) {
      PresenceStage.detected => 'détecté, identité inconnue',
      PresenceStage.identifying => 'poignée de main en cours',
      PresenceStage.identified => 'identifié',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            peer.snapshot?.displayName ?? '(anonyme)',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            '$etat · ${peer.rssi.toStringAsFixed(0)} dBm · ${peer.level.label}'
            '${peer.isFriend ? " · ami" : ""}',
            style: TextStyle(color: context.muted, fontSize: 12),
          ),
          // L'adresse est affichée exprès : c'est elle qui change quand Android
          // renouvelle la MAC, et c'est ce qui produisait deux lignes pour la
          // même personne avant la fusion par identifiant.
          Text(
            peer.address,
            style: TextStyle(
              color: context.faint,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
