import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/widgets/avatar.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
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
import 'net/proximity_supervisor.dart';
import 'net/radio_status.dart';
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
  /// ⚠️ **Cet écran ne lit plus AUCUN fichier depuis le 2026-08-27.**
  ///
  /// Il en lisait deux à chaque rafraîchissement — les conversations ping et
  /// les croisements locaux — tous deux alimentés par le transport BLE, qui est
  /// supprimé. Ce qui reste vient du serveur ou de la radio, et se rafraîchit
  /// tout seul.
  Future<void> _reload() async {
    ref.invalidate(pingNearbyProvider);
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ **Observé pour son EFFET, pas pour sa valeur.** Construire ce provider
    // démarre le réseau de pairs, la synchro des clés et le balayage des
    // constats de croisement. Il ne rend plus rien depuis le 2026-08-27 (les
    // demandes d'amis de proximité vivent côté serveur) — mais le retirer
    // d'ici couperait toute la proximité, sans la moindre erreur.
    ref.watch(proximityControllerProvider);
    // ⚠️ **On observe la COMPOSITION de la liste, pas son contenu.** Le contenu
    // d'une tuile est observé par la tuile elle-même (`peerViewProvider`), donc
    // un pair qui se rapproche ne reconstruit que sa ligne — pas la barre de
    // stories, pas l'interrupteur, pas les autres tuiles. Règle de dissociation
    // de Jay, 2026-08-20 ; détail dans `presence_feed.dart`.
    final keys = ref.watch(presenceKeysProvider);
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
                  // ⚠️ **Réécrit le 2026-08-27.** Il promettait « ton profil ne
                  // circule que dans un canal chiffré, d'appareil à appareil » —
                  // vrai tant que le BLE transportait le mini-profil, faux
                  // depuis que l'identité d'un inconnu vient du serveur. Une
                  // promesse de confidentialité périmée est pire qu'aucune.
                  'Ton identifiant Bluetooth change toutes les 15 minutes, et '
                  'personne ne peut le relier à ton compte sans être à côté de '
                  'toi.',
                  style: TextStyle(color: context.faint, fontSize: 11),
                ),
              ),

            // ⚠️ **La carte « X veut se connecter avec toi » a été retirée le
            // 2026-08-27.** Elle affichait une demande d'ami arrivée par le
            // canal BLE, gardée dans un fichier local faute de ligne serveur.
            // Une demande est désormais une ligne de `connection_requests`, et
            // l'écran « Demandes & rencontres » la montre déjà — c'est
            // d'ailleurs là que Jay était allé la chercher le 2026-08-17.

            // ⚠️ **UNE seule section depuis le 2026-08-27.** Les deux chemins
            // coexistaient « le temps du test » (`RAPPELS.md` #65) ; le test a
            // eu lieu le 2026-08-26 et la v2 a produit sa première rencontre.
            //
            // Ce qui reste de chaque côté, et pourquoi :
            //
            // | Source | Ce qu'elle apporte |
            // |---|---|
            // | **BLE** | les AMIS, reconnus à l'annonce, avec leur DISTANCE |
            // | **ping v2** | les INCONNUS, après réciprocité prouvée |
            //
            // Les amis venaient aussi de `ping_nearby`, d'où le même profil
            // affiché deux fois. Le serveur les écarte maintenant : chaque
            // personne a UNE ligne, et une seule.
            const _TitreSection('Autour de toi'),
            ..._autourDeToiAmis(runtime, keys),
            ..._autourDeToiV2(ref, runtime),

            // ⚠️ **Les sections « Conversations ping » et « Croisés
            // récemment » ont été retirées les 2026-08-27.**
            //
            // La première listait les conversations BLE locales : un second
            // chemin d'émission à côté de la messagerie serveur.
            //
            // La seconde listait les croisements **certifiés en BLE**, une
            // preuve co-signée d'appareil à appareil. Décision de Jay du
            // 2026-08-27 : *« on ne garde que le certificat de croisement côté
            // serveur »*. Le constat mutuel (`report_sightings`) remplit déjà
            // la table `encounters`, qui est ce qui ouvre l'accès aux profils et
            // aux stories — la barre de stories en haut de cet écran en vit.
            //
            // ⚠️ **Le certificat BLE n'a jamais rien produit** : vérifié en base
            // le 2026-08-27, la seule ligne de `encounters` porte
            // `proof = 'mutual_sighting'` alors que le défaut de la colonne est
            // `'certificate'`. Cette section était donc vide en permanence.
            //
            // 📌 **La rebrancher sur `encounters` est un chantier à part**,
            // consigné dans `RAPPELS.md`.
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

  /// **Les AMIS à portée**, reconnus par le BLE seul.
  ///
  /// ⚠️ **C'est la moitié du produit, et elle ne passe par aucun serveur.** Un
  /// ami est reconnu à l'annonce, hors ligne, app fermée, sans permission de
  /// localisation sur Android 12+ — et c'est le seul chemin qui donne une
  /// **distance**. Ne pas la confondre avec la découverte d'inconnus, qui vient
  /// du ping v2 et qui, elle, a besoin du serveur.
  List<Widget> _autourDeToiAmis(ProximityRuntime runtime, PresenceKeys keys) {
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
    // ⚠️ **Le compteur « N appareils détectés » a été SUPPRIMÉ le
    // 2026-08-27.** Il comptait les sessions BLE non identifiées, c'est-à-dire
    // celles qui attendaient une poignée de main GATT — or plus aucun lien
    // n'est ouvert vers un inconnu : leur identité vient du serveur.
    //
    // Il ne mesurait donc plus rien d'atteignable, et tournait en boucle chez
    // Jay (« 2 appareils détectés, vérification chiffrée en cours ») : un
    // appareil en mode ping émet deux jetons, donc deux sessions, dont une
    // seule est un ami. **Un compteur qui ne peut plus tomber à zéro n'est
    // pas une mesure, c'est du bruit.**
    //
    // Le vide, lui, est dit par la section du ping juste en dessous : elle
    // sait distinguer « personne autour » de « personne à portée », ce que
    // celle-ci n'a jamais su faire.
    return [
      // La tuile ne reçoit qu'une ADRESSE : elle va chercher elle-même ce
      // qu'elle affiche, et ne se reconstruit que quand cela change.
      for (final address in keys.identified) _TuilePair(address: address),
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
    // ⚠️ `BLUETOOTH_CONNECT` a été retirée du natif le 2026-08-27, avec le bloc
    // GATT. Sa traduction part avec elle : la garder pour « au cas où » ferait
    // demander une permission que rien ne réclame plus.
    'android.permission.ACCESS_FINE_LOCATION' => Permission.locationWhenInUse,
    _ => null,
  };
}

