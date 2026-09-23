/// **La phrase qui résume ce que la radio entend** — un seul endroit.
///
/// ## 🔴 Pourquoi ce fichier existe (2026-09-23)
///
/// La même lecture vivait en deux copies — l'écran « Diagnostic proximité » et
/// le rapport envoyé — avec des mots différents, et **toutes deux se
/// trompaient de la même façon** : elles concluaient « ton écoute fonctionne »
/// à partir de `rawScans`, un **cumul** depuis le démarrage. Au diagnostic de
/// 11:58, le compteur valait 22 969 alors que l'écoute était morte depuis
/// 10:53 (`scanMode : aucun scan`) : l'instrument disait « tout va bien » sur
/// un téléphone sourd.
///
/// ➡️ **L'état présent passe avant le cumul.** On regarde d'abord si quelque
/// chose écoute EN CE MOMENT ; les compteurs ne parlent qu'ensuite, et
/// seulement du passé.
///
/// Rend `null` quand le service ne tourne pas (aucune statistique).
String? lireEcoute(Map<Object?, Object?> stats) {
  final raw = stats['rawScans'] as int?;
  if (raw == null) return null;
  final neo = stats['neoScans'] as int? ?? 0;
  final autreVersion = stats['otherVersionScans'] as int? ?? 0;
  final voulue = stats['ecouteVoulue'] as bool?;
  final refus = stats['scanRefus'] as int? ?? 0;
  final panneMs = stats['scanPanneDepuisMillis'] as int? ?? -1;

  if (stats['scanMode'] == 'aucun scan') {
    if (voulue == false) {
      return "Ping éteint : rien n'écoute, et c'est voulu.";
    }
    final depuis = panneMs >= 0 ? ' depuis ${_duree(panneMs)}' : '';
    final combien = refus > 0
        ? " Android a refusé l'écoute $refus fois ; l'app réessaie seule."
        : '';
    return "🔴 L'ÉCOUTE EST ARRÊTÉE$depuis : ce téléphone ne peut voir "
        "personne, même s'il reste visible des autres.$combien Les "
        "compteurs d'annonces ($raw) ne parlent que du passé.";
  }
  if (autreVersion > 0 && neo == 0) {
    return '$autreVersion annonces NeoVibe écartées : elles parlent une AUTRE '
        'version du protocole. Les deux appareils ne sont pas à la même '
        'version — mets-les à jour ENSEMBLE.';
  }
  if (raw == 0) {
    return 'ZÉRO annonce reçue, toutes applications confondues. La radio ne '
        "te livre rien : le problème est SOUS l'app — permission, puce, ou "
        "bridage du système. Ce n'est pas la faute de l'autre appareil.";
  }
  if (neo == 0) {
    return "L'écoute tourne et reçoit ($raw annonces), mais AUCUNE ne vient "
        "de NeoVibe : c'est la diffusion d'en face qui n'arrive pas jusqu'ici, "
        "ou il n'y a personne.";
  }
  return 'La chaîne est complète : $raw annonces reçues, dont $neo de '
      'NeoVibe.';
}

/// **La puissance d'émission d'en face : quel chemin la rend ?** (2026-09-23)
///
/// Instrument posé AVANT tout correctif (règle 7). Le récepteur lit la
/// puissance par l'en-tête des annonces étendues (`ScanResult.txPower`) ; notre
/// annonce la porte dans une boîte (`scanRecord.txPowerLevel`). Si seul le
/// second chemin répond, l'estimation de distance tourne sur une valeur
/// supposée depuis toujours. Détail : `docs/annonce-ble-octet-par-octet.md` §5.
///
/// Rend `null` tant qu'aucune annonce NeoVibe d'un autre appareil n'a été
/// reçue : sans elle, les deux compteurs à zéro ne prouvent rien.
String? lirePuissance(Map<Object?, Object?> stats) {
  final n = stats['txAnnonces'] as int? ?? 0;
  if (n == 0) return null;
  final entete = stats['txEnTetePresent'] as int? ?? 0;
  final boite = stats['txBoitePresent'] as int? ?? 0;
  final chiffres =
      'sur $n annonces NeoVibe reçues : en-tête $entete, boîte $boite '
      '(dernières valeurs ${stats['txEnTeteDernier']} / '
      '${stats['txBoiteDernier']} dBm)';
  if (entete == 0 && boite > 0) {
    return '🔴 PUISSANCE : le défaut est CONFIRMÉ — la valeur n\'arrive que '
        'par la boîte, que la distance ne lit pas. La distance est estimée '
        'sur une valeur supposée ($chiffres).';
  }
  if (entete > 0) {
    return 'Puissance : l\'en-tête la fournit, la distance est calibrée '
        '($chiffres).';
  }
  return 'Puissance : AUCUN des deux chemins ne la rend ($chiffres).';
}

String _duree(int ms) {
  final min = ms ~/ 60000;
  if (min < 1) return '${ms ~/ 1000} s';
  if (min < 60) return '$min min';
  return '${min ~/ 60} h ${(min % 60).toString().padLeft(2, '0')}';
}
