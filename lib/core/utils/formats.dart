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

/// Temps restant avant expiration (messages éphémères, liens partiels).
String remaining(DateTime until) {
  final diff = until.difference(DateTime.now());
  if (diff.isNegative) return 'expiré';
  if (diff.inHours >= 24) return '${diff.inDays} j';
  if (diff.inHours >= 1) return '${diff.inHours} h';
  return '${diff.inMinutes} min';
}
