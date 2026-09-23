import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../prefs.dart';
import '../video/video_open_trace.dart';
import '../content/content_media_cache.dart';
import '../content/saved_store.dart';
import '../../features/cards/card_media_cache.dart';
import '../../features/cards/native_camera.dart';
import '../../features/library_vibes/library_vault_cache.dart';
import 'app_log.dart';
import 'card_rules_trace.dart';
import 'radio_reading.dart';
import 'service_journal_reading.dart';

import '../../features/proximity/background_guard.dart';
import '../../features/proximity/geo/coarse_location.dart';
import '../../features/proximity/net/ble_radio.dart';
import '../../features/proximity/net/connection_trace.dart';
import '../../features/proximity/net/presence_book.dart';

/// Tout ce qu'il faut pour diagnostiquer, en **un seul** copier-coller.
///
/// ### Pourquoi ça existe
///
/// Les traces vivent à quatre endroits — journal de l'app, journal caméra,
/// mesures d'ouverture vidéo, et l'appareil lui-même. Les relever un par un
/// demande quatre écrans, quatre boutons et autant d'occasions d'en oublier un
/// ou de coller le mauvais. Demande de Jay le 2026-08-13 : « un bouton
/// permettant de copier simultanément tous les logs et données de toutes les
/// parties, de sorte à ce que je te les renvoie ».
///
/// Chaque section est délimitée par un titre en clair : le résultat doit se
/// lire tel quel, sans être remis en forme.
///
/// ⚠️ **Outil de développement** — à retirer avec la section Développeur avant
/// la prod (voir `RAPPELS.md`).
class DiagnosticBundle {
  const DiagnosticBundle._();

  static const _channel = MethodChannel('neovibe/diag');

