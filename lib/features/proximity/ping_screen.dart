import 'package:flutter/material.dart';
import '../connections/tier_avatar.dart';
import '../../core/typography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/utils/formats.dart';
import '../../core/widgets/avatar.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
import '../connections/connections_repository.dart';
import '../library/user_library_screen.dart';
import '../stories/stories_bar.dart';
import '../stories/stories_repository.dart';
import 'geo/coarse_location.dart';
import 'net/ping_beacon_service.dart';
import 'net/ping_nearby_feed.dart';
import 'net/ping_repository.dart';
import 'proximity_repository.dart';
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
  /// Le geste « tirer pour rafraîchir » : on redemande au SERVEUR.
  ///
  /// ⚠️ **On s'adresse à l'ACQUISITION, jamais à la vue dérivée.**
  /// `pingNearbyProvider` est l'**usage** — il filtre la source sur le délai de
  /// grâce. L'invalider ne fait que recalculer le même filtre sur les mêmes
  /// données : le geste de l'utilisateur ne produit alors **rien du tout**, et
  /// rien ne le signale. Seule la source sait aller rechercher.
  ///
  /// (C'est exactement le défaut introduit puis corrigé le 2026-08-27, en
  /// remplaçant la lecture des fichiers locaux du chat BLE par ce geste.)
  ///
  /// ⚠️ **Cet écran ne lit plus AUCUN fichier.** Il en lisait deux à chaque
  /// rafraîchissement — conversations ping et croisements locaux — tous deux
  /// alimentés par le transport BLE. La radio, elle, se rafraîchit toute seule :
  /// il n'y a rien à lui redemander.
  Future<void> _reload() async {
    // ⚠️ **Les DEUX étages, et dans cet ordre.** Republier la balise et
    // récupérer la liste d'écoute d'abord : sans ça, on redemanderait la liste
    // des gens déjà appariés sans jamais pouvoir en apparier de nouveaux.
    await ref.read(pingBeaconProvider.notifier).refreshNow();
    await ref.read(pingNearbySourceProvider.notifier).refresh();
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
              // ⚠️ **Cet interrupteur ne commande QUE la découverte d'inconnus
              // depuis le 2026-08-28.** Le croisement d'amis a le sien, dans
              // Réglages → Sécurité et confidentialité.
              title: const Text('Visible à proximité'),
              subtitle: Text(_sousTitreInterrupteur(runtime)),
              value: runtime.wantsDiscovery,
              // Tant que l'intention n'est pas relue, l'interrupteur est inerte
              // — sinon il s'afficherait éteint puis sauterait, et un
              // utilisateur qui voit ça le rebascule, donc coupe sa visibilité.
              onChanged: runtime.intentLoaded
                  ? (on) => ref
                        .read(proximitySupervisorProvider.notifier)
                        .setDiscovery(on)
                  : null,
            ),

            if (runtime.wantsDiscovery) _BandeauEtat(runtime: runtime),

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

            ..._croisesRecemment(ref),

            // ⚠️ **La section « Conversations ping » a été retirée le
            // 2026-08-27.** Elle listait les conversations BLE locales : un
            // second chemin d'émission à côté de la messagerie serveur.
            //
            // ✅ **« Croisés récemment » est REVENUE le 2026-08-27**, sur une
            // source qui marche. L'ancienne lisait les certificats BLE
            // co-signés — vérifié en base : la seule ligne de `encounters`
            // portait `proof = 'mutual_sighting'` alors que le défaut de la
            // colonne est `'certificate'`, donc **aucun certificat n'a jamais
            // abouti** et la section était vide en permanence.
            //
            // Elle se dérive maintenant de `croisesRecemmentProvider` : la
            // différence entre les paires fraîches du serveur et ceux qu'on
            // entend. Aucune requête de plus.
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  String _sousTitreInterrupteur(ProximityRuntime runtime) {
    if (!runtime.wantsDiscovery) {
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
    // 🔴 **Cette ligne testait le MAUVAIS interrupteur jusqu'au 2026-08-28.**
    //
    // Elle lisait `wantsVisible`, c'est-à-dire « visible des inconnus ». Couper
    // sa découverte vidait donc aussi la liste de ses amis à portée — alors que
    // le croisement d'amis ne dépend ni du serveur, ni de la position, ni de la
    // découverte. C'est le défaut rendu visible par la séparation des deux
    // intentions ; il était **invisible** tant qu'un seul booléen commandait
    // les deux.
    if (!runtime.wantsFriends) {
      return const [
        _Vide(
          icon: Icons.bluetooth_disabled,
          text:
              'Le croisement de tes amis est coupé.\nRéglages → Sécurité et '
              'confidentialité pour le rallumer.',
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
      _GrilleDeTuiles(
        enfants: [
          for (final address in keys.identified) _TuilePair(address: address),
        ],
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
      // ⚠️ **On demande au SUPERVISEUR, pas à la radio.** Cet écran
      // construisait son propre `BleRadio()` — un écran qui parle au natif.
      // Le superviseur possède la radio ; lui seul l'adresse.
      await ref
          .read(proximitySupervisorProvider.notifier)
          .openLocationSettings();
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
    // ⚠️ **Cette tuile n'affiche QUE des amis, et c'est désormais vrai par
    // construction** (2026-08-28).
    //
    // Elle interrogeait le carnet à chaque rendu pour savoir si la personne
    // qu'elle affiche est une amie — alors qu'une identité ne peut venir que du
    // carnet. La réponse était donc toujours « oui »… sauf pendant la fenêtre
    // où un ami venait d'être retiré et où sa session gardait son nom. C'est
    // cette fenêtre qui est supprimée : `PeerNetwork.refreshFriends` retire
    // maintenant l'identité des sessions que le carnet ne connaît plus.
    //
    // Le bouton « demander en ami » qui s'affichait dans ce cas est parti avec :
    // il ne pouvait de toute façon que se faire refuser par le serveur, qui
    // n'accepte pas de demande entre gens déjà connectés.
    final p = context.palette;

    // ⚠️ **LA DISTANCE N'EST PLUS AFFICHÉE — décision de Jay, 2026-08-30** :
    // *« pour les amis on n'a plus besoin de la distance, c'était pour les
    // tests ; on peut la garder mais sans l'afficher »*.
    //
    // Le commentaire d'origine (2026-08-16) annonçait déjà cette issue : la
    // bande et la tendance étaient là pour que Jay JUGE la fiabilité sur le
    // terrain. Le jugement est rendu.
    //
    // ✅ **Rien ne devient orphelin** : `PeerSession` continue de calculer
    // bande, tendance et fourchette, et Développeur → Diagnostic proximité les
    // affiche toujours. C'est l'affichage grand public qui s'arrête, pas la
    // mesure — vérifié avant de retirer, dans les deux sens.
    return GestureDetector(
      onTap: () => _ouvrirProfil(context, ref, snapshot),
      child: Container(
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(NeoRadius.md),
          border: Border.all(color: p.line),
        ),
        padding: const EdgeInsets.all(NeoSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // L'anneau de palier — le même composant que partout ailleurs.
            TierAvatar(
              peerId: snapshot.userId,
              storedAvatar: null,
              initiale: snapshot.displayName.characters.first.toUpperCase(),
              size: 42,
            ),
            const SizedBox(height: NeoSpace.sm),
            Text(
              snapshot.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.pseudo,
            ),
            // ⚠️ **« À portée » et rien de plus.** Un ami reconnu par la radio
            // EST à portée : c'est la seule façon dont il peut arriver ici.
            // Le dire suffit ; le chiffrer fabriquait une précision qui
            // n'existe pas.
            Text('À portée', style: context.tagName),
            const Spacer(),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: const Icon(Icons.chat_bubble_outline),
                tooltip: 'Message',
                // ⚠️ **La conversation SERVEUR, et elle seule** (2026-08-27).
                // Un ami a déjà une conversation partout ailleurs dans l'app :
                // en ouvrir une seconde, locale et éphémère, faisait deux
                // historiques pour une même personne.
                onPressed: () =>
                    _ouvrirConversation(context, ref, snapshot.userId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ⚠️ **`_oublier` a été SUPPRIMÉE le 2026-08-27**, avec le journal local des
  // demandes sortantes qu'elle effaçait. Elle n'avait plus de bouton pour
  // l'appeler.
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
  if (!runtime.wantsDiscovery) {
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
    final m = messagePosition(blocker, beacon.precision);
    return [
      _BandeauSimple(
        titre: m.titre,
        detail: m.detail,
        action: m.action,
        onAction: switch (m.quoiFaire) {
          ActionPosition.ouvrirReglages => openAppSettings,
          ActionPosition.autoriser || ActionPosition.autoriserPrecise =>
            () => ref.read(pingBeaconProvider.notifier).requestPermission(),
          ActionPosition.reessayer =>
            () => ref.read(pingBeaconProvider.notifier).refreshNow(),
        },
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
            : "${beacon.listening} personne(s) ont le ping actif autour "
                  "de toi. Aucune n'est à portée pour l'instant — il faut être "
                  "à une vingtaine de mètres.",
      ),
    ];
  }

  return [...notice, _GrilleInconnus(gens: gens, aPortee: true)];
}

/// Quelqu'un que le ping a révélé : un **inconnu**, dont la proximité est
/// prouvée des deux côtés.
///
/// ⚠️ **Un ami n'arrive jamais ici** depuis le 2026-08-27 : `ping_nearby` les
/// écarte. Cette chaîne sert à découvrir, et un ami est déjà reconnu par le BLE
/// — avec une information meilleure, sa distance. Les afficher ici produisait le
/// même profil deux fois, et un bouton de chat qui ne pouvait qu'échouer.
class _TuileInconnu extends ConsumerWidget {
  const _TuileInconnu({required this.personne, this.aPortee = true});

  final NearbyPerson personne;

  /// Faux dans « Croisés récemment » : la personne est partie.
  ///
  /// ⚠️ **Le bouton « Écrire » disparaît alors, et ce n'est pas cosmétique.**
  /// Le canal de proximité se ferme dès qu'on ne s'entend plus : le laisser
  /// afficherait un bouton dont le seul effet possible est un refus du serveur.
  /// Le bouton « demander en ami », lui, reste — c'est justement la fenêtre
  /// pendant laquelle il marche encore.
  final bool aPortee;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final initiale = personne.displayName.isEmpty
        ? "?"
        : personne.displayName.substring(0, 1).toUpperCase();

    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(NeoRadius.md),
        border: Border.all(color: p.line),
      ),
      padding: const EdgeInsets.all(NeoSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ⚠️ **Le widget partagé, et pas un `NetworkImage`.** `avatar_url`
          // porte un chemin de coffre privé, pas une URL : le donner tel quel à
          // `NetworkImage` levait « No host specified in URI » et laissait un
          // rond vide (constaté par Jay le 2026-08-26). `Avatar` sait lire les
          // deux formes, passe par la politique du coffre, et garde le fichier.
          Avatar(
            stored: personne.avatarUrl,
            radius: 21,
            fallback: Text(initiale),
          ),
          const SizedBox(height: NeoSpace.sm),
          Text(
            personne.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.pseudo,
          ),
          Text(
            aPortee
                ? (personne.tagName == null
                      ? "À portée"
                      : "@${personne.tagName}")
                : "Croisé ${vagueTimeAgo(personne.lastSeenAt)}",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.tagName,
          ),
          const SizedBox(height: NeoSpace.sm),

          // La MENTION SPÉCIALE — la deuxième bio, écrite pour les gens qu'on
          // croise sans les connaître.
          //
          // ⚠️ **Absente ne veut pas dire vide** : le serveur ne l'envoie que
          // si la personne a ouvert son interrupteur. L'app n'a donc rien à
          // décider, et rien à cacher.
          Expanded(
            child: personne.specialMention == null
                ? const SizedBox.shrink()
                : Text(
                    personne.specialMention!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
          ),

          // Deux gestes, deux boutons : écrire, ou demander en ami. Les
          // confondre obligerait l'utilisateur à deviner lequel il déclenche.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BoutonDemande(
                userId: personne.userId,
                displayName: personne.displayName,
              ),
              if (aPortee)
                IconButton(
                  tooltip: "Écrire",
                  icon: const Icon(Icons.chat_bubble_outline),
                  onPressed: () => _ouvrirChatProximite(ref, personne),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Les inconnus, **deux par ligne** (consigne de Jay, 2026-08-29).
///
/// ⚠️ **Une hauteur de tuile FIXE, et pas un rapport de forme.** Le contenu
/// varie — une mention de zéro, une ou deux lignes — et un rapport de forme
/// produit une hauteur qui dépend de la largeur de l'écran. Sur un téléphone
/// étroit, la tuile déborderait ; le débordement s'affiche en rayures jaunes en
/// debug et **se voit à peine en release**. Une hauteur fixe se calcule une
/// fois et tient sur tous les écrans.
class _GrilleInconnus extends StatelessWidget {
  const _GrilleInconnus({required this.gens, required this.aPortee});

  final List<NearbyPerson> gens;
  final bool aPortee;

  @override
  Widget build(BuildContext context) => _GrilleDeTuiles(
    enfants: [
      for (final personne in gens)
        _TuileInconnu(personne: personne, aPortee: aPortee),
    ],
  );
}

/// **Deux tuiles par ligne**, la même grille pour les amis et les inconnus.
///
/// ⚠️ **Une seule grille, pas une par section.** Deux grilles finiraient par
/// avoir deux hauteurs de tuile, et les deux blocs de l'écran ne s'aligneraient
/// plus — le genre d'écart qu'on ne remarque pas un par un et qui fait ensemble
/// une page « pas finie ».
class _GrilleDeTuiles extends StatelessWidget {
  const _GrilleDeTuiles({required this.enfants});

  final List<Widget> enfants;

  @override
  Widget build(BuildContext context) => _grille(enfants);

  static Widget _grille(List<Widget> enfants) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
    child: GridView.builder(
      shrinkWrap: true,
      // Elle vit DANS la liste de l'écran : c'est la liste qui défile, pas la
      // grille. Deux zones de défilement imbriquées se disputeraient le doigt.
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: NeoSpace.md,
        mainAxisSpacing: NeoSpace.md,
        mainAxisExtent: 196,
      ),
      itemCount: enfants.length,
      itemBuilder: (context, i) => enfants[i],
    ),
  );
}

/// Le bouton « demander en ami », **et l'état de la demande**.
///
/// ## ⚠️ Un seul bouton pour les DEUX tuiles, et c'est le sujet
///
/// Il en existait deux, avec deux fonctions d'envoi quasi identiques : une sur
/// la tuile d'un ami à portée, une sur celle d'un inconnu révélé par le ping.
/// Deux copies d'un même geste divergent toujours — c'est exactement ce qui
/// avait produit deux boutons « Ajouter » faisant deux choses différentes selon
/// la tuile touchée. **Le test de la règle** : le jour où une troisième tuile
/// aura besoin de ce bouton, il n'y aura rien à réécrire.
///
/// ## ⚠️ L'état vient du SERVEUR, jamais d'une mémoire locale
///
/// Voir [etatDemandeProvider]. La leçon coûte deux itérations : la première
/// réponse au défaut du 2026-08-17 fut un journal local, qui n'a jamais eu de
/// raison d'être une fois la demande devenue une ligne serveur.
class _BoutonDemande extends ConsumerWidget {
  const _BoutonDemande({required this.userId, required this.displayName});

  final String userId;
  final String displayName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ⚠️ **Une famille par personne, pas la liste entière.** Un lecteur qui
    // suit UNE demande n'est réveillé que quand CELLE-CI change — pas à chaque
    // fois que n'importe laquelle des demandes de l'utilisateur bouge.
    final etat = ref.watch(etatDemandeProvider(userId));
    return switch (etat) {
      EtatDemande.aucune => IconButton(
        icon: const Icon(Icons.person_add_alt),
        tooltip: 'Demander à se connecter',
        onPressed: () => _demanderEnAmi(context, ref, userId, displayName),
      ),
      // Désactivé, mais il DIT pourquoi. Un bouton grisé muet est
      // indiscernable d'une fonction absente (leçon du 2026-08-16).
      EtatDemande.envoyee => IconButton(
        icon: Icon(Icons.hourglass_top, color: context.muted),
        tooltip: 'Demande envoyée — en attente de sa réponse',
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Demande déjà envoyée à $displayName. '
              'En attente de sa réponse.',
            ),
          ),
        ),
      ),
      // ⚠️ **Redemander, et non « oublier ».** L'ancien bouton effaçait une
      // entrée d'un journal local ; il n'y a plus rien à effacer, et le serveur
      // autorise explicitement une nouvelle demande après un refus (vérifié
      // dans `request_connection_from_proximity`, qui ne cherche qu'une demande
      // `pending`). Cacher le refus serait pire : l'utilisateur ne saurait
      // jamais qu'on lui a dit non, il verrait juste le bouton revenir.
      EtatDemande.declinee => IconButton(
        icon: Icon(Icons.person_off_outlined, color: context.muted),
        tooltip: '$displayName n\'a pas accepté — appuie pour redemander',
        onPressed: () => _demanderEnAmi(context, ref, userId, displayName),
      ),
    };
  }
}

/// Demande en ami quelqu'un qui est à portée.
///
/// ⚠️ **La barrière de présence physique est vérifiée PAR LE SERVEUR** depuis le
/// 2026-08-27. Elle était tenue par la radio — il fallait un canal BLE ouvert
/// pour émettre la demande, donc être à portée. Maintenant que la demande est un
/// appel réseau ordinaire, c'est `request_connection_from_proximity` qui exige
/// la preuve : pas de proximité mutuelle fraîche, pas de demande.
///
/// ⚠️ **Rien à invalider après l'envoi.** La demande apparaît dans le flux temps
/// réel de `connection_requests`, donc le bouton change tout seul. Une
/// invalidation posée ici serait un second chemin vers un état dont le serveur
/// est déjà la source.
Future<void> _demanderEnAmi(
  BuildContext context,
  WidgetRef ref,
  String userId,
  String displayName,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(pingRepositoryProvider).requestConnection(userId);
    messenger.showSnackBar(
      SnackBar(content: Text('Demande envoyée à $displayName.')),
    );
  } catch (e) {
    // ⚠️ **La vraie raison, pas un conseil au hasard.** Un `catch` qui
    // répondait « rapproche-toi » donnait un conseil FAUX quand la cause était
    // « vous êtes déjà connectés » ou « proximité non constatée », et envoyait
    // l'utilisateur faire quelque chose d'inutile.
    messenger.showSnackBar(SnackBar(content: Text(messageServeur(e))));
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

/// **Croisés récemment** : plus à portée, mais encore ajoutables.
///
/// ⚠️ **Elle ne s'affiche que si elle a quelque chose à dire.** Une section
/// permanente et vide apprend à l'œil à ne plus la regarder — et le jour où
/// elle se remplit, personne ne la voit.
List<Widget> _croisesRecemment(WidgetRef ref) {
  final gens = ref.watch(croisesRecemmentProvider);
  if (gens.isEmpty) return const [];
  return [
    const _TitreSection('Croisés récemment'),
    _GrilleInconnus(gens: gens, aPortee: false),
  ];
}

/// Ce que l'utilisateur peut FAIRE quand la position manque.
///
/// ⚠️ **Une valeur, pas une fermeture.** [messagePosition] est pure et
/// éprouvable sans écran ni fournisseur ; c'est le widget qui branche l'action
/// sur son `ref`. Sans cette séparation, la seule façon de vérifier le texte
/// affiché aurait été de monter tout l'écran — donc de ne jamais le vérifier.
enum ActionPosition { ouvrirReglages, autoriser, autoriserPrecise, reessayer }

/// Le bandeau à afficher : un titre, une explication, une action.
class MessagePosition {
  const MessagePosition(this.titre, this.detail, this.action, this.quoiFaire);
  final String titre;
  final String detail;
  final String action;
  final ActionPosition quoiFaire;
}

/// **Quel bandeau, pour quel blocage — et à quelle finesse accordée.**
///
/// ## 🔴 Le défaut que la finesse corrige — relevé par Jay le 2026-08-29
///
/// Son écran affichait *« Ni les satellites, ni le Wi-Fi, ni le réseau n'ont
/// répondu — approche-toi d'une fenêtre, ou active le Wi-Fi »*. **Son Wi-Fi
/// était allumé**, ses données mobiles aussi. Le diagnostic, lui, disait
/// `finesse : approximate` : Android ne lui accordait plus que la position
/// approximative.
///
/// Le bandeau accusait donc l'environnement pour une cause qu'il n'avait pas
/// vérifiée, et proposait « Réessayer » — qui rejoue exactement la même chose
/// et ne peut rien réparer. **L'action qui aurait marché existait déjà**
/// (« Autoriser la position précise ») et était précisément cachée par le
/// `return` du cas bloqué.
///
/// ⚠️ **La documentation de [LocationBlocker.noFix] portait la prémisse
/// fausse** : « tout est autorisé, et aucun palier n'a su répondre ». Non :
/// `blocker()` rend `null` dès que la permission COARSE est accordée. « noFix »
/// et « position approximative » peuvent donc être vrais **en même temps**, et
/// c'est le cas de Jay.
///
/// ⚠️ **Un message qui prescrit une action prescrit une cause.** « Active le
/// Wi-Fi » n'est pas un conseil neutre : c'est une accusation, et elle envoie
/// chercher le problème là où il n'est pas.
MessagePosition messagePosition(
  LocationBlocker blocker,
  LocationPrecision precision,
) => switch (blocker) {
  LocationBlocker.serviceOff => const MessagePosition(
    "Localisation de l'appareil éteinte",
    "La découverte de proximité a besoin de savoir dans quel quartier tu es "
        "— à un kilomètre près, jamais plus précis.",
    "Ouvrir les réglages",
    ActionPosition.ouvrirReglages,
  ),
  LocationBlocker.denied => const MessagePosition(
    "Position non autorisée",
    "Elle sert uniquement à savoir dans quel quartier chercher. Qui est "
        "vraiment à 20 m, c'est le Bluetooth qui le prouve.",
    "Autoriser",
    ActionPosition.autoriser,
  ),
  LocationBlocker.deniedForever => const MessagePosition(
    "Position refusée définitivement",
    "Seuls les réglages système peuvent la rouvrir.",
    "Ouvrir les réglages",
    ActionPosition.ouvrirReglages,
  ),
  // 🔴 Deux causes possibles, deux messages, deux actions.
  LocationBlocker.noFix =>
    precision == LocationPrecision.approximate
        ? const MessagePosition(
            "Impossible de savoir où tu es",
            "Aucune source n'a rendu de position — et Android ne t'accorde "
                "que la position APPROXIMATIVE. C'est la première chose à "
                "corriger : inutile de chercher du côté du Wi-Fi ou de la "
                "fenêtre. Elle ne sert qu'à savoir dans quel quartier chercher "
                "— qui est vraiment à 20 m, c'est le Bluetooth qui le prouve.",
            "Autoriser la position précise",
            ActionPosition.autoriserPrecise,
          )
        : const MessagePosition(
            "Impossible de savoir où tu es",
            "Ni les satellites, ni le Wi-Fi, ni le réseau n'ont répondu. Tant "
                "que c'est le cas tu n'es annoncé nulle part, donc personne ne "
                "peut te trouver ici. Approche-toi d'une fenêtre, ou active le "
                "Wi-Fi.",
            "Réessayer",
            ActionPosition.reessayer,
          ),
};
