import 'package:flutter/services.dart';

import '../video/video_open_trace.dart';
import '../../features/cards/native_camera.dart';
import 'app_log.dart';
import 'card_rules_trace.dart';

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
  static Future<String> proximity() async {
    try {
      final stats = await BleRadio().stats();
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
        'protocolVersion',
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
        'resumedFromDisk',
        'multipleAdvertisement',
        'extendedAdvertising',
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

      final raw = stats['rawScans'] as int?;
      final neo = stats['neoScans'] as int?;
      if (raw == 0) {
        buffer.writeln(
          'LECTURE : la radio ne livre RIEN. Le problème est sous l\'app '
          '(permission, localisation éteinte sur Android <= 11, ou puce).',
        );
      } else if ((stats['otherVersionScans'] as int? ?? 0) > 0 && neo == 0) {
        buffer.writeln(
          'LECTURE : ${stats['otherVersionScans']} annonces NeoVibe ecartees '
          'parce qu\'elles parlent une AUTRE version du protocole. Les deux '
          'appareils ne sont pas a la meme version : mets-les a jour ENSEMBLE.',
        );
      } else if (raw != null && neo == 0) {
        buffer.writeln(
          'LECTURE : la radio livre ($raw), mais aucune annonce NeoVibe. '
          'L\'écoute marche ; c\'est la diffusion d\'en face qui n\'arrive pas.',
        );
      }

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
    } catch (e) {
      buffer.writeln('relevé impossible : $e');
    }
    return buffer.toString();
  }

  static Future<String> build({
    bool device = true,
    bool video = true,
    bool rules = true,
    bool appLog = true,
    bool cameraLog = true,
    bool proximityState = true,
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
    }

    // ⚠️ Placée juste après l'appareil, et **avant** les journaux : c'est la
    // section la plus courte et la plus décisive du paquet. Enfouie après
    // 40 000 caractères de journal caméra, elle ne serait jamais lue.
    if (proximityState) {
      buffer
        ..writeln('\n===== PROXIMITÉ — CE QUE LA RADIO A REÇU =====')
        ..writeln(await proximity())
        // ⚠️ **Juste après la radio, et AVANT les journaux.** C'est la section
        // qui dit si les durées de contact se mesurent quand personne ne
        // regarde — enfouie après 40 000 caractères de journal caméra, elle ne
        // serait jamais lue. Même raison que la section proximité elle-même.
        ..writeln('\n===== PRÉSENCES — CE QUE LE CARNET A RETENU =====')
        ..writeln(await presences())
        ..writeln('\n===== CONNEXIONS — DEMANDES ET SYNCHRONISATION =====')
        ..writeln(connections())
        ..writeln('\n===== POSITION — CE QU\'ANDROID A ACCORDÉ =====')
        ..writeln(await location());
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
        buffer.writeln(log.trim().isEmpty ? '(vide)' : log.trim());
      } catch (e) {
        buffer.writeln('(illisible : $e)');
      }
    }

    if (appLog) {
      buffer.writeln('\n===== JOURNAL DE L\'APP =====');
      try {
        final log = await AppLog.instance.readAll();
        buffer.writeln(log.trim().isEmpty ? '(vide)' : log.trim());
      } catch (e) {
        buffer.writeln('(illisible : $e)');
      }
    }

    return buffer.toString();
  }
}