/// **Un ami à portée**, reconnu par la radio à son jeton rotatif.
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
          // ⚠️ **Un seul état depuis le 2026-08-27, contre trois avant.**
          //
          // Les trois — « demander », « envoyée, en attente », « déclinée,
          // appuie pour oublier » — se lisaient dans un journal LOCAL de
          // demandes sortantes, qui n'existait que parce qu'une demande d'ami
          // voyageait d'appareil à appareil sans laisser de ligne serveur. Ce
          // journal est supprimé : le serveur se souvient à sa place, et c'est
          // lui qui répond « demande déjà envoyée » quand on insiste.
          //
          // ⚠️ **C'est un recul d'interface, et il est assumé** : Jay avait
          // cliqué plusieurs fois faute de voir l'état (2026-08-17). La bonne
          // réponse est de lire l'état SERVEUR de la demande, pas de garder un
          // second journal local — un état affiché depuis une source que le
          // serveur peut contredire, c'est deux vérités. Consigné dans
          // `RAPPELS.md`. En attendant, le refus du serveur est **montré**, ce
          // qui n'était pas le cas en 2026-08-17.
          if (!estAmi)
            IconButton(
              icon: const Icon(Icons.person_add_alt),
              tooltip: 'Demander à se connecter',
              onPressed: () => _demander(context, ref, snapshot),
            ),
          // ⚠️ **La conversation SERVEUR, et elle seule** (2026-08-27).
          //
          // Cette tuile n'affiche que des **amis** : eux seuls sont reconnus par
          // la radio. Or un ami a déjà une conversation directe partout ailleurs
          // dans l'app — ouvrir ici un second fil, local et éphémère, faisait
          // deux historiques pour une même personne.
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Message',
            onPressed: () => _ouvrirConversation(context, ref, snapshot.userId),
          ),
        ],
      ),
      onTap: () => _ouvrirProfil(context, ref, snapshot),
    );
  }

  // ⚠️ **`_oublier` a été SUPPRIMÉE le 2026-08-27**, avec le journal local des
  // demandes sortantes qu'elle effaçait. Elle n'avait plus de bouton pour
  // l'appeler.

  /// Demande en ami quelqu'un que la radio a identifié.
  ///
  /// ⚠️ **Passe par le SERVEUR depuis le 2026-08-27**, comme le bouton de la
  /// tuile d'un inconnu. Elle appelait `ProximityController.requestFriendship`,
  /// qui envoyait la demande dans le canal BLE chiffré : c'était le **dernier**
  /// des trois chemins d'émission, et le garder aurait laissé deux boutons
  /// « Ajouter » faire deux choses différentes selon la tuile touchée.
  ///
  /// ⚠️ **Le serveur peut répondre « Proximité non constatée », et c'est
  /// correct** : cette tuile peut afficher quelqu'un identifié par un lien
  /// ENTRANT (un appareil resté sur une version antérieure), sans paire ping.
  /// La barrière s'applique alors, et elle le dit — au lieu de laisser croire
  /// que la demande est partie.
  Future<void> _demander(
    BuildContext context,
    WidgetRef ref,
    PingPeerSnapshot snapshot,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(pingRepositoryProvider).requestConnection(snapshot.userId);
      messenger.showSnackBar(
        SnackBar(content: Text('Demande envoyée à ${snapshot.displayName}.')),
      );
    } catch (e) {
      // ⚠️ **La vraie raison, pas un conseil au hasard.** Un `catch` qui
      // répondait « rapproche-toi » donnait un conseil FAUX quand la cause
      // était « vous êtes déjà connectés », et envoyait l'utilisateur faire
      // quelque chose d'inutile.
      messenger.showSnackBar(SnackBar(content: Text(messageServeur(e))));
    }
  }
}

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
    await _ouvrirConversation(context, ref, snapshot.userId);
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

  // ⚠️ **Une dégradation s'AJOUTE à la liste, elle ne la remplace pas.**
  // « Position approximative » était un bandeau exclusif : la découverte
  // s'arrêtait là. Or elle fonctionne quand même, moins bien — et le mur
  // garantissait l'échec que l'avertissement se contente d'annoncer.
  final notice = beacon.precision == LocationPrecision.approximate
      ? [
          _BandeauSimple(
            titre: "Position approximative",
            detail:
                "Android répond à environ 3 km près : on cherche quand même, "
                "mais quelqu'un du quartier d'à côté peut te manquer. La "
                "position précise ne sert qu'à savoir OÙ chercher — qui est "
                "vraiment à 20 m, c'est le Bluetooth qui le prouve.",
            action: "Autoriser la position précise",
            onAction: () =>
                ref.read(pingBeaconProvider.notifier).requestPermission(),
          ),
        ]
      : const <Widget>[];

  if (gens.isEmpty) {
    return [
      ...notice,
      _Vide(
        icon: Icons.travel_explore,
        text: beacon.listening == 0
            ? "Personne d'autre n'a le ping activé dans ton quartier."
            // Un compte tronque s'annonce comme un PLANCHER : afficher le
            // plafond de la requete comme un total serait presenter une limite
            // d'instrument pour une mesure.
            : "${beacon.listeningTruncated ? 'Plus de ' : ''}"
                  "${beacon.listening} personne(s) ont le ping actif autour de "
                  "toi. Aucune n'est à portée pour l'instant — il faut être à "
                  "une vingtaine de mètres.",
      ),
    ];
  }

  return [
    ...notice,
    for (final personne in gens) _TuileInconnu(personne: personne),
  ];
}

