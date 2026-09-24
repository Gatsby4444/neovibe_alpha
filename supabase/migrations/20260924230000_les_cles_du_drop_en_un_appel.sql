-- =============================================================================
-- LES CLÉS D'UN DROP, EN UN APPEL — 2026-09-24
-- =============================================================================
--
-- Jay, option (A) : des vignettes nettes et une Vibe qui s'ouvre sans attendre,
-- SANS renoncer au chiffrement. Le temps perdu n'était pas le déchiffrement
-- (~2 ms pour une photo) mais les allers-retours : une question au serveur par
-- Vibe pour obtenir sa clé.
--
-- `drop_keys` rend toutes les clés d'un Drop que je peux lire MAINTENANT.
--
-- ⚠️ **La même règle que `get_library_vibe_key`, et seulement elle** (règle 2 :
-- le transport se mutualise, la politique de clé ne s'élargit pas) :
-- - être membre de la conversation ;
-- - la Vibe est révélée (`now() >= reveal_at`).
-- Une Vibe pas encore révélée n'a PAS sa clé dans la réponse.
-- =============================================================================

create or replace function public.drop_keys(p_conversation_id uuid)
returns table (vibe_id uuid, media_key text)
language sql
stable
security definer
set search_path = ''
as $$
  select v.id, k.media_key
  from public.library_vibes v
  join public.library_vibe_keys k on k.vibe_id = v.id
  where v.conversation_id = p_conversation_id
    and now() >= v.reveal_at
    and exists (
      select 1 from public.conversation_members m
      where m.conversation_id = p_conversation_id
        and m.user_id = auth.uid()
    );
$$;

revoke all on function public.drop_keys(uuid) from public, anon;
grant execute on function public.drop_keys(uuid) to authenticated;

notify pgrst, 'reload schema';
