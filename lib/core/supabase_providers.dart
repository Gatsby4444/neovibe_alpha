import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
final myProfileProvider = FutureProvider<Profile?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  final data = await ref
      .watch(supabaseProvider)
      .from('profiles')
      .select()
      .eq('id', userId)
      .maybeSingle();
  return data == null ? null : Profile.fromJson(data);
});