/// Quelqu'un que le ping a révélé : un **inconnu**, dont la proximité est
/// prouvée des deux côtés.
///
/// ⚠️ **Un ami n'arrive jamais ici** depuis le 2026-08-27 : `ping_nearby` les
/// écarte. Cette chaîne sert à découvrir, et un ami est déjà reconnu par le BLE
/// — avec une information meilleure, sa distance. Les afficher ici produisait le
/// même profil deux fois, et un bouton de chat qui ne pouvait qu'échouer.
class _TuileInconnu extends ConsumerWidget {
  const _TuileInconnu({required this.personne});

  final NearbyPerson personne;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initiale = personne.displayName.isEmpty
        ? "?"
        : personne.displayName.substring(0, 1).toUpperCase();
    return ListTile(
      // ⚠️ **Le widget partagé, et pas un `NetworkImage`.** `avatar_url` porte
      // un chemin de coffre privé, pas une URL : le donner tel quel à
      // `NetworkImage` levait « No host specified in URI » et laissait un rond
      // vide (constaté par Jay le 2026-08-26). `Avatar` sait lire les deux
      // formes, passe par la politique du coffre, et garde le fichier.
      leading: Avatar(stored: personne.avatarUrl, fallback: Text(initiale)),
      title: Text(personne.displayName),
      subtitle: Text(
        personne.tagName == null ? "À portée" : "@${personne.tagName}",
      ),
      // Deux gestes, deux boutons : écrire, ou demander en ami. Les confondre
      // obligerait l'utilisateur à deviner lequel il déclenche.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: "Demander en ami",
            icon: const Icon(Icons.person_add_alt),
            onPressed: () => _demanderEnAmi(ref, personne),
          ),
          IconButton(
            tooltip: "Écrire",
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () => _ouvrirChatProximite(ref, personne),
          ),
        ],
      ),
    );
  }
}

