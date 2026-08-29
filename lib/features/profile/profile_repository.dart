import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

/// **Toutes les écritures sur `profiles`, en un seul endroit.**
///
/// ⚠️ **Créé le 2026-08-25** (checkup `RAPPELS.md` #52). Ces trois écritures
/// vivaient dans trois écrans différents — réglages de confidentialité, édition
/// de profil, inscription — et chacune connaissait par cœur le nom des colonnes.
///
/// Deux raisons de les rassembler, et la seconde compte plus que la première :
///
/// 1. **Le jour où une colonne est renommée**, il fallait la retrouver dans
///    trois écrans, sans qu'aucun outil ne signale l'oubli.
/// 2. **Chacune décidait aussi d'invalider le cache** — ou oubliait de le
///    faire. Le rafraîchissement du profil est une conséquence de l'écriture,
///    pas une décision d'écran : deux écrans qui écrivent la même table doivent
///    laisser le lecteur dans le même état, sinon l'un affiche du périmé et
///    l'autre non, selon lequel a servi.
///
/// C'est aussi un pas vers la couche d'abstraction des accès aux données
/// (`RAPPELS.md` #12) : le coût de sortie de Supabase se compte en nombre
/// d'endroits qui connaissent son API.
class ProfileRepository {
  ProfileRepository(this.ref);

  final Ref ref;

  /// Crée la ligne de profil à l'inscription.
  ///
  /// ⚠️ **Avant tout dépôt d'avatar** : `AvatarService.upload` met le profil à
  /// jour, donc sans la ligne la photo atterrirait dans le coffre sans que rien
  /// ne la désigne.
  Future<void> create({required String userId, required String displayName}) =>
      _write(
        () => ref.read(supabaseProvider).from('profiles').insert({
          'id': userId,
          'display_name': displayName,
        }),
      );

  /// Le pseudo, le tag et la bio.
  Future<void> updateIdentity({
    required String displayName,
    String? tagName,
    String? bio,
  }) => _write(
    () => ref
        .read(supabaseProvider)
        .from('profiles')
        .update({
          'display_name': displayName,
          'tag_name': (tagName?.isEmpty ?? true) ? null : tagName,
          'bio': (bio?.isEmpty ?? true) ? null : bio,
        })
        .eq('id', _me),
  );

  /// La **mention spéciale** et son interrupteur.
  ///
  /// ⚠️ **Écrits ensemble, dans une seule opération.** Séparer les deux
  /// laisserait un instant où la mention existe déjà et où l'interrupteur n'est
  /// pas encore posé — ou l'inverse. Sur un texte destiné à des inconnus, cet
  /// instant-là est exactement celui qu'il ne faut pas créer.
  Future<void> updateSpecialMention({
    required String? mention,
    required bool public,
  }) => _write(
    () => ref
        .read(supabaseProvider)
        .from('profiles')
        .update({
          'special_mention': (mention?.isEmpty ?? true) ? null : mention,
          // Une mention vide ne peut pas être publique : il n'y a rien à
          // publier. Énoncé positivement plutôt que laissé à l'écran.
          'special_mention_public': (mention?.isEmpty ?? true) ? false : public,
        })
        .eq('id', _me),
  );

  /// Recevoir les waves en temps réel, ou en différé (le défaut).
  Future<void> setRealtimeWaves(bool value) => _write(
    () => ref
        .read(supabaseProvider)
        .from('profiles')
        .update({'realtime_waves': value})
        .eq('id', _me),
  );

  // ⚠️ `stories_public` n'est PAS ici : `StoriesRepository.setStoriesPublic`
  // l'écrit déjà. Deux chemins vers la même colonne, c'est la règle 3 de
  // `CLAUDE.md` — et le jour où les deux divergent, rien ne le signale.

  String get _me => ref.read(currentUserIdProvider)!;

  /// ⚠️ **L'invalidation appartient à l'écriture, pas à l'appelant.** C'est la
  /// seule façon que deux écrans qui touchent la même table laissent le lecteur
  /// dans le même état.
  Future<void> _write(Future<void> Function() action) async {
    await action();
    ref.invalidate(myProfileProvider);
  }
}

final profileRepositoryProvider = Provider(ProfileRepository.new);
