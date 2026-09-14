/// Lecture du carnet de vie du service radio (`ServiceJournal.kt`).
///
/// Le natif écrit une ligne par événement, sur le disque, au moment où il se
/// produit :
///
/// ```
/// 2026-09-13 03:07:08 up=51234s cree
/// 2026-09-13 03:07:08 up=51234s demarre par l'app
/// 2026-09-13 03:15:00 up=51706s alarme — retard=312ms
/// ```
///
/// Ce fichier **ne fait que lire** : il compte, repère les morts sans
/// « detruit », les redémarrages du téléphone (`up=` qui redescend), et écrit
/// la phrase que Jay lira en premier. Pur, sans I/O, pour être éprouvable —
/// c'est un instrument, et un instrument livré sans test a déjà coûté deux
/// nuits à ce projet (`RAPPELS.md` #94, #106).
library;

/// Une ligne du carnet, décodée.
class ServiceJournalLine {
  const ServiceJournalLine({
    required this.at,
    required this.uptimeSeconds,
    required this.event,
    this.detail,
  });

  final DateTime at;
  final int uptimeSeconds;
  final String event;
  final String? detail;

  /// `null` si la ligne n'a pas la forme attendue (marque de coupe, ligne
  /// tronquée par la borne, texte étranger).
  static ServiceJournalLine? parse(String raw) {
    final m = _forme.firstMatch(raw.trim());
    if (m == null) return null;
    final at = DateTime.tryParse('${m.group(1)}T${m.group(2)}');
    if (at == null) return null;
    return ServiceJournalLine(
      at: at,
      uptimeSeconds: int.parse(m.group(3)!),
      event: m.group(4)!.trim(),
      detail: m.group(5)?.trim(),
    );
  }

  static final _forme = RegExp(
    r'^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) up=(\d+)s ([^—]+)(?:— (.*))?$',
  );
}

/// Ce que le carnet raconte, en quelques phrases.
class ServiceJournalReading {
  ServiceJournalReading._();

  /// La lecture, prête à être écrite au-dessus du carnet brut.
  static String lecture(String texte) {
    final lignes = texte
        .split('\n')
        .map(ServiceJournalLine.parse)
        .whereType<ServiceJournalLine>()
        .toList();
    if (lignes.isEmpty) {
      return 'Aucun carnet : le service n\'a jamais été créé depuis cette '
          'installation.';
    }

    final comptes = <String, int>{};
    for (final l in lignes) {
      comptes[l.event] = (comptes[l.event] ?? 0) + 1;
    }

    final morts = <String>[];
    final redemarrages = <String>[];
    ServiceJournalLine? precedente;
    var vivant = false;
    for (final l in lignes) {
      if (precedente != null && l.uptimeSeconds < precedente.uptimeSeconds) {
        redemarrages.add(
          'le téléphone a redémarré entre ${_hhmm(precedente.at)} et '
          '${_hhmm(l.at)}',
        );
      }
      if (l.event == 'cree') {
        if (vivant && precedente != null) {
          morts.add(
            'mort sans prévenir entre ${_hhmm(precedente.at)} '
            '(dernier signe : ${precedente.event}) et ${_hhmm(l.at)}',
          );
        }
        vivant = true;
      } else if (l.event == 'detruit') {
        vivant = false;
      }
      precedente = l;
    }

    final b = StringBuffer();
    b.writeln(
      '${lignes.length} lignes, du ${_jjhhmm(lignes.first.at)} au '
      '${_jjhhmm(lignes.last.at)}',
    );
    b.writeln(
      'créé ${comptes['cree'] ?? 0} · démarré par l\'app '
      '${comptes["demarre par l'app"] ?? 0} · relancé par Android '
      '${comptes['relance par Android'] ?? 0} '
      '(reprise ok ${comptes['reprise du disque : ok'] ?? 0}, '
      'rien ${comptes['reprise du disque : rien'] ?? 0}) · '
      'détruit ${comptes['detruit'] ?? 0} · alarmes ${comptes['alarme'] ?? 0} · '
      'mémoire basse ${comptes['memoire basse'] ?? 0} · '
      'tâche retirée ${comptes['tache retiree par l\'utilisateur'] ?? 0} · '
      'arrêt voulu ${comptes['arret voulu'] ?? 0}',
    );
    // Une alarme « perdue » a été constatée jamais délivrée et reposée par
    // `SlotAlarm.veille` (nuit du 2026-09-14 : 26 d'affilée, sans une ligne).
    // Zéro = rien à dire ; on ne l'imprime que si ça s'est produit.
    final perdues = comptes['alarme perdue, reposee'] ?? 0;
    if (perdues > 0) {
      b.writeln(
        '🔴 $perdues alarme(s) perdue(s) puis reposée(s) : le téléphone a '
        'avalé une sonnerie de créneau',
      );
    }
    final energie = _energie(comptes);
    if (energie != null) b.writeln(energie);
    for (final m in morts) {
      b.writeln('🔴 $m');
    }
    for (final r in redemarrages) {
      b.writeln('⚠️ $r');
    }
    if (morts.isEmpty && redemarrages.isEmpty) {
      b.writeln('aucune mort sans « detruit », aucun redémarrage du téléphone');
    }
    return b.toString().trimRight();
  }

  /// Les signaux d'énergie (`EnergyWatcher.kt`), sur une ligne — ou `null`
  /// si le carnet n'en porte aucun (version antérieure à la v0.9.180).
  static String? _energie(Map<String, int> comptes) {
    int c(String e) => comptes[e] ?? 0;
    final total =
        c('chargeur branche') +
        c('chargeur debranche') +
        c('ecran allume') +
        c('ecran eteint') +
        c('veille profonde : oui') +
        c('veille profonde : non') +
        c('veille legere : oui') +
        c('veille legere : non') +
        c("economie d'energie : oui") +
        c("economie d'energie : non") +
        c('batterie faible') +
        c('batterie ok');
    if (total == 0) return null;
    return 'énergie : chargeur branché ${c('chargeur branche')} / '
        'débranché ${c('chargeur debranche')} · écran allumé '
        '${c('ecran allume')} / éteint ${c('ecran eteint')} · veille profonde '
        'entrée ${c('veille profonde : oui')} / sortie '
        '${c('veille profonde : non')} · veille légère entrée '
        '${c('veille legere : oui')} / sortie ${c('veille legere : non')} · '
        "économie d'énergie activée ${c("economie d'energie : oui")} / "
        "désactivée ${c("economie d'energie : non")} · batterie faible "
        '${c('batterie faible')}';
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  static String _jjhhmm(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} ${_hhmm(d)}';
}
