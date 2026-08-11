-- LA CAUSE RÉELLE de la panne des stories et des publications (v0.9.48/49).
--
-- Symptôme : tout ce qui touchait `stories`, `library_items` ou `contents`
-- échouait, y compris les URL signées des buckets `stories` et `library`. Seul
-- le chat en DM continuait de fonctionner.
--
-- Cause : **une politique RLS s'évalue avec les droits de celui qui
-- interroge.** Si elle appelle une fonction, l'utilisateur doit pouvoir
-- EXÉCUTER cette fonction. J'avais révoqué ce droit sur toutes les fonctions
-- créées aux étapes 1 et 2 — chaque requête tombait donc sur
-- `permission denied for function story_audience`.
--
-- ─── Pourquoi je me suis trompé ─────────────────────────────────────────────
--
-- La leçon du 2026-08-10 disait : « toute fonction SECURITY DEFINER non
-- destinée aux clients doit être révoquée de public, anon, authenticated ».
-- Elle est juste, mais elle visait le schéma **`public`** — le seul exposé par
-- PostgREST, où une fonction reste joignable sur `/rest/v1/rpc/`.
--
-- Le schéma **`private` n'est pas exposé**. Y révoquer l'exécution ne protège
-- de rien et casse toutes les politiques qui s'appuient dessus. La preuve la
-- plus simple : l'audit de sécurité de Supabase ne signale JAMAIS une fonction
-- de `private` — il n'en liste que du schéma `public`.
--
-- Les anciennes fonctions du projet (`can_view_card_file`, `can_view_library`,
-- `can_view_profile`, `can_view_stories`, `has_unlimited_card_access`) ont
-- toutes ce droit d'exécution. C'est la convention établie, et c'est
-- exactement ce qui explique que le DM ait continué de marcher pendant que
-- tout le reste tombait.
--
-- ─── La règle à retenir ─────────────────────────────────────────────────────
--
-- Une fonction citée dans une politique **doit** être exécutable par
-- `authenticated`. Sa protection vient de `SECURITY DEFINER` et du schéma non
-- exposé — **jamais** du retrait du droit d'exécution.

grant execute on function private.story_audience(uuid, uuid) to authenticated;
grant execute on function private.publication_audience(uuid, uuid) to authenticated;
grant execute on function private.content_audience(uuid, uuid) to authenticated;
grant execute on function private.can_view_story_file(text, uuid) to authenticated;
grant execute on function private.can_view_publication_file(text, uuid) to authenticated;

-- `private.is_revoked` et `private.record_view` restent révoquées, à juste
-- titre : elles ne sont appelées que depuis l'INTÉRIEUR de fonctions
-- SECURITY DEFINER, où elles s'exécutent avec les droits du propriétaire.
-- Aucune politique ne les cite directement.
