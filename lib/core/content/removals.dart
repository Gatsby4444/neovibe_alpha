import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../supabase_providers.dart';

/// **Ce qui a disparu d'une conversation** — l'ACQUISITION (2026-09-25).
///
/// Jay : *« il faut qu'une suppression soit effective immédiatement »*. Le
/// temps réel de Supabase ne sait pas filtrer une suppression par
/// conversation : la ligne partie, rien ne peut plus dire à qui l'annoncer.
/// Le serveur ÉCRIT donc chaque disparition dans `removals` (déclencheurs
/// sur `library_vibes` et `messages`, quel que soit le chemin — auteur,
/// organisateur, purge) — un ajout comme un autre, filtré par conversation
/// et par la politique de lecture.
///
/// Rend les identifiants disparus depuis 24 h : Vibes du Drop et containers
/// du chat (les identifiants ne se croisent pas d'une table à l'autre).
///
/// ⚠️ Ne décide de rien : le chat retire ses messages
/// (`visibleMessagesProvider`), le Drop se relit
/// (`conversationLibraryProvider`), les visionneurs se ferment — chacun à
/// sa manière, sans que cette source sache qui l'écoute.
final removalsProvider = StreamProvider.autoDispose.family<Set<String>, String>(
  (ref, conversationId) {
    // Le jeton temps réel renouvelé fait repartir l'abonnement (voir
    // `messagesStreamProvider`).
    ref.watch(realtimeEpochProvider);
    return ref
        .watch(supabaseProvider)
        .from('removals')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .map((rows) => {for (final r in rows) r['target_id'] as String});
  },
);
