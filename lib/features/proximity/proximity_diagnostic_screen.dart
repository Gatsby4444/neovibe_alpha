import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'dart:async';

import 'net/ble_radio.dart';
import 'net/distance_estimate.dart';
import 'net/peer_session.dart';
import 'ping_store.dart';
import 'presence_feed.dart';
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
class ProximityDiagnosticScreen extends ConsumerStatefulWidget {
  const ProximityDiagnosticScreen({super.key});

  @override
  ConsumerState<ProximityDiagnosticScreen> createState() =>
      _ProximityDiagnosticScreenState();
}

class _ProximityDiagnosticScreenState
    extends ConsumerState<ProximityDiagnosticScreen> {
  /// ⚠️ **Le canal natif vient du provider depuis le 2026-08-28.** Cet écran
  /// construisait son propre `BleRadio()` : un client qui va lui-même en
  /// cuisine. La classe est sans état, donc rien ne cassait — mais la règle
  /// « un seul chemin vers le natif » ne peut pas s'énoncer si chacun peut
  /// s'en fabriquer un.
  BleRadio get _radio => ref.read(bleRadioProvider);
  Map<String, dynamic> _stats = const {};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await _radio.stats();
      if (mounted) setState(() => _stats = s);
    } catch (_) {
      // Le service ne tourne pas : les compteurs restent a leur derniere
      // valeur connue plutot que de sauter a zero, ce qui ferait croire a une
      // remise a zero de la radio.
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(proximitySupervisorProvider);
    final peers = ref.watch(presenceProvider);

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
              _Texte('Croiser mes amis', '${runtime.wantsFriends}'),
              _Texte('Visible des inconnus', '${runtime.wantsDiscovery}'),
              _Texte('Intention relue du disque', '${runtime.intentLoaded}'),
              _Texte('État publié par le natif', _nommer(runtime.status)),
            ],
          ),
          _Bloc(
            titre: 'Ce que la radio a REÇU',
            enfants: [
              _Texte(
                'Annonces BLE (toutes apps)',
                '${_stats['rawScans'] ?? '—'}',
              ),
              _Texte('dont NeoVibe', '${_stats['neoScans'] ?? '—'}'),
              // ⚠️ **Le désaccord de version doit se VOIR.** Deux appareils de
              // versions différentes ne se voient pas — c'est voulu — et sans
              // ce compteur, ce cas est indiscernable de « personne autour ».
              _Texte(
                'écartées (autre version)',
                '${_stats['otherVersionScans'] ?? '—'}',
              ),
              _Texte(
                'version du protocole',
                '${_stats['protocolVersion'] ?? '—'}',
              ),
              const SizedBox(height: 8),
              Text(
                _lireCompteurs(),
                style: TextStyle(color: context.muted, fontSize: 12),
              ),
            ],
          ),
          _Bloc(
            titre: 'Appareil et technologies de mesure',
            enfants: [
              _Texte('Modèle', '${_stats['device'] ?? '—'}'),
              _Texte('Android SDK', '${_stats['sdk'] ?? '—'}'),
              const SizedBox(height: 10),
              // ⚠️ **Demandé au système, jamais déduit d'une fiche technique.**
              //
              // Question de Jay, 2026-08-16 : « pour la distance tu as juste
              // utilisé le BLE ? ». Oui — c'est la seule radio que TOUS les
              // appareils ont. Deux autres feraient bien mieux si le matériel
              // les portait, et ces deux lignes disent lesquelles sont là.
              _Ligne(
                'UWB — précision ~10 cm',
                _stats['uwb'] == true,
                'Absent : la mesure au centimètre est hors de portée sur cet '
                    'appareil, quel que soit le code écrit.',
              ),
              _Ligne(
                'Wi-Fi RTT — précision ~1-2 m',
                _stats['wifiRtt'] == true,
                'Absent : pas de mesure de temps de vol Wi-Fi ici.',
              ),
              const SizedBox(height: 6),
              Text(
                'Le BLE, lui, est partout — c\'est pour ça qu\'on s\'appuie '
                'dessus. Il donne une bande et une tendance fiables, jamais '
                'une distance en mètres.',
                style: TextStyle(color: context.faint, fontSize: 11),
              ),
            ],
          ),
          // ⚠️ **Deux chiffres, et ce n'est pas de la coquetterie** (2026-08-28).
          //
          // Ce bloc affichait « Appareils vus (N) » à partir des sessions de
          // présence. Or **un appareil en mode parallèle crie deux jetons** —
          // un public, un privé — que rien ne peut relier : c'est la propriété
          // anti-traçage, et elle interdit de les fusionner. Il produit donc
          // deux sessions, dont une seule est nommée.
          //
          // Un seul téléphone en face affichait « Appareils vus (2) ». C'est la
          // confusion des « 13 détections » du 2026-08-25, en plus petit — et
          // sur l'instrument même qui sert à interpréter les tests.
          //
          // On ne corrige pas le compte, on le **dit** : une personne reconnue
          // et une annonce anonyme ne répondent pas à la même question.
          _Bloc(
            titre:
                'Personnes reconnues '
                '(${peers.where((p) => p.stage == PresenceStage.identified).length})'
                ' · annonces anonymes '
                '(${peers.where((p) => p.stage != PresenceStage.identified).length})',
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

  /// ⚠️ **Le chiffre le plus utile de tout cet écran.**
  ///
  /// Il sépare deux pannes que « détection active » confondait : ne rien
  /// entendre, et n'avoir personne à entendre.
  String _lireCompteurs() {
    final raw = _stats['rawScans'] as int?;
    final neo = _stats['neoScans'] as int?;
    final autreVersion = _stats['otherVersionScans'] as int? ?? 0;
    if (autreVersion > 0 && (neo ?? 0) == 0) {
      return '$autreVersion annonces NeoVibe écartées : elles parlent une AUTRE version du protocole. Les deux appareils ne sont pas à la même version — mets-les à jour ENSEMBLE.';
    }
    if (raw == null) return 'Le service ne tourne pas.';
    if (raw == 0) {
      return 'ZÉRO annonce reçue, toutes applications confondues. La radio ne '
          "te livre rien : le problème est SOUS l'app — permission, puce, ou "
          "bridage du système. Ce n'est pas la faute de l'autre appareil.";
    }
    if (neo == 0) {
      return 'La radio te livre bien des annonces ($raw), mais AUCUNE ne vient '
          "de NeoVibe. Ton écoute fonctionne : c'est la diffusion d'en face "
          "qui n'arrive pas jusqu'ici.";
    }
    return 'La chaîne est complète : $raw annonces reçues, dont $neo de '
        'NeoVibe.';
  }

  static String _nommer(RadioStatus status) => switch (status) {
    RadioUnsupported() => 'unsupported',
    RadioPermissionsMissing(:final missing) =>
      'permissionsMissing ${missing.join(", ")}',
    RadioAdapterOff() => 'adapterOff',
    RadioLocationOff() => 'locationOff (Android <= 11)',
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

class _Pair extends ConsumerWidget {
  const _Pair({required this.peer});
  final PresencePeer peer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final etat = switch (peer.stage) {
      // ⚠️ « poignée de main en cours » a disparu avec le transport BLE
      // (2026-08-27). Un pair détecté et non identifié le reste : son identité
      // ne peut plus venir que du serveur, jamais de la radio.
      PresenceStage.detected => 'détecté, identité inconnue',
      PresenceStage.identified => 'identifié',
    };
    // Le statut d'ami se dérive du carnet — la présence ne le porte plus.
    final userId = peer.userId;
    final estAmi =
        userId != null && (ref.watch(isFriendProvider(userId)).value ?? false);
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
            '$etat · ${peer.rssi.toStringAsFixed(0)} dBm'
            '${estAmi ? " · ami" : ""}',
            style: TextStyle(color: context.muted, fontSize: 12),
          ),
          // ⚠️ **La fourchette, jamais un nombre unique.** L'écart entre ses
          // deux bornes est l'information la plus honnête de cet écran : c'est
          // lui qui dit à quel point une valeur centrale ne voudrait rien dire.
          // C'est aussi ce qui permettra de trancher, relevés en main, si des
          // mètres sont un jour affichables.
          Text(
            '${peer.band.label} · estimation ${peer.distance.metersLabel} '
            '(plage ${peer.distance.range})'
            '${peer.distance.calibrated ? "" : " · puissance émise non annoncée"}'
            '${peer.trend == ProximityTrend.stable ? "" : " · ${peer.trend.label}"}',
            style: TextStyle(color: context.faint, fontSize: 11),
          ),
          // Les entrées brutes du calcul : c'est avec elles qu'on recalibrera
          // l'exposant de perte après les relevés.
          Text(
            'RSSI lissé ${peer.rssi.toStringAsFixed(1)} dBm · '
            'puissance émise ${peer.txPower == 127 ? "non annoncée" : "${peer.txPower} dBm"}',
            style: TextStyle(color: context.faint, fontSize: 11),
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
