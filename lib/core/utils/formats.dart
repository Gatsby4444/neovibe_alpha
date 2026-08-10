/// Horodatage approximatif volontairement flou (Waves, spec 4.11 :
/// jamais d'heure exacte de croisement).
String vagueTimeAgo(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 15) return 'il y a quelques minutes';
  if (diff.inMinutes < 60) return 'il y a moins d\'une heure';
  if (diff.inHours < 2) return 'il y a une heure environ';
  if (diff.inHours < 24) return 'il y a quelques heures';
  return 'récemment';
}

String shortTime(DateTime when) {
  final local = when.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

const _joursFr = [
  'lundi',
  'mardi',
  'mercredi',
  'jeudi',
  'vendredi',
  'samedi',
  'dimanche',
];

const _moisFr = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];

/// Titre d'un album daté de bibliothèque : « Aujourd'hui », « Hier », sinon
/// « Mardi 12 août ».
///
/// Écrit à la main plutôt qu'avec `DateFormat(…, 'fr_FR')` : `intl` exige
/// `initializeDateFormatting`, qui n'est appelé nulle part dans l'app — la
/// version localisée aurait levé à l'ouverture de l'écran. Le reste du projet
/// formate déjà ses dates ainsi.
String albumDayLabel(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(DateTime(day.year, day.month, day.day)).inDays;
  if (diff == 0) return 'Aujourd\'hui';
  if (diff == 1) return 'Hier';

  final jour = _joursFr[day.weekday - 1];
  final label = '$jour ${day.day} ${_moisFr[day.month - 1]}';
  final titre = label[0].toUpperCase() + label.substring(1);
  return day.year == now.year ? titre : '$titre ${day.year}';
}

/// Temps restant avant expiration (messages éphémères, liens partiels).
String remaining(DateTime until) {
  final diff = until.difference(DateTime.now());
  if (diff.isNegative) return 'expiré';
  if (diff.inHours >= 24) return '${diff.inDays} j';
  if (diff.inHours >= 1) return '${diff.inHours} h';
  return '${diff.inMinutes} min';
}