/// Demande en ami quelqu'un que le ping vient de révéler.
///
/// ⚠️ **La barrière de présence physique est vérifiée PAR LE SERVEUR** depuis le
/// 2026-08-27. Elle était tenue par la radio — il fallait un canal BLE ouvert
/// pour émettre la demande, donc être à portée. Maintenant que la demande est un
/// appel réseau ordinaire, c'est `request_connection_from_proximity` qui exige
/// la preuve : pas de proximité mutuelle fraîche, pas de demande.
Future<void> _demanderEnAmi(WidgetRef ref, NearbyPerson personne) async {
  final messenger = ScaffoldMessenger.maybeOf(ref.context);
  try {
    await ref.read(pingRepositoryProvider).requestConnection(personne.userId);
    messenger?.showSnackBar(
      SnackBar(content: Text("Demande envoyée à ${personne.displayName}")),
    );
  } catch (e) {
    // ⚠️ Un refus du serveur se MONTRE. « Proximité non constatée » veut dire
    // quelque chose de précis, et l'avaler laisserait l'utilisateur croire que
    // sa demande est partie.
    messenger?.showSnackBar(SnackBar(content: Text(messageServeur(e))));
  }
}

/// Ouvre la messagerie de proximité — **et l'écran qui va avec**.
///
/// ⚠️ **Elle créait la conversation sans jamais l'ouvrir** : le seul retour
/// était un encadré « Conversation ouverte », et la conversation restait
/// introuvable. La messagerie de proximité existait donc en base sans exister
/// pour l'utilisateur (constaté le 2026-08-27, en préparant le retrait du chat
/// BLE — sans cette correction, le produit se serait retrouvé sans aucune
/// messagerie de proximité).
///
/// ⚠️ **Le serveur peut refuser**, et c'est voulu : il exige une proximité
/// constatée des DEUX côtés. Un refus se montre, il ne s'avale pas.
Future<void> _ouvrirChatProximite(WidgetRef ref, NearbyPerson personne) async {
  final messenger = ScaffoldMessenger.maybeOf(ref.context);
  final navigator = Navigator.maybeOf(ref.context);
  try {
    final id = await ref
        .read(pingRepositoryProvider)
        .openConversation(personne.userId);
    navigator?.push(
      MaterialPageRoute(builder: (_) => ChatScreen(conversationId: id)),
    );
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(messageServeur(e))));
  }
}

/// Ouvre la conversation **serveur** avec quelqu'un qu'on a croisé.
///
/// ⚠️ **Un seul chemin pour écrire, depuis le 2026-08-27.** Cet écran en avait
/// trois : le chat BLE local sur la tuile d'un pair, le même sur une rencontre,
/// et la messagerie serveur sur un inconnu du ping. Trois historiques possibles
/// pour une même personne, selon le bouton emprunté.
///
/// ⚠️ **Deux conversations restent distinctes, et c'est voulu** : la
/// **directe** pour un ami, la **proximité** pour un inconnu prouvé proche. Le
/// serveur refuse d'ouvrir la seconde entre gens déjà connectés — on essaie
/// donc la directe d'abord, et la proximité si l'on n'est pas amis.
Future<void> _ouvrirConversation(
  BuildContext context,
  WidgetRef ref,
  String peerId,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final me = ref.read(currentUserIdProvider);
  final amis = ref
      .read(fullConnectionsProvider)
      .any((c) => me != null && c.peerIdFor(me) == peerId);
  try {
    final id = amis
        ? await ref
              .read(conversationsRepositoryProvider)
              .getOrCreateDirect(peerId)
        : await ref.read(pingRepositoryProvider).openConversation(peerId);
    navigator.push(
      MaterialPageRoute(builder: (_) => ChatScreen(conversationId: id)),
    );
  } catch (e) {
    // Un appui qui n'aboutit à rien est le pire des retours : l'utilisateur
    // n'a d'autre hypothèse que « le bouton ne marche pas ».
    messenger.showSnackBar(SnackBar(content: Text(messageServeur(e))));
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
