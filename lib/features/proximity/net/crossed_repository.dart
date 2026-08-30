import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';

/// Quelqu'un qu'on a croisé dans les dernières 24 h, **et qui n'est pas un ami**.
///
/// ⚠️ **Ce n'est pas un « inconnu à portée ».** Le ping affiche les gens
/// présents *maintenant* ; ceci est la mémoire de la journée. Les deux ne se
/// confondent pas : on peut envoyer une Vibe à quelqu'un qu'on a croisé ce
/// matin et qui est parti depuis longtemps.
class CrossedPerson {
  const CrossedPerson({
    required this.userId,
    required this.displayName,
    required this.crossedAt,
    required this.alreadyRequested,
    this.tagName,
    this.avatarUrl,
  });

  final String userId;
  final String displayName;
  final String? tagName;
  final String? avatarUrl;
  final DateTime crossedAt;

  /// Une demande d'ami est déjà en attente vers cette personne.
  ///
  /// ⚠️ **Ça n'empêche PAS de lui envoyer une Vibe** : le serveur accroche
  /// alors la nouvelle Vibe à la demande existante plutôt que de refuser.
  /// Refuser laisserait l'utilisateur devant un mur sans issue.
  final bool alreadyRequested;

  factory CrossedPerson.fromJson(Map<String, dynamic> json) => CrossedPerson(
    userId: json['user_id'] as String,
    displayName: json['display_name'] as String? ?? 'Quelqu\'un',
    tagName: json['tag_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    crossedAt: DateTime.parse(json['crossed_at'] as String).toLocal(),
    alreadyRequested: json['already_requested'] as bool? ?? false,
  );

  /// ⚠️ **L'égalité de valeur est obligatoire** pour toute vue dérivée
  /// (`DerivedList`, `ValueList`) : sans elle, elles sont inopérantes EN
  /// SILENCE — elles réveillent l'écran à chaque publication, même identique.
  /// C'est ce qui manquait à tous les modèles avant le 2026-08-25.
  @override
  bool operator ==(Object other) =>
      other is CrossedPerson &&
      other.userId == userId &&
      other.displayName == displayName &&
      other.tagName == tagName &&
      other.avatarUrl == avatarUrl &&
      other.crossedAt == crossedAt &&
      other.alreadyRequested == alreadyRequested;

  @override
  int get hashCode => Object.hash(
    userId,
    displayName,
    tagName,
    avatarUrl,
    crossedAt,
    alreadyRequested,
  );
}

/// **L'ACQUISITION** : qui ai-je croisé aujourd'hui ?
///
/// ⚠️ **Le serveur filtre, l'app n'écarte rien.** `crossed_recently` retire
/// déjà les amis et les personnes bloquées. Rendre des gens que l'app devrait
/// ensuite masquer, ce serait confier une règle au client — exactement ce qui
/// avait laissé le blocage entre ses mains jusqu'au 2026-08-28
/// (`RAPPELS.md` #93).
///
/// ⚠️ **La fenêtre de 24 h n'est écrite nulle part ici.** Elle vit dans
/// `private.fenetre_croisement()`, et elle vaut exactement la rétention de
/// `ping_pairs` : le droit expire quand la preuve disparaît, sans ménage
/// séparé. La recopier côté Dart ferait une seconde définition, qui finirait
/// par diverger sans que rien ne le signale.
final crossedRecentlyProvider = FutureProvider<List<CrossedPerson>>((
  ref,
) async {
  final client = ref.watch(supabaseProvider);
  if (ref.watch(currentUserIdProvider) == null) return const [];
  final rows = await client.rpc('crossed_recently') as List;
  return [
    for (final row in rows)
      CrossedPerson.fromJson((row as Map).cast<String, dynamic>()),
  ];
});
