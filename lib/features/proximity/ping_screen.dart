import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/theme.dart';
import '../../core/utils/formats.dart';
import '../connections/connections_repository.dart';
import '../library/user_library_screen.dart';
import '../stories/stories_bar.dart';
import '../stories/stories_repository.dart';
import 'geo/coarse_location.dart';
import 'net/ble_radio.dart';
import 'net/ping_beacon_service.dart';
import 'net/ping_nearby_feed.dart';
import 'net/ping_repository.dart';
import 'net/distance_estimate.dart';
import 'net/proximity_controller.dart';
import 'net/proximity_journal.dart';
import 'net/proximity_supervisor.dart';
import 'net/radio_status.dart';
import 'ping_chat_screen.dart';
import 'ping_store.dart';
import 'presence_feed.dart';

/// Le Ping — découverte 100 % locale, chiffrée d'appareil à appareil.
///
/// ## Le principe de cet écran, après la reconstruction du 2026-08-16
///
/// **Il ne dit jamais « personne » quand il ne sait pas.**
///
/// L'ancienne version affichait le même écran vide dans trois situations sans
/// rapport : Bluetooth éteint, permission manquante, et poignée de main en
/// cours. Trois causes, un seul message — donc aucun moyen, pour l'utilisateur
/// comme pour nous, de savoir laquelle. C'est le défaut qui a rendu les tests
/// de Jay ininterprétables pendant des semaines.
///
/// Ici, chaque état a sa phrase et, quand c'est possible, **son bouton**.
class PingScreen extends ConsumerStatefulWidget {
  const PingScreen({super.key});

  @override
  ConsumerState<PingScreen> createState() => _PingScreenState();
}

class _PingScreenState extends ConsumerState<PingScreen> {
  List<PingConversation> _conversations = const [];
  List<LocalEncounter> _encounters = const [];

  /// Capturé à l'initialisation : `ref` est INTERDIT dans `dispose()`.
  late final _store = ref.read(pingStoreProvider);

