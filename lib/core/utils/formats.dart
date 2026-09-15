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

/// Un moment, passé ou à venir, en français de tous les jours : « aujourd'hui
/// à 21:30 », « demain à 21:30 », « mardi 15 septembre à 21:30 ». Sert aux
/// événements (2026-09-12), dont les dates sont réelles et pas floues.
String dayAndTime(DateTime when) {
  final local = when.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = day.difference(today).inDays;
  final heure = shortTime(local);
  if (diff == 0) return "aujourd'hui à $heure";
  if (diff == 1) return 'demain à $heure';
  if (diff == -1) return 'hier à $heure';
  final jour = _joursFr[local.weekday - 1];
  final base = '$jour ${local.day} ${_moisFr[local.month - 1]}';
  return local.year == now.year
      ? '$base à $heure'
      : '$base ${local.year} à $heure';
}

/// Temps restant avant expiration (messages éphémères, liens partiels).
String remaining(DateTime until) {
  final diff = until.difference(DateTime.now());
  if (diff.isNegative) return 'expiré';
  if (diff.inHours >= 24) return '${diff.inDays} j';
  if (diff.inHours >= 1) return '${diff.inHours} h';
  return '${diff.inMinutes} min';
}

/// L'âge d'une publication, en français court : « à l'instant », « il y a
/// 5 min », « il y a 3 h », « hier », « il y a 3 j », puis la date.
String timeAgo(DateTime when, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(when);
  if (diff.inSeconds < 60) return 'à l\'instant';
  if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
  if (diff.inDays == 1) return 'hier';
  if (diff.inDays < 7) return 'il y a ${diff.inDays} j';
  final local = when.toLocal();
  final mois = _moisFr[local.month - 1];
  if (local.year == ref.year) return '${local.day} $mois';
  return '${local.day} $mois ${local.year}';
}
