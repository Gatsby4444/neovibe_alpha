import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/profile.dart';

final supabaseProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

/// Compteur de renouvellements du jeton temps réel. **Voir `main.dart`.**
///
/// ⚠️ Il n'existe que pour une raison : **un `StreamProvider` en erreur y
/// reste**. Le renouvellement du jeton ne change ni l'identifiant de
/// l'utilisateur, ni le client Supabase — Riverpod n'a donc aucune raison de
/// reconstruire les abonnements, et ceux qui étaient tombés restent tombés.
final realtimeEpoch = ValueNotifier<int>(0);

/// À **surveiller par tout provider adossé au temps réel.**
///
/// Défaut relevé dans le journal de Jay le 2026-08-17 :
/// `InvalidJWTToken: Token has expired 4847 seconds ago`. Le socle temps réel
/// gardait le jeton avec lequel il s'était ouvert — mort depuis 80 minutes. Les
/// demandes de connexion cessaient d'arriver, **sans le moindre symptôme**.
///
/// Surveiller ce compteur fait repartir l'abonnement avec le jeton frais.
final realtimeEpochProvider = Provider<int>((ref) {
  void bump() => ref.invalidateSelf();
  realtimeEpoch.addListener(bump);
  ref.onDispose(() => realtimeEpoch.removeListener(bump));
  return realtimeEpoch.value;
});

final currentUserProvider = Provider<User?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser;
});

final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(currentUserProvider)?.id,
);

/// Profil de l'utilisateur courant (null si pas encore créé → onboarding).
///
/// ## 🔴 L'app ne s'ouvrait pas sans réseau — corrigé le 2026-09-20
///
/// Ce profil est la porte de l'app (`RootGate`) : tant qu'il n'est pas
/// chargé, rien ne s'affiche. Il ne venait QUE du serveur. Mode avion,
/// Wi-Fi coupé : « Failed host lookup », et un écran d'erreur à la place de
/// l'app — pour une app censée dépendre du réseau le moins possible (Jay).
///
/// Désormais la dernière ligne de profil reçue est **gardée sur l'appareil**
/// (`SharedPreferences`, par utilisateur). À l'ouverture : la copie locale
/// tout de suite, le serveur ensuite ; si le serveur ne répond pas, la copie
/// reste. Le réseau met le profil à jour, il ne conditionne plus l'entrée.
class MyProfile extends AsyncNotifier<Profile?> {
  static String _cle(String userId) => 'profile_cache_$userId';

  @override
  Future<Profile?> build() async {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cle(userId));
    if (cached == null) {
      // Première ouverture sur cet appareil : il faut le serveur.
      return _fetch(userId, prefs);
    }
    // La copie locale sert tout de suite ; le serveur affine derrière.
    unawaited(_refresh(userId, prefs));
    return Profile.fromJson(jsonDecode(cached) as Map<String, dynamic>);
  }

  Future<Profile?> _fetch(String userId, SharedPreferences prefs) async {
    final data = await ref
        .read(supabaseProvider)
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();
    if (data == null) {
      await prefs.remove(_cle(userId));
      return null;
    }
    await prefs.setString(_cle(userId), jsonEncode(data));
    return Profile.fromJson(data);
  }

  Future<void> _refresh(String userId, SharedPreferences prefs) async {
    try {
      final fresh = await _fetch(userId, prefs);
      if (ref.mounted) state = AsyncData(fresh);
    } catch (_) {
      // Pas de réseau : la copie locale reste. Ce n'est pas une erreur, c'est
      // l'état normal d'un téléphone en mode avion.
    }
  }
}

final myProfileProvider = AsyncNotifierProvider<MyProfile, Profile?>(
  MyProfile.new,
);