  @override
  void initState() {
    super.initState();
    _store.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _store.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final convs = await _store.conversations();
    final encounters = await _store.encounters();
    if (!mounted) return;
    setState(() {
      _conversations = convs;
      _encounters = encounters;
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(proximityControllerProvider).value;
    // ⚠️ **On observe la COMPOSITION de la liste, pas son contenu.** Le contenu
    // d'une tuile est observé par la tuile elle-même (`peerViewProvider`), donc
    // un pair qui se rapproche ne reconstruit que sa ligne — pas la barre de
    // stories, pas l'interrupteur, pas les autres tuiles. Règle de dissociation
    // de Jay, 2026-08-20 ; détail dans `presence_feed.dart`.
    final keys = ref.watch(presenceKeysProvider);
    final nearbyIds = ref.watch(nearbyUserIdsProvider);
    // ⚠️ L'état de la radio se lit **au superviseur**, jamais à l'instantané du
    // contrôleur : c'est le superviseur qui en est l'autorité, et son état
    // change plus souvent que la liste des pairs. Le lire ailleurs, c'est
    // rouvrir l'écart entre ce qu'on affiche et ce qui est vrai.
    final runtime = ref.watch(proximitySupervisorProvider);

    return Scaffold(
      appBar: AppBar(centerTitle: true, title: const Text('Ping')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          children: [
            StoriesBar(
              provider: crossedStoriesProvider,
              emptyHint:
                  'Pas de story des gens que tu croises. Elles n\'apparaissent '
                  'que si la personne a activé ses stories publiques.',
            ),

            SwitchListTile(
              title: const Text('Visible à proximité'),
              subtitle: Text(_sousTitreInterrupteur(runtime)),
              value: runtime.wantsVisible,
              // Tant que l'intention n'est pas relue, l'interrupteur est inerte
              // — sinon il s'afficherait éteint puis sauterait, et un
              // utilisateur qui voit ça le rebascule, donc coupe sa visibilité.
              onChanged: runtime.intentLoaded
                  ? (on) => ref
                        .read(proximitySupervisorProvider.notifier)
                        .setVisible(on)
                  : null,
            ),

            if (runtime.wantsVisible) _BandeauEtat(runtime: runtime),

            if (runtime.isLive)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Découverte 100 % locale : ton identifiant change toutes les '
                  '15 minutes et ton profil ne circule que dans un canal '
                  'chiffré, d\'appareil à appareil.',
                  style: TextStyle(color: context.faint, fontSize: 11),
                ),
              ),

            for (final request
                in view?.requests ?? const <PendingFriendRequest>[])
              _CarteDemande(request: request),

            // ⚠️ **Deux chemins coexistent volontairement, le temps du test.**
            // Le nouveau (GPS + BLE, v2) est au-dessus ; l'ancien (BLE seul) en
            // dessous. Rien n'est supprimé tant que le nouveau n'a pas tourné
            // sur appareil — règle 8 : on relève les deux sens avant de couper.
            const _TitreSection('Autour de toi'),
            ..._autourDeToiV2(ref, runtime),

            const _TitreSection('Autour de toi — ancien chemin (BLE seul)'),
            ..._autourDeToi(runtime, keys),

            if (_conversations.any((c) => nearbyIds.contains(c.peerId))) ...[
              const _TitreSection('Conversations ping'),
              for (final conv in _conversations.where(
                (c) => nearbyIds.contains(c.peerId),
              ))
                ListTile(
                  leading: const Icon(Icons.podcasts),
                  title: Text(conv.peer.displayName),
                  subtitle: Text(
                    conv.messages.isEmpty ? '' : conv.messages.last.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: conv.messages.isEmpty
                      ? null
                      : Text(
                          shortTime(conv.messages.last.at),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          PingChatScreen(peerId: conv.peerId, peer: conv.peer),
                    ),
                  ),
                ),
            ],

            if (_encounters.any((e) => !nearbyIds.contains(e.peer.userId))) ...[
              const _TitreSection('Croisés récemment'),
              for (final rencontre in _encounters.where(
                (e) => !nearbyIds.contains(e.peer.userId),
              ))
                _TuileRencontre(encounter: rencontre),
            ],

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  String _sousTitreInterrupteur(ProximityRuntime runtime) {
    if (!runtime.wantsVisible) {
      return 'Active pour rencontrer ceux qui te croisent';
    }
    if (runtime.isLive) {
      return 'Les autres membres NeoVibe proches peuvent te voir';
    }
    return 'Activée, mais en pause — voir ci-dessous';
  }

  /// La liste, et surtout **ce qu'on dit quand elle est vide**.
  List<Widget> _autourDeToi(ProximityRuntime runtime, PresenceKeys keys) {
    if (!runtime.wantsVisible) {
      return const [
        _Vide(
          icon: Icons.bluetooth_disabled,
          text:
              'Ta visibilité est coupée.\nPersonne ne peut te détecter, et tu '
              'ne détectes personne.',
        ),
      ];
    }
    if (!runtime.status.isDetecting) {
      // Le bandeau d'état dit déjà la cause exacte et propose l'action : ne pas
      // répéter « personne à proximité », qui serait faux — on ne cherche pas.
      return const [
        _Vide(
          icon: Icons.pause_circle_outline,
          text:
              'La détection est en pause. Rien n\'est cherché pour l\'instant.',
        ),
      ];
    }
    return [
      // La tuile ne reçoit qu'une ADRESSE : elle va chercher elle-même ce
      // qu'elle affiche, et ne se reconstruit que quand cela change.
      for (final address in keys.identified) _TuilePair(address: address),
      if (keys.pending > 0)
        ListTile(
          leading: const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text(
            keys.pending == 1
                ? 'Un appareil détecté'
                : '${keys.pending} appareils détectés',
          ),
          // ⚠️ C'est exactement le cas que l'ancienne version affichait comme
          // « Personne à proximité » : deux téléphones en train de se parler.
          subtitle: const Text('Vérification chiffrée en cours…'),
        ),
      if (keys.identified.isEmpty && keys.pending == 0)
        const _Vide(
          icon: Icons.radar,
          text:
              'Personne à proximité pour l\'instant.\nLes membres NeoVibe '
              'proches apparaîtront ici.',
        ),
    ];
  }
}

/// Dit **pourquoi** la détection ne tourne pas, et propose quoi faire.
class _BandeauEtat extends ConsumerWidget {
  const _BandeauEtat({required this.runtime});
  final ProximityRuntime runtime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = runtime.status;
    // ⚠️ **`isHealthy`, et non `isDetecting`.**
    //
    // Cette ligne testait `isDetecting` : le bandeau disparaissait donc dès que
    // le SCAN tournait, même si la DIFFUSION avait échoué. Le cas
    // « tu n'es pas annoncé » écrit juste en dessous était par conséquent
    // **inatteignable** — un message que le code ne pouvait pas afficher.
    //
    // Effet concret, constaté par Jay le 2026-08-16 : un appareil qui voit tout
    // le monde sans que personne ne le voie, et une interface parfaitement
    // sereine. La proximité est symétrique ; l'état affiché doit l'être aussi.
    if (status.isHealthy) return const SizedBox.shrink();

    final (String titre, String detail, String? action) = switch (status) {
      RadioAdapterOff() => (
        'Bluetooth éteint',
        'La détection de proximité a besoin du Bluetooth. Rien ne tourne tant '
            'qu\'il est coupé — et tout repartira tout seul quand tu '
            'l\'allumeras.',
        'Ouvrir les réglages',
      ),
      RadioLocationOff() => (
        'Localisation de l\'appareil éteinte',
        'Sur Android 11 et avant, le système exige que la localisation soit '
            'allumée pour détecter les appareils Bluetooth autour de toi. '
            'Ce n\'est pas une permission à accorder : c\'est l\'interrupteur '
            'de localisation du téléphone. Sans lui, la détection tourne dans '
            'le vide, sans aucune erreur.',
        'Ouvrir les réglages de localisation',
      ),
      RadioPermissionsMissing() => (
        'Permission manquante',
        'Sans elle, Android ne renvoie aucun résultat de détection — sans '
            'aucune erreur. C\'est pour ça que rien n\'apparaît.',
        'Accorder',
      ),
      RadioUnsupported() => (
        'Bluetooth LE indisponible',
        'Cet appareil n\'a pas le Bluetooth basse consommation : le Ping ne '
            'peut pas fonctionner ici.',
        null,
      ),
      RadioFailed(:final message) => (
        'Détection interrompue',
        message,
        'Réessayer',
      ),
      RadioStarting() => ('Démarrage…', 'La radio se met en route.', null),
      RadioRunning(advertising: false) => (
        'Tu n\'es pas annoncé',
        'Tu détectes les autres, mais eux ne te voient pas : le système a '
            'refusé la diffusion. Réessayer suffit le plus souvent.',
        'Réessayer',
      ),
      _ => ('En pause', 'La détection ne tourne pas.', 'Réessayer'),
    };

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                Text(
                  titre,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(detail, style: TextStyle(color: context.muted, fontSize: 12)),
            if (action != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: () => _agir(ref, status),
                  child: Text(action),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _agir(WidgetRef ref, RadioStatus status) async {
    if (status is RadioLocationOff) {
      // ⚠️ Les réglages de LOCALISATION du système, pas ceux de l'app : c'est
      // le service qu'il faut allumer, et aucune permission ne le remplace.
      await BleRadio().openLocationSettings();
    } else if (status is RadioPermissionsMissing) {
      // ⚠️ **On demande ce que le NATIF dit manquer, on ne le déduit pas.**
      //
      // La liste dépend de la version d'Android — `ACCESS_FINE_LOCATION` sous
      // Android 12, `BLUETOOTH_SCAN` au-dessus — et c'est `BlePermissions`
      // qui la calcule, en interrogeant le système. Écrire ici un second test
      // de version reviendrait à décider une deuxième fois de ce qu'Android
      // exige, à un endroit qui ne le sait pas : le jour où les deux ne
      // diraient plus la même chose, rien ne le signalerait — la demande
      // porterait sur une permission, le blocage sur une autre.
      //
      // C'est le défaut A2 du diagnostic, corrigé en 2026-07 : la couche Dart
      // demandait les permissions puis jetait le résultat.
      await [
        ...status.missing.map(_permissionAndroid).nonNulls,
        Permission.notification,
      ].request();
    } else if (status is RadioAdapterOff) {
      await openAppSettings();
    }
    // Dans tous les cas on redemande : c'est le natif qui dira si ça a marché.
    await ref.read(proximitySupervisorProvider.notifier).retry();
  }

  /// Traduit un nom de permission Android en permission `permission_handler`.
  ///
  /// ⚠️ **Traduction, pas décision.** Les seuls noms qui arrivent ici sont ceux
  /// que `BlePermissions.required()` a produits côté natif. `BLUETOOTH` et
  /// `BLUETOOTH_ADMIN` (Android ≤ 11) n'en font jamais partie en pratique : ce
  /// sont des permissions de niveau *normal*, accordées à l'installation, donc
  /// `checkSelfPermission` ne les déclare jamais manquantes. On rend `null`
  /// plutôt que de lever : un nom inconnu ne doit pas empêcher de demander les
  /// autres.
  Permission? _permissionAndroid(String nom) => switch (nom) {
    'android.permission.BLUETOOTH_SCAN' => Permission.bluetoothScan,
    'android.permission.BLUETOOTH_ADVERTISE' => Permission.bluetoothAdvertise,
    'android.permission.BLUETOOTH_CONNECT' => Permission.bluetoothConnect,
    'android.permission.ACCESS_FINE_LOCATION' => Permission.locationWhenInUse,
    _ => null,
  };
}

/// Une demande d'ami reçue en proximité.
///
/// ⚠️ **Plusieurs peuvent coexister**, et elles survivent à la fermeture de
/// l'app. L'ancienne version n'en gardait qu'une, en mémoire : la seconde
/// écrasait la première sans trace.
class _CarteDemande extends ConsumerWidget {
  const _CarteDemande({required this.request});
  final PendingFriendRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${request.snapshot.displayName} veut se connecter avec toi',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              'Reçue ${vagueTimeAgo(request.receivedAt)}',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            // ⚠️ **`Expanded` sur les deux, et ce n'est pas de la cosmétique.**
            //
            // Le style des `FilledButton` pose `minimumSize:
            // Size.fromHeight(52)`, ce qui vaut `Size(infinity, 52)` : une
            // largeur minimale **infinie**. Une `Row` ne borne pas la largeur de
            // ses enfants non-flexibles — « Accepter » réclamait donc l'infini
            // et était peint **hors de l'écran**. En debug Flutter lève ; en
            // release l'assertion est compilée hors du binaire et il n'y a
            // aucun signe.
            //
            // Jay n'a vu que « Refuser », et la demande d'ami était donc
            // impossible à accepter (2026-08-17). `Expanded` borne la largeur,
            // et donne au passage deux boutons de largeur égale.
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => _repondre(context, ref, accept: false),
                    child: const Text('Refuser'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _repondre(context, ref, accept: true),
                    child: const Text('Accepter'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// ⚠️ **L'échec se DIT, et la demande reste.**
  ///
  /// L'ancienne version effaçait la carte puis abandonnait en silence si le
  /// lien BLE était tombé : la demande disparaissait pour toujours, sans copie
  /// serveur, et l'émetteur n'apprenait jamais rien.
  Future<void> _repondre(
    BuildContext context,
    WidgetRef ref, {
    required bool accept,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(proximityControllerProvider.notifier)
          .respondToRequest(request.fromUserId, accept: accept);
      if (accept) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Vous êtes connectés avec '
              '${request.snapshot.displayName}.',
            ),
          ),
        );
      }
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${request.snapshot.displayName} n\'est plus à portée. La demande '
            'est gardée : réessaie quand vous serez de nouveau proches.',
          ),
        ),
      );
    }
  }
}

class _TuilePair extends ConsumerWidget {
  const _TuilePair({required this.address});