  /// L'appareil et la version installée.
  ///
  /// La version vient du **paquet Android**, pas d'une constante Dart : une
  /// version recopiée à la main finit toujours par mentir, et un mauvais
  /// numéro dans un rapport fait chercher le bug dans la mauvaise version.
  static Future<Map<String, String>> deviceInfo() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'deviceInfo',
      );
      return {
        for (final entry in (info ?? {}).entries) entry.key: '${entry.value}',
      };
    } catch (_) {
      // Un diagnostic qui échoue ne doit jamais empêcher de copier le reste.
      return const {};
    }
  }

  /// Les mesures d'ouverture vidéo, mises en forme.
  ///
  /// Le détail par étape est conservé : c'est lui qui dit **qui** a retardé la
  /// première image — un total seul ne permet aucune décision.
  static String videoTimings() {
    final records = VideoOpenTrace.records;
    if (records.isEmpty) return 'Aucune mesure.';

    final buffer = StringBuffer();
    for (final availability in MediaAvailability.values) {
      final group = records.where((r) => r.availability == availability);
      // `perceived` : pour une face préchargée, l'attente ne commence qu'à
      // l'affichage (voir [VideoOpenTrace.prefetched]).
      final totals =
          group.map((r) => r.perceived).whereType<Duration>().toList()..sort();
      if (totals.isEmpty) {
        buffer.writeln('${availability.label} : aucune mesure');
        continue;
      }
      final median = totals[totals.length ~/ 2];
      buffer
        ..writeln(
          '${availability.label} : médiane ${median.inMilliseconds} ms '
          'sur ${totals.length} — meilleure ${totals.first.inMilliseconds} ms, '
          'pire ${totals.last.inMilliseconds} ms',
        )
        ..writeln(_stepLines(group.toList()));
    }

    buffer.writeln('\n--- ouvertures, la plus récente d\'abord ---');
    for (final record in records) {
      buffer.writeln(
        '[${record.availability.name}]'
        '${record.prefetched ? '[préchargée]' : ''} ${record.id} : '
        '${record.perceived?.inMilliseconds ?? '—'} ms'
        '${record.prefetched ? ' (ouverte ${record.total?.inMilliseconds} ms avant)' : ''}',
      );
      for (final step in VideoOpenStep.values.skip(1)) {
        final spent = record.spentOn(step);
        if (spent != null) {
          buffer.writeln('    ${step.label} : +${spent.inMilliseconds} ms');
        }
      }
      for (final entry in record.detail.entries) {
        buffer.writeln('        ${entry.key} : ${entry.value} ms');
      }
    }
    return buffer.toString().trimRight();
  }

  static String _stepLines(List<VideoOpenTrace> group) {
    final buffer = StringBuffer();
    for (final step in VideoOpenStep.values.skip(1)) {
      final values = group
          .map((r) => r.spentOn(step))
          .whereType<Duration>()
          .map((d) => d.inMilliseconds)
          .toList();
      if (values.isEmpty) continue;
      values.sort();
      buffer.writeln('    ${step.label} : ${values[values.length ~/ 2]} ms');
    }
    // Les coûts parallèles, à part : les additionner n'aurait aucun sens.
    final labels = <String>{for (final r in group) ...r.detail.keys};
    for (final label in labels) {
      final values = group
          .map((r) => r.detail[label])
          .whereType<int>()
          .toList();
      if (values.isEmpty) continue;
      values.sort();
      buffer.writeln('        $label : ${values[values.length ~/ 2]} ms');
    }
    return buffer.toString().trimRight();
  }

  /// L'état de la proximité, au moment de la collecte.
  ///
  /// ⚠️ **Absent du paquet jusqu'au 2026-08-16**, alors que c'était le chantier
  /// en cours : le premier rapport envoyé par Jay depuis la tablette ne
  /// contenait donc **rien** sur le ping. Une section manquante ne se voit pas
  /// dans un rapport — on lit ce qui est là, jamais ce qui n'y est pas.
  ///
  /// ⚠️ **La radio arrive par l'appelant, elle ne se construit pas ici.**
  /// Ce collecteur était le dernier des quatre `BleRadio()` que le provider du
  /// 2026-08-28 devait supprimer : le commentaire de `bleRadioProvider` énonçait
  /// donc une règle qu'un fichier contredisait, en silence. Relevé et corrigé le
  /// 2026-09-01.
  static Future<String> proximity(BleRadio radio) async {
    try {
      final stats = await radio.stats();
      final buffer = StringBuffer();

      // ⚠️ **Tout ce que le natif publie, sans liste à tenir à jour.**
      //
      // La première version nommait deux champs — `rawScans` et `neoScans`. Le
      // jour où le natif s'est mis à publier les capacités de mesure (UWB,
      // Wi-Fi RTT), elles sont apparues dans l'écran de diagnostic **et pas
      // dans le rapport** : Jay a envoyé ses relevés, et la réponse à sa
      // question n'y était pas.
      //
      // C'était la deuxième fois le même jour : la section proximité elle-même
      // avait manqué au premier rapport, pour la même raison. **Une liste de
      // champs à recopier finit toujours par diverger de sa source.**
      //
      // En parcourant la map, un champ ajouté côté natif arrive ici tout seul.
      // La cause est supprimée, pas le symptôme.
      final ordre = [
        'device',
        'sdk',
        'rawScans',
        'neoScans',
        'otherVersionScans',
        // La puissance d'émission par ses deux chemins (2026-09-23) : voir
        // `lirePuissance` dans `radio_reading.dart`.
        'txAnnonces',
        'txEnTetePresent',
        'txBoitePresent',
        'txEnTeteDernier',
        'txBoiteDernier',
        'protocolVersion',
        // ⚠️ **À quel rythme on ÉCOUTE, et pourquoi** — ajoutées le 2026-09-10
        // après le signalement de Jay : casque Bluetooth branché, puis ping
        // allumé, et la musique se tait.
        //
        // Le BLE et l'audio Bluetooth partagent la même antenne. On écoutait en
        // permanence (`continu`) sans jamais la relâcher. Désormais, casque
        // branché ⇒ `cyclique`, environ un quart du temps.
        //
        // ⚠️ **Les deux se lisent ENSEMBLE, et aucune ne se lit seule** :
        //   • `cyclique` + `casqueBluetooth: true`  → normal, c'est le remède ;
        //   • `cyclique` + `casqueBluetooth: false` → un état resté collé, donc
        //     une détection ralentie sans raison — invisible autrement ;
        //   • `continu`  + `casqueBluetooth: true`  → le remède n'a PAS pris,
        //     et c'est exactement ce qu'il faut savoir avant de conclure que la
        //     coupure de son vient d'ailleurs.
        'scanMode',
        // Collés à `scanMode` (2026-09-23) : un « aucun scan » ne se lit
        // qu'avec eux — voulu ou panne, combien de refus, depuis quand.
        'ecouteVoulue',
        'scanRefus',
        'scanPanneDepuisMillis',
        'casqueBluetooth',
        // Seconde cause de `cyclique` depuis le 2026-09-22 : écran éteint
        // depuis plus d'une minute.
        'ecranAllume',
        'advertMode',
        'advertTokensPerSlot',
        // ⚠️ **POURQUOI on est en cycle** — ajoutées le 2026-08-31.
        //
        // `advertMode` disait « cycle », ce qui est vrai, et ne disait pas d'où
        // ça vient. Il y a deux causes, et elles ne se corrigent pas pareil :
        //
        //   • `advertTokensPerSlot` > `advertMaxSets` → **le plafond**, atteint
        //     dès 6 jetons, donc dès 5 amis avec la découverte allumée. Le
        //     défaut d'échelle que le mode parallèle existe pour supprimer
        //     revient alors : le jeton d'un ami n'est en l'air que 1/N du temps.
        //   • `advertParallelCooldownMs` > 0 → **un refus** de la pile, qu'on
        //     retentera tout seul dans les dix minutes.
        //
        // Sans ces deux nombres, un croisement raté à six amis était
        // indiscernable d'un croisement raté pour toute autre raison.
        'advertMaxSets',
        'advertPlafondAppris',
        'advertParallelCooldownMs',
        // ⚠️ **Remontées tout en haut, et pas rangées avec les capacités.** Ce
        // sont les deux lignes qui datent ce que la radio crie vraiment : à 0,
        // l'appareil est reconnaissable ; à toute autre valeur, il est entendu
        // par tous et reconnu par personne. Voir `ProximityService.stats()`.
        'advertSlotDrift',
        // ⚠️ **Les quatre lignes d'un TEST DE NUIT, et elles se lisent
        // ensemble.** `advertSlotDrift` ci-dessus ne dit que l'instant présent
        // — or on ne lit un diagnostic qu'après avoir réveillé l'appareil,
        // c'est-à-dire après l'avoir réparé. Le 2026-08-30, il affichait 0 sur
        // les deux appareils au terme d'une nuit où la tablette a reçu 110 694
        // jetons d'ami sans en reconnaître un seul.
        //
        // `advertSlotDriftMax` retient la PIRE dérive depuis le démarrage du
        // service, et `...AgeMillis` dit quand : les deux survivent au réveil.
        // Les deux `slotAlarm...` disent si le réveil de veille a bien sonné —
        // sans eux, une dérive nulle ne distinguerait pas « c'est réparé » de
        // « l'alarme n'a jamais été honorée ».
        'advertSlotDriftMax',
        'advertSlotDriftMaxAgeMillis',
        'slotAlarmReveils',
        'slotAlarmRetardMaxMillis',
        'advertDataRefus',
        'advertRappelsPerimes',
        // ⚠️ **Vrai = le service a repris sur le plan écrit sur le disque.**
        // Dans cet état l'appareil croise ses amis mais **n'est pas
        // découvrable par des inconnus** : il n'a pas d'identifiant public à
        // crier tant que l'app n'a pas été rouverte. C'est le prix du choix du
        // 2026-08-28, et un prix qu'on ne voit pas est un prix qu'on oublie
        // d'avoir accepté.
        // Le battement de position (2026-09-22) : sans ces lignes, « la
        // balise a-t-elle été republiée cette nuit ? » n'a aucune réponse.
        'publicEnArrierePlan',
        'beaconPublications',
        'beaconEchecs',
        'beaconDernierEchec',
        'beaconMoteur',
        'beaconAgeMillis',
        'resumedFromDisk',
        'multipleAdvertisement',
        'extendedAdvertising',
        // ⚠️ La puce sait-elle trier elle-même ? Pas utilisé aujourd'hui
        // (filtre vide depuis le 2026-08-16) — RAPPELS #159.
        'offloadedFiltering',
        'offloadedScanBatching',
        'maxAdvertisingDataLength',
        'needsLocation',
        'fgsLocationType',
        'locationEnabled',
        'uwb',
        'wifiRtt',
        'wifiDirect',
        'wifiAware',
      ];
      final cles = [
        ...ordre.where(stats.containsKey),
        ...stats.keys.where((k) => !ordre.contains(k)),
      ];
      for (final cle in cles) {
        buffer.writeln('${cle.padRight(12)} : ${stats[cle]}');
      }

      // Une seule lecture, partagée avec l'écran de diagnostic : voir
      // `radio_reading.dart` pour le mensonge du 2026-09-23 qu'elle corrige.
      final lecture = lireEcoute(stats);
      if (lecture != null) buffer.writeln('LECTURE : $lecture');
      final puissance = lirePuissance(stats);
      if (puissance != null) buffer.writeln('LECTURE : $puissance');

      // ⚠️ **La ligne qui aurait fait gagner une journée le 2026-08-26.**
      //
      // Le jeton d'ami était alors symétrique : celui qu'on émet valait
      // exactement celui qu'on attend, donc le filtre anti-auto-détection
      // jetait toutes les annonces de l'ami — comptées en `selfScans`. Le
      // rapport portait le chiffre (317 contre 321 d'annonces retenues, soit
      // une sur deux) sans que rien ne dise ce qu'il fallait en lire.
      //
      // Le protocole 5 rend les deux sens distincts : au-delà de quelques
      // unités, ce compteur redevient un signal.
      // ⚠️ **Le mode d'émission décide de la moitié des croisements ratés.**
      // En `cycle`, un ami n'est annoncé que 1/N du temps : à dix amis, 10 %.
      // Sans cette ligne, un croisement manqué ressemble à une panne de radio.
      if (stats['advertMode'] == 'cycle') {
        final n = stats['advertTokensPerSlot'] as int? ?? 0;
        if (n > 1) {
          buffer.writeln(
            "LECTURE : émission en CYCLE sur $n jetons — chacun n'est "
            "en l'air qu'environ ${(100 / n).round()} % du temps. Le repli "
            "s'est déclenché : cet appareil n'a pas accepté les "
            "annonces simultanées.",
          );
        }
      }

      final neo = stats['neoScans'] as int?;
      final self = stats['selfScans'] as int?;
      if (self != null && neo != null && neo > 0 && self * 3 > neo) {
        buffer.writeln(
          'LECTURE : $self annonces sur $neo écartées comme « les nôtres ». '
          'Au-delà de quelques-unes, c\'est que deux appareils calculent le '
          'MÊME jeton — le sens du jeton d\'ami est perdu (protocole < 5).',
        );
      }

      // ⚠️ **`clientPaths`, `serverPaths`, `bothPaths` et `bothPathsPeak` ont
      // été retirés le 2026-08-27**, avec les connexions GATT qu'ils
      // comptaient. Ils avaient servi : `bothPathsPeak` valant zéro sur les
      // deux appareils avait **réfuté** l'hypothèse des deux chemins
      // simultanés, et donc évité une réécriture du natif fondée sur une
      // déduction. Un instrument qui ne peut plus rien mesurer se retire avec
      // ce qu'il mesurait.
      return buffer.toString();
    } catch (e) {
      return 'indisponible : $e';
    }
  }

  // 2026-08-27**, avec le transport BLE.
  //
  // Elle comptait les endroits où une trame disparaissait sans que personne ne
  // lève : trame sur un lien inconnu, sur un lien sans canal, déchiffrement
  // refusé, réassemblage abandonné. Elle était née des messages fantômes du
  // 2026-08-16 et avait révélé une quatrième cause invisible autrement.
  //
  // Plus aucune trame ne circule sur la radio. Un journal de pertes pour un
  // transport qui n'existe plus n'aurait rien à consigner — et une section
  // toujours vide dans un rapport de diagnostic est une invitation à conclure
  // « rien de perdu » là où il n'y a rien à perdre.

  /// Ce que le chemin des CONNEXIONS a fait — demandes et synchronisation.
  ///
  /// ⚠️ **Section distincte du transport, et ce n'est pas de la mise en page.**
  /// Le transport parle de trames et de canaux ; celle-ci parle de demandes
  /// d'amis et de carnet. Deux domaines, deux durées de vie. Les mélanger, c'est
  /// ne plus savoir lequel des deux a menti.
  ///
  /// Née du 2026-08-17 : Jay a signalé une demande d'ami qui n'arrivait pas, et
  /// les deux rapports envoyés ce jour-là ne contenaient **pas une seule ligne**
  /// sur ce chemin.
  static String connections() => ConnectionTrace.report();

  /// Le paquet complet, prêt à coller ou à envoyer.
  ///
  /// Les drapeaux permettent d'en produire une partie seulement — l'écran des
  /// temps d'ouverture copie ses seules mesures.
  /// Ce que le ping v2 sait de la position — **des faits, pas un verdict**.
  ///
  /// ⚠️ **Cette section manquait, et son absence a coûté un aller-retour.** Le
  /// 2026-08-26, un appareil affichait « position approximative » et l'autre
  /// non ; rien dans le rapport ne permettait de trancher entre « la permission
  /// précise n'est pas accordée » et « le dernier point en cache est mauvais ».
  /// Il a fallu lire le code pour le savoir. Un instrument qui ne peut pas
  /// mesurer la chose qu'on soupçonne ne sert à rien.
  /// **Ce que le carnet des présences a retenu** — des faits, pas un verdict.
  ///
  /// ## 🔴 Pourquoi cette section existe
  ///
  /// Le carnet a été livré le 2026-08-30 en annonçant qu'il répondrait à *« les
  /// durées se mesurent-elles pendant que le téléphone dort ? »*. Il n'était
  /// branché sur **aucun** rapport : la mesure existait, juste, et personne ne
  /// pouvait la lire. Deuxième instrument sans sortie du même jour, après
  /// `advertSlotDrift`.
  ///
  /// ## Ce qu'on peut en conclure, et ce qu'on ne peut pas
  ///
  /// | Ce qu'on lit | Ce que ça veut dire |
  /// |---|---|
  /// | des contacts datés de la nuit | le suivi tient quand l'écran est éteint |
  /// | **rien**, alors qu'on s'est croisés | le natif ne remonte pas au Dart |
  /// | des contacts « en attente » vieux de plus d'une heure | le balayage des verdicts ne tourne pas |
  ///
  /// ⚠️ **Identités abrégées à huit caractères.** De quoi retrouver qui c'est en
  /// base, sans faire de ce rapport un carnet d'adresses. Un diagnostic part par
  /// un geste explicite, ce n'est pas une raison pour qu'il en dise plus que
  /// nécessaire.
  ///
  /// [livre] : injectable **pour que cette section soit éprouvable**. Le défaut
  /// qu'on répare ici était justement une mesure sans lecteur ; en livrer la
  /// correction sans test aurait été refaire la moitié de l'erreur.
  static Future<String> presences({PresenceBook? livre}) async {
    final buffer = StringBuffer();
    try {
      final carnet = await (livre ?? PresenceBook()).tout();
      if (carnet.isEmpty) return 'Aucun contact retenu.';

      final maintenant = DateTime.now();
      var total = 0;
      var enAttente = 0;
      for (final entry in carnet.entries) {
        final contacts = [...entry.value]
          ..sort((a, b) => a.debut.compareTo(b.debut));
        buffer.writeln('${entry.key.substring(0, 8)} — ${contacts.length}');
        for (final c in contacts) {
          total++;
          final murissant = !c.juge;
          if (murissant) enAttente++;
          final age = maintenant.difference(c.fin);
          buffer.writeln(
            '  ${_hhmmss(c.debut)} · ${c.fin.difference(c.debut).inSeconds}s '
            '· ${c.detections} vues · '
            '${c.juge ? 'jugé' : 'en attente depuis ${age.inMinutes} min'}',
          );
        }
      }
      buffer.writeln('total $total contacts, dont $enAttente en attente');
    } catch (e) {
      buffer.writeln('relevé impossible : $e');
    }
    return buffer.toString();
  }

  /// La vie du service radio, relue depuis le disque.
  ///
  /// ⚠️ **C'est la seule section du paquet qui survive à la mort du
  /// processus.** Tout ce que « PROXIMITÉ » affiche vit dans l'objet service ;
  /// le test de nuit du 2026-09-13 l'a montré : les compteurs étaient à zéro
  /// parce que le service avait 30 secondes, et rien ne disait quand ni
  /// comment le précédent était mort. Ici, la lecture d'abord (morts sans
  /// « detruit », redémarrages du téléphone), le carnet brut ensuite.
  static Future<String> serviceJournal(BleRadio radio) async {
    try {
      final texte = await radio.serviceJournal();
      final buffer = StringBuffer()
        ..writeln('LECTURE : ${ServiceJournalReading.lecture(texte)}');
      if (texte.trim().isNotEmpty) {
        buffer
          ..writeln()
          ..write(texte.trimRight());
      }
      return buffer.toString();
    } catch (e) {
      return 'relevé impossible : $e';
    }
  }

  static String _hhmmss(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';

  static Future<String> location() async {
    final buffer = StringBuffer();
    try {
      const geo = CoarseLocation();
      final blocker = await geo.blocker();
      final precision = await geo.precision();
      buffer
        ..writeln('service actif : ${blocker != LocationBlocker.serviceOff}')
        ..writeln('blocage       : ${blocker?.name ?? 'aucun'}')
        ..writeln('finesse       : ${precision.name}');
      final fix = await geo.current();
      buffer.writeln('carreau       : ${fix ?? 'aucune position lisible'}');
      buffer.writeln(
        'repli haut    : ${CoarseLocation.lastBestFailure ?? 'aucun échec'}',
      );
      buffer.write(await _convergence(geo));
    } catch (e) {
      buffer.writeln('relevé impossible : $e');
    }
    return buffer.toString();
  }

  /// Combien on tirait à côté — **la mesure du défaut du 2026-09-22**.
  ///
  /// ## Ce qu'elle compare, et pourquoi elle vaut le temps qu'elle prend
  ///
  /// Le 2026-09-22, dans le métro, NeoVibe affichait Jay à `± 675 m` et deux
  /// rues plus loin, quand Google Maps le plaçait juste. La cause n'était pas
  /// la source des données — c'était qu'on **raccrochait à la première
  /// réponse**, la plus rapide donc la plus grossière.
  ///
  /// Cette sonde écoute [CoarseLocation.watch] pendant [_ecoute] et écrit ce
  /// qu'il s'est passé : **combien de relevés** sont arrivés, celui de départ,
  /// celui d'arrivée, et le meilleur. C'est la seule façon de répondre, sur
  /// l'appareil et à l'endroit qui pose problème, à la question qui compte :
  /// *le point se resserre-t-il si on attend ?*
  ///
  /// Deux lectures possibles du résultat, et elles n'appellent pas la même
  /// suite :
  ///
  /// - **l'incertitude descend** → rester abonné sert, et on sait de combien ;
  /// - **elle ne descend pas** → le moteur n'a rien de mieux à offrir ici
  ///   (sous terre, sans Wi-Fi), et aucun code ne le corrigera.
  ///
  /// ⚠️ **Un petit NOMBRE de relevés n'est PAS un défaut.** Immobile, le
  /// moteur de position ne réémet que lorsqu'il a quelque chose de neuf à
  /// dire : un seul relevé à ± 19 m vaut infiniment mieux que dix à ± 2000 m.
  /// C'est **l'incertitude** qu'on lit, jamais le compteur seul.
  ///
  /// ⚠️ **Ne PAS en conclure que la carte affiche ça.** Cette sonde repart de
  /// zéro à chaque diagnostic ; la carte, elle, reste abonnée tant qu'elle est
  /// ouverte et a donc bien plus de temps que [_ecoute] pour converger.
  ///
  /// ## 🔴 Le défaut d'instrument corrigé le 2026-09-22 au soir
  ///
  /// Cette sonde bornait son écoute avec `Stream.timeout`. Or ce délai est
  /// **inter-événement** : il se réarme à chaque relevé reçu. Elle ne mesurait
  /// donc pas « dix secondes d'écoute » mais « jusqu'à dix secondes de
  /// silence » — et elle écrivait quand même *« N relevés en 10 s »*.
  ///
  /// Le premier relevé publié par cet instrument disait *« 1 relevés en
  /// 10 s »* alors que la carte, au même moment, en comptait sept. Les deux
  /// chiffres étaient vrais et se contredisaient : c'est exactement le
  /// **mensonge d'instrument** que `CLAUDE.md` désigne comme le défaut le plus
  /// coûteux — il ne gêne rien, il fausse simplement toutes les décisions
  /// prises ensuite. La sonde ouvre maintenant une vraie fenêtre d'horloge.
  static Future<String> _convergence(CoarseLocation geo) async {
    final vus = <CoarseFix>[];
    StreamSubscription<CoarseFix>? sub;
    String? panne;
    try {
      sub = geo.watch().listen(
        vus.add,
        onError: (Object e) => panne ??= e.toString(),
        cancelOnError: false,
      );
      // ⚠️ **Une vraie fenêtre d'horloge**, et non un délai qui se réarme.
      // C'est la seule forme qui autorise la phrase « en N secondes ».
      await Future<void>.delayed(_ecoute);
    } catch (e) {
      return 'convergence   : flux indisponible ($e)\n';
    } finally {
      await sub?.cancel();
    }
    final s = _ecoute.inSeconds;
    if (vus.isEmpty) {
      return 'convergence   : aucun relevé en $s s'
          '${panne == null ? '' : ' · $panne'}\n';
    }
    final meilleur = vus
        .map((f) => f.accuracy)
        .reduce((a, b) => a < b ? a : b)
        .round();
    return 'convergence   : ${vus.length} relevés en $s s · '
        'début ± ${vus.first.accuracy.round()} m · '
        'fin ± ${vus.last.accuracy.round()} m · '
        'meilleur ± $meilleur m'
        '${panne == null ? '' : ' · $panne'}\n';
  }

  /// Combien de temps la sonde écoute. Assez pour qu'un GPS tiède réponde,
  /// assez peu pour qu'un diagnostic reste un geste et non une attente.
  static const _ecoute = Duration(seconds: 10);

  /// Ce que le téléphone accorde à l'app pour vivre en arrière-plan.
  /// L'état MIUI « démarrage automatique » n'est pas lisible : on le dit,
  /// plutôt que d'afficher un faux « non ».
  static Future<String> backgroundGuard() async {
    final buffer = StringBuffer();
    try {
      final etat = await const BackgroundGuard().state();
      buffer
        ..writeln('fabricant            : ${etat.manufacturer} (${etat.model})')
        ..writeln('exemption batterie   : ${etat.batteryExempt}')
        ..writeln('surcouche MIUI       : ${etat.miui}');
      if (etat.miui) {
        buffer.writeln(
          'démarrage automatique : non lisible (aucune API) — à vérifier à '
          'la main',
        );
      }
      if (!etat.batteryExempt) {
        buffer.writeln(
          'LECTURE : sans exemption, le téléphone peut arrêter le service '
          'radio sur batterie sans le relancer (après-midi du 2026-09-21).',
        );
      }
    } catch (e) {
      buffer.writeln('relevé impossible : $e');
    }
    return buffer.toString();
  }

  /// [radio] non nul = la section proximité est collectée, et c'est le seul
  /// moyen de la demander. L'ancien drapeau `proximityState` pouvait valoir
  /// `true` sans qu'aucune radio ne soit fournie : le collecteur en construisait
  /// alors une lui-même, ce qui contredisait `bleRadioProvider`.
  // ------------------------------------------------------------------
  // La place que chaque journal a le droit de prendre
  // ------------------------------------------------------------------

  /// Ce qu'un journal peut occuper dans le paquet, au maximum.
  ///
  /// ## 🔴 Le défaut que ceci supprime — relevé le 2026-09-11
  ///
  /// Les envois réels étaient **à 408 125 caractères pour un plafond de
  /// 409 600** : 99,6 %. Le prochain rapport un peu plus bavard se faisait
  /// couper.
  ///
  /// ⚠️ **Et il se serait fait couper par le mauvais bout.** [DevReport]
  /// tronque en gardant la **FIN** du texte — ce qui est juste pour un journal,
  /// qui se lit par ce qui vient de se passer. Mais le paquet, lui, place
  /// délibérément les sections **courtes et décisives en TÊTE** (radio,
  /// présences, connexions, position), précisément parce qu'enfouies après
  /// 40 000 caractères de journal caméra elles ne seraient jamais lues.
  ///
  /// Les deux règles se contredisaient donc en silence : le jour où le plafond
  /// serait atteint, la troncature aurait supprimé **exactement les sections
  /// qu'on avait pris soin de mettre en premier**, et le rapport serait arrivé
  /// amputé sans que rien ne l'indique — un paquet incomplet qu'on aurait lu
  /// comme complet.
  ///
  /// ➡️ On borne donc **chaque journal séparément**, à la source. Les sections
  /// structurées ne peuvent plus être poussées dehors par un journal bavard, et
  /// le plafond global de [DevReport] redevient ce qu'il aurait toujours dû
  /// être : un filet, pas le mécanisme.
  static const maxLogChars = 120 * 1024;

  /// Garde la **fin** de [texte] — un journal se lit par ce qui vient de se
  /// passer — et **dit qu'il a coupé**. Un journal tronqué en silence se lit
  /// comme un journal complet : on conclut alors que « ça n'est jamais arrivé »
  /// alors que la ligne est simplement tombée.
  static String bornerJournal(String texte) {
    if (texte.length <= maxLogChars) return texte;
    final retires = texte.length - maxLogChars;
    return '[...] $retires caracteres plus anciens retires de ce journal\n'
        '${texte.substring(retires)}';
  }

  // ------------------------------------------------------------------
  // Les trois zones qui ne remontaient PAS — ajoutées le 2026-09-11
  // ------------------------------------------------------------------

  /// **Dans quel état étaient les interrupteurs de test ?**
  ///
  /// ⚠️ **Sans cette section, tout le reste du paquet est ambigu.** « Forcer la
  /// vue simple Oneshot » resté allumé explique à lui seul un double live qui
  /// ne s'ouvre jamais — et rien, nulle part ailleurs dans le rapport, ne
  /// permettait de le savoir. On aurait cherché un défaut là où il y a un
  /// réglage. C'est la famille exacte « un instrument qui ne dit pas dans
  /// quelles conditions il a mesuré ».
  static String devFlags(Ref ref) {
    final lignes = <String, bool>{
      'Anti-capture (FLAG_SECURE)': ref.read(devSecureEnabledProvider),
      'Compte a rebours visible': ref.read(devShowExpiryProvider),
      'Diagnostic camera sur l apercu': ref.read(devCameraHudProvider),
      'Forcer la vue simple Oneshot': ref.read(devDualOneshotProvider),
    };
    return lignes.entries
        .map((e) => '${e.key.padRight(32)} : ${e.value ? 'OUI' : 'non'}')
        .join('\n');
  }

  /// **Ce que la caméra sait faire ici, et ce qu'elle a déjà raté.**
  ///
  /// ## 🔴 Pourquoi cette section existe — 2026-09-11
  ///
  /// Signalement de Jay du 2026-09-10 : le double live du Oneshot ne s'active
  /// qu'au deuxième passage. Or le paquet de diagnostic ne portait **aucune**
  /// trace de l'état du double flux — ni s'il avait été tenté, ni s'il avait
  /// échoué, ni si l'app se l'était interdit pour le reste de la session. La
  /// question de Jay ne pouvait donc pas être répondue par un rapport.
  ///
  /// ⚠️ **[NativeCameraController.dualFailedThisSession] est un verrou à sens
  /// unique** : posé par n'importe quel échec, y compris passager, et jamais
  /// relâché avant le redémarrage de l'app. À `OUI`, le Oneshot ne retentera
  /// **plus rien** — et le journal caméra, plus bas, dit pourquoi il a été posé.
  ///
  /// ⚠️ **Le service caméra d'Android peut tomber** après certains échecs
  /// (`cameraIdList` devient vide). Un appareil dans cet état échoue pour une
  /// raison qui n'a aucun rapport avec le code qu'on est en train de lire.
  static Future<String> cameraCaps() async {
    final buffer = StringBuffer()
      ..writeln(
        'double live deja refuse cette session : '
        '${NativeCameraController.dualFailedThisSession ? 'OUI' : 'non'}',
      );
    try {
      final vivant = await NativeCameraController.isCameraServiceAlive();
      buffer.writeln(
        'service camera d Android vivant       : ${vivant ? 'oui' : 'NON'}',
      );
    } catch (e) {
      buffer.writeln(
        'service camera d Android vivant       : (illisible : $e)',
      );
    }
    return buffer.toString().trimRight();
  }

  /// **Ce que l'app occupe sur le téléphone**, par contexte de diffusion.
  ///
  /// ⚠️ **Les contextes restent SÉPARÉS ici aussi.** Les sauvegardes sont des
  /// octets en clair, permanents, sans clé ni règle de visionnage ; les copies
  /// de Vibes et les scellés de bibliothèque obéissent à d'autres cycles de
  /// vie. Un total unique masquerait exactement ce qui les distingue — et un
  /// quota qui déborde ne se lit que par celui qui déborde.
  static Future<String> storage(Ref ref) async {
    try {
      final vibes = await ref.read(cardMediaCacheProvider).usage();
      final contenus = await ref.read(contentMediaCacheProvider).usage();
      final saved = await ref.read(savedStoreProvider).usedBytes();
      final vault = await ref.read(libraryVaultCacheProvider).usageBytes();
      final quotaMo = ref.read(ownCardsQuotaMbProvider);
      return [
        'mes Vibes (copies locales) : ${_mo(vibes.ownBytes)} / quota $quotaMo Mo',
        'Vibes recues               : ${_mo(vibes.othersBytes)}',
        'contenus — a moi           : ${_mo(contenus.ownBytes)}',
        'contenus — aux autres      : ${_mo(contenus.othersBytes)}',
        'sauvegardes (EN CLAIR)     : ${_mo(saved)}',
        'scelles de bibliotheque    : ${_mo(vault)}',
        'emplacement                : ${vibes.path}',
      ].join('\n');
    } catch (e) {
      return '(illisible : $e)';
    }
  }

  static String _mo(int octets) =>
      '${(octets / (1024 * 1024)).toStringAsFixed(1)} Mo';

  /// **LE paquet complet — le bouton « un clic » de Jay.**
  ///
  /// ## ⚠️ Pourquoi ceci existe EN PLUS de [build]
  ///
  /// [build] prend ses sections en option, et c'est voulu : un écran ciblé ne
  /// doit pas embarquer tout le reste. Mais l'envoi « tout » passait par ce
  /// même appel à options, et **une section oubliée n'y laissait aucune
  /// trace** — le rapport arrivait simplement plus court, et rien ne disait
  /// qu'il manquait quelque chose. Un rapport incomplet qui ne se signale pas
  /// est pire qu'un rapport absent : on conclut dessus.
  ///
  /// ➡️ Ici, **il n'y a rien à choisir**. C'est le seul point d'entrée de
  /// l'envoi complet, et **le seul endroit à modifier** quand une nouvelle zone
  /// de diagnostic apparaît : un ajout fait ici arrive dans le rapport de Jay
  /// sans qu'aucun appelant n'ait à être touché.
  static Future<String> everything(Ref ref) async {
    final buffer = StringBuffer(await build(radio: ref.read(bleRadioProvider)))
      ..writeln('\n===== INTERRUPTEURS DE TEST =====')
      ..writeln(devFlags(ref))
      ..writeln('\n===== CAMERA — CAPACITES ET ECHECS =====')
      ..writeln(await cameraCaps())
      ..writeln('\n===== STOCKAGE LOCAL =====')
      ..writeln(await storage(ref));
    return buffer.toString();
  }

  static Future<String> build({
    BleRadio? radio,
    bool device = true,
    bool video = true,
    bool rules = true,
    bool appLog = true,
    bool cameraLog = true,
  }) async {
    final buffer = StringBuffer()
      ..writeln('===== DIAGNOSTIC NEOVIBE =====')
      ..writeln('relevé le ${DateTime.now().toIso8601String()}');

    if (device) {
      final info = await deviceInfo();
      buffer.writeln(
        'app ${info['appVersion'] ?? '?'}+${info['appBuild'] ?? '?'} · '
        '${info['model'] ?? '?'} · Android ${info['android'] ?? '?'}',
      );
      // L'espace et la mémoire AU MOMENT du relevé : un rendu vidéo a
      // disparu du cache en plein travail le 2026-09-19, et rien ne disait
      // si le système manquait de place.
      String mo(String? v) {
        final n = int.tryParse(v ?? '');
        return n == null || n < 0
            ? '?'
            : (n / (1024 * 1024)).toStringAsFixed(0);
      }

      buffer.writeln(
        'disque : ${mo(info['diskFreeBytes'])} Mo libres sur '
        '${mo(info['diskTotalBytes'])} · mémoire : ${mo(info['memAvailBytes'])} Mo '
        'disponibles sur ${mo(info['memTotalBytes'])}'
        '${info['memLow'] == 'true' ? ' · 🔴 MÉMOIRE BASSE' : ''}',
      );
    }

    // ⚠️ Placée juste après l'appareil, et **avant** les journaux : c'est la
    // section la plus courte et la plus décisive du paquet. Enfouie après
    // 40 000 caractères de journal caméra, elle ne serait jamais lue.
    if (radio != null) {
      buffer
        ..writeln('\n===== PROXIMITÉ — CE QUE LA RADIO A REÇU =====')
        ..writeln(await proximity(radio))
        // ⚠️ Juste après la radio : c'est la section qui dit si le service a
        // passé la nuit, et la seule qui survive à sa mort (2026-09-13).
        ..writeln('\n===== SERVICE RADIO — SA VIE SUR LE DISQUE =====')
        ..writeln(await serviceJournal(radio))
        // ⚠️ **Juste après la radio, et AVANT les journaux.** C'est la section
        // qui dit si les durées de contact se mesurent quand personne ne
        // regarde — enfouie après 40 000 caractères de journal caméra, elle ne
        // serait jamais lue. Même raison que la section proximité elle-même.
        ..writeln('\n===== PRÉSENCES — CE QUE LE CARNET A RETENU =====')
        ..writeln(await presences())
        ..writeln('\n===== CONNEXIONS — DEMANDES ET SYNCHRONISATION =====')
        ..writeln(connections())
        ..writeln('\n===== POSITION — CE QU\'ANDROID A ACCORDÉ =====')
        ..writeln(await location())
        // ⚠️ Ajouté le 2026-09-22 : l'après-midi du 21, le service est mort
        // sur batterie sans relance ni réveil, et le rapport ne disait pas si
        // l'app était exemptée de l'optimisation batterie. Maintenant il le
        // dit — et le carnet du service aussi, ligne par ligne (`exempt=`).
        ..writeln('\n===== ARRIÈRE-PLAN — CE QUE LE TÉLÉPHONE ACCORDE =====')
        ..writeln(await backgroundGuard());
    }

    if (video) {
      buffer
        ..writeln('\n===== LECTURE VIDÉO — TEMPS D\'OUVERTURE =====')
        ..writeln(videoTimings());
    }

    if (rules) {
      buffer.writeln('\n===== RÈGLES DES VIBES =====');
      final records = CardRulesTrace.records;
      buffer.writeln(
        records.isEmpty
            ? 'Aucune ouverture.'
            : records.map((r) => r.describe()).join('\n'),
      );
    }

    if (cameraLog) {
      buffer.writeln('\n===== JOURNAL CAMÉRA =====');
      try {
        final log = await NativeCameraController.readLog();
        buffer.writeln(
          log.trim().isEmpty ? '(vide)' : bornerJournal(log.trim()),
        );
      } catch (e) {
        buffer.writeln('(illisible : $e)');
      }
    }

    if (appLog) {
      buffer.writeln('\n===== JOURNAL DE L\'APP =====');
      try {
        final log = await AppLog.instance.readAll();
        buffer.writeln(
          log.trim().isEmpty ? '(vide)' : bornerJournal(log.trim()),
        );
      } catch (e) {
        buffer.writeln('(illisible : $e)');
      }
    }

    return buffer.toString();
  }
}