  /// ⚠️ **Une adresse, pas un pair.** La tuile s'abonne à `peerViewProvider`,
  /// donc elle se reconstruit quand — et seulement quand — ce qu'ELLE affiche
  /// change. Lui passer l'objet complet reviendrait à la faire dépendre de
  /// l'écran parent, et donc à reconstruire toute la page à chaque annonce.
  final String address;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peer = ref.watch(peerViewProvider(address));
    // Il vient de partir entre la composition de la liste et ce build.
    if (peer == null || peer.snapshot == null) return const SizedBox.shrink();
    final snapshot = peer.snapshot!;
    // ⚠️ **Le statut d'ami se DÉRIVE ici, il ne vient pas de la présence.**
    //
    // Il venait de `peer.isFriend`, un champ de l'entrée de présence — écrit
    // par le chemin de l'ID rotatif, et **pas** par celui de la poignée de
    // main. Un ami identifié par poignée de main s'affichait donc comme un
    // inconnu, avec ce bouton. Jay, 2026-08-17 : « il manque une connexion
    // entre la vérification et l'affichage. »
    //
    // Le champ n'existe plus. La question se pose au carnet, au moment du
    // rendu, là où elle ne peut pas se désynchroniser.
    final estAmi = ref.watch(isFriendProvider(snapshot.userId)).value ?? false;
    final demande = ref
        .watch(proximityControllerProvider)
        .value
        ?.outgoingTo(snapshot.userId);
    return ListTile(
      leading: CircleAvatar(
        child: Text(snapshot.displayName.characters.first.toUpperCase()),
      ),
      title: Text(snapshot.displayName),
      // ⚠️ **Une BANDE et une TENDANCE, jamais des mètres.**
      //
      // Demande de Jay le 2026-08-16 : afficher la distance en temps réel. La
      // formule existe, mais le bruit de la vraie vie — un corps entre les deux
      // appareils absorbe 10 à 20 dB — rend un chiffre en mètres faux d'un
      // facteur 2 à 4. Afficher « 3,2 m » fabriquerait une précision qui
      // n'existe pas, et une distance au mètre près transformerait une app de
      // rencontre en outil de traque (spec 4.2).
      //
      // La TENDANCE, elle, est solide : les erreurs systématiques décalent le
      // niveau du signal, jamais le signe de sa pente. Elle est aussi plus
      // utile socialement — « il arrive » vaut mieux que « il est à 3 m ».
      //
      // La fourchette chiffrée existe, avec son incertitude assumée, dans
      // Développeur → Diagnostic proximité.
      subtitle: Row(
        children: [
          Icon(
            Icons.circle,
            size: 10,
            color: switch (peer.band) {
              ProximityBand.contact => Colors.greenAccent,
              ProximityBand.close => Colors.lightGreen,
              ProximityBand.room => Colors.amber,
              ProximityBand.far => Colors.orange,
            },
          ),
          const SizedBox(width: 6),
          Text(peer.band.label),
          if (peer.trend != ProximityTrend.stable) ...[
            const SizedBox(width: 8),
            Icon(
              peer.trend == ProximityTrend.approaching
                  ? Icons.trending_up
                  : Icons.trending_down,
              size: 14,
              color: peer.trend == ProximityTrend.approaching
                  ? Colors.greenAccent
                  : context.muted,
            ),
            const SizedBox(width: 3),
            Text(
              peer.trend.label,
              style: TextStyle(
                color: peer.trend == ProximityTrend.approaching
                    ? Colors.greenAccent
                    : context.muted,
              ),
            ),
          ],
          if (estAmi) ...[
            const SizedBox(width: 10),
            const Icon(Icons.link, size: 14),
          ],
          // ⚠️ **Affiché à la demande de Jay pour les relevés du 2026-08-16**,
          // et présenté comme ce que c'est : une ESTIMATION, avec sa
          // fourchette. Il veut juger la fiabilité sur le terrain plutôt que
          // sur ma parole — c'est la bonne façon de trancher.
          //
          // ⚠️ **À revoir après les relevés.** Si la fourchette se révèle aussi
          // large qu'annoncée, ce chiffre n'a rien à faire dans l'interface
          // d'un utilisateur : il redescendra dans le diagnostic. Ce n'est pas
          // une régression, c'est la décision que les mesures auront dictée.
          const SizedBox(width: 10),
          Text(
            '≈ ${peer.distanceLabel}',
            style: TextStyle(color: context.faint, fontSize: 12),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ⚠️ **Trois états, et chacun se voit.**
          //
          // Il n'y en avait qu'un : le bouton « demander », réaffiché à
          // l'identique après un envoi réussi. Jay a donc cliqué plusieurs
          // fois, et lu « Demande envoyée » à chaque fois — l'app ne gardait
          // aucune trace de ce qu'elle venait de faire, et ne pouvait donc rien
          // en dire.
          //
          // Une action doit aboutir à un état **visible**, sans quoi
          // l'utilisateur n'a d'autre choix que de recommencer.
          if (!estAmi)
            switch (demande) {
              null => IconButton(
                icon: const Icon(Icons.person_add_alt),
                tooltip: 'Demander à se connecter',
                onPressed: () => _demander(context, ref, snapshot),
              ),
              final d when d.isDeclined => IconButton(
                icon: Icon(Icons.person_off_outlined, color: context.muted),
                tooltip: 'Demande déclinée — appuie pour oublier',
                onPressed: () => _oublier(context, ref, snapshot),
              ),
              _ => IconButton(
                icon: Icon(Icons.hourglass_top, color: context.muted),
                // Désactivé, mais il DIT pourquoi. Un bouton grisé muet est
                // indiscernable d'une fonction absente (leçon du 2026-08-16).
                tooltip: 'Demande envoyée — en attente de sa réponse',
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Demande déjà envoyée à ${snapshot.displayName}. '
                      'En attente de sa réponse.',
                    ),
                  ),
                ),
              ),
            },
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Message ping',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    PingChatScreen(peerId: snapshot.userId, peer: snapshot),
              ),
            ),
          ),
        ],
      ),
      onTap: () => _ouvrirProfil(context, ref, snapshot),
    );
  }

  /// Oublie une demande **déclinée**. Geste explicite : une demande refusée ne
  /// s'efface pas toute seule, sinon l'utilisateur ne saurait jamais qu'on lui
  /// a dit non — il verrait juste le bouton revenir.
  Future<void> _oublier(
    BuildContext context,
    WidgetRef ref,
    PingPeerSnapshot snapshot,
  ) async {
    try {
      await ref
          .read(proximityControllerProvider.notifier)
          .dismissOutgoing(snapshot.userId);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Impossible d'oublier cette demande.")),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${snapshot.displayName} n\'a pas accepté. Tu peux redemander.',
        ),
      ),
    );
  }

  Future<void> _demander(
    BuildContext context,
    WidgetRef ref,
    PingPeerSnapshot snapshot,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(proximityControllerProvider.notifier)
          .requestFriendship(snapshot.userId);
      messenger.showSnackBar(
        SnackBar(content: Text('Demande envoyée à ${snapshot.displayName}.')),
      );
    } on FriendRequestRefused catch (refus) {
      // ⚠️ **La vraie raison, pas un conseil au hasard.** Tout était attrapé
      // par un `catch (_)` qui répondait « rapproche-toi » — un conseil FAUX
      // quand la cause était « vous êtes déjà connectés ». Une réponse fausse
      // envoie l'utilisateur faire quelque chose d'inutile.
      messenger.showSnackBar(SnackBar(content: Text(refus.message)));
    } catch (_) {
      // Un envoi raté se DIT. En silence, l'utilisateur croit avoir demandé.
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Impossible de joindre cette personne — rapproche-toi '
            'et réessaie.',
          ),
        ),
      );
    }
  }
}

class _TuileRencontre extends ConsumerWidget {
  const _TuileRencontre({required this.encounter});
  final LocalEncounter encounter;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: CircleAvatar(
      child: Text(encounter.peer.displayName.characters.first.toUpperCase()),
    ),
    title: Text(encounter.peer.displayName),
    subtitle: Text('Croisé ${vagueTimeAgo(encounter.at)}'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => _ouvrirProfil(context, ref, encounter.peer),
  );
}

/// Ouvre le profil complet (serveur). Sans internet, retombe sur la
/// conversation ping locale.
Future<void> _ouvrirProfil(
  BuildContext context,
  WidgetRef ref,
  PingPeerSnapshot snapshot,
) async {
  try {
    final profile = await ref.read(profileByIdProvider(snapshot.userId).future);
    if (profile != null && context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => UserLibraryScreen(profile: profile)),
      );
      return;
    }
  } catch (_) {
    // Hors ligne : pas de profil serveur.
  }
  if (context.mounted) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PingChatScreen(peerId: snapshot.userId, peer: snapshot),
      ),
    );
  }
}

class _TitreSection extends StatelessWidget {
  const _TitreSection(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _Vide extends StatelessWidget {
  const _Vide({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        Icon(icon, size: 48, color: context.ghost),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.muted),
        ),
      ],
    ),
  );
}

/// La découverte **v2** : le GPS oriente, le BLE prouve.
///
/// ⚠️ **Cette liste ne contient que des proximités MUTUELLES.** Quelqu'un qui
/// écoute sans s'annoncer n'y apparaît jamais — et n'y fait apparaître
/// personne. La règle vit côté serveur, pas ici (`confirm_ping`).
List<Widget> _autourDeToiV2(WidgetRef ref, ProximityRuntime runtime) {
  if (!runtime.wantsVisible) {
    return const [
      _Vide(
        icon: Icons.visibility_off_outlined,
        text: "Active « Visible à proximité » pour découvrir qui est autour.",
      ),
    ];
  }

  final beacon = ref.watch(pingBeaconProvider);
  final gens = ref.watch(pingNearbyProvider);

  // ⚠️ **Un blocage se DIT, et il nomme son action.** Une liste vide et une
  // permission refusée doivent rester distinguables — c'est tout ce que ce
  // projet a appris cette semaine.
  final blocker = beacon.blocker;
  if (blocker != null) {
    final (String titre, String detail, String action) = switch (blocker) {
      LocationBlocker.serviceOff => (
        "Localisation de l'appareil éteinte",
        "La découverte de proximité a besoin de savoir dans quel quartier tu "
            "es — à un kilomètre près, jamais plus précis.",
        "Ouvrir les réglages",
      ),
      LocationBlocker.denied => (
        "Position non autorisée",
        "Elle sert uniquement à savoir dans quel quartier chercher. Qui est "
            "vraiment à 20 m, c'est le Bluetooth qui le prouve.",
        "Autoriser",
      ),
      LocationBlocker.deniedForever => (
        "Position refusée définitivement",
        "Seuls les réglages système peuvent la rouvrir.",
        "Ouvrir les réglages",
      ),
      LocationBlocker.approximate => (
        "Position approximative",
        "Android répond à environ 3 km près, ce qui ne suffit pas à savoir "
            "dans quel quartier chercher. Choisis « Précise » dans les réglages "
            "de l'app.",
        "Ouvrir les réglages",
      ),
    };
    return [
      _BandeauSimple(
        titre: titre,
        detail: detail,
        action: action,
        onAction: () => blocker == LocationBlocker.denied
            ? ref.read(pingBeaconProvider.notifier).requestPermission()
            : openAppSettings(),
      ),
    ];
  }

  if (gens.isEmpty) {
    return [
      _Vide(
        icon: Icons.travel_explore,
        text: beacon.listening == 0
            ? "Personne d'autre n'a le ping activé dans ton quartier."
            : "${beacon.listening} personne(s) ont le ping actif dans le "
                  "quartier. Aucune n'est à portée pour l'instant — il faut "
                  "être à une vingtaine de mètres.",
      ),
    ];
  }

  return [
    for (final personne in gens)
      ListTile(
        leading: CircleAvatar(
          backgroundImage: personne.avatarUrl == null
              ? null
              : NetworkImage(personne.avatarUrl!),
          child: personne.avatarUrl == null
              ? Text(
                  personne.displayName.isEmpty
                      ? "?"
                      : personne.displayName.substring(0, 1).toUpperCase(),
                )
              : null,
        ),
        title: Text(personne.displayName),
        subtitle: Text(
          personne.tagName == null ? "À portée" : "@${personne.tagName}",
        ),
        trailing: const Icon(Icons.chat_bubble_outline),
        onTap: () => _ouvrirChatProximite(ref, personne),
      ),
  ];
}

/// Ouvre la messagerie de proximité.
///
/// ⚠️ **Le serveur peut refuser**, et c'est voulu : il exige une proximité
/// constatée des DEUX côtés. Un refus se montre, il ne s'avale pas.
Future<void> _ouvrirChatProximite(WidgetRef ref, NearbyPerson personne) async {
  final messenger = ScaffoldMessenger.maybeOf(ref.context);
  try {
    await ref.read(pingRepositoryProvider).openConversation(personne.userId);
    messenger?.showSnackBar(
      SnackBar(
        content: Text("Conversation ouverte avec ${personne.displayName}"),
      ),
    );
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text("$e")));
  }
}

/// Un bandeau d'information autonome, pour les blocages du ping v2.
class _BandeauSimple extends StatelessWidget {
  const _BandeauSimple({
    required this.titre,
    required this.detail,
    required this.action,
    required this.onAction,
  });

  final String titre;
  final String detail;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titre, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(detail, style: TextStyle(color: context.faint, fontSize: 12)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onAction, child: Text(action)),
          ),
        ],
      ),
    ),
  );
}
