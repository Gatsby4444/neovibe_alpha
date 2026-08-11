-- Le blocage coupe aussi le RELAIS, pas seulement l'accès direct.
--
-- Sans cela il restait deux trous, tous deux ouverts par la propagation :
--   1. un repartage **reçu avant** le blocage continuait de donner accès ;
--   2. on pouvait relayer un contenu vers quelqu'un qui vous a bloqué — ou
--      pire, vers quelqu'un que l'AUTEUR a bloqué, ce qui aurait fait du
--      relais un moyen de contourner le blocage d'un tiers.
--
-- Un blocage doit couper le lien, pas seulement la porte d'entrée principale.

create or replace function private.story_audience(p_story_id uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from stories s
    where s.id = p_story_id
      and s.expires_at > now()
      and not private.is_revoked(s.id)
      and (
        s.owner_id = p_uid
        or can_view_stories(s.owner_id, p_uid)
        or exists (
          select 1 from content_grants g
          where g.content_id = s.id
            and g.grantee_id = p_uid
            -- Un relais reçu de quelqu'un que j'ai bloqué depuis ne vaut plus.
            and not private.is_blocked(g.granted_by, p_uid)
        )
      )
  );
$$;

create or replace function private.publication_audience(p_item_id uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from library_items li
    where li.id = p_item_id
      and not private.is_revoked(li.id)
      and (
        li.owner_id = p_uid
        or can_view_library(li.owner_id, p_uid)
        or (li.is_public and can_view_profile(p_uid, li.owner_id))
        or exists (
          select 1 from content_grants g
          where g.content_id = li.id
            and g.grantee_id = p_uid
            and not private.is_blocked(g.granted_by, p_uid)
        )
      )
  );
$$;

grant execute on function private.story_audience(uuid, uuid) to authenticated;
grant execute on function private.publication_audience(uuid, uuid) to authenticated;

-- On ne relaie pas vers quelqu'un avec qui on est bloqué.
create or replace function public.share_content(
  p_content_id uuid,
  p_conversation_id uuid
)
returns integer
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_shareable boolean;
  v_context public.content_context;
  v_added integer;
begin
  select shareable, context into v_shareable, v_context
  from contents where id = p_content_id and revoked_at is null;

  if not found then
    raise exception 'Contenu introuvable';
  end if;

  if v_context = 'direct' or v_context = 'conversation_library' then
    raise exception 'Ce contenu n''est pas partageable';
  end if;

  if not v_shareable then
    raise exception 'Ce contenu n''est pas partageable';
  end if;

  if not private.content_audience(p_content_id, v_me) then
    raise exception 'Contenu introuvable';
  end if;

  if not exists (
    select 1 from conversation_members
    where conversation_id = p_conversation_id and user_id = v_me
  ) then
    raise exception 'Conversation introuvable';
  end if;

  insert into content_grants (content_id, grantee_id, granted_by, conversation_id)
  select p_content_id, m.user_id, v_me, p_conversation_id
  from conversation_members m
  where m.conversation_id = p_conversation_id
    and m.user_id <> v_me
    -- Ni vers quelqu'un que je bloque, ni vers quelqu'un qui me bloque.
    and not private.is_blocked(v_me, m.user_id)
    -- Ni vers quelqu'un que l'AUTEUR a bloqué : relayer ne doit pas servir à
    -- contourner le blocage de quelqu'un d'autre.
    and not private.is_blocked(
      (select owner_id from contents where id = p_content_id), m.user_id);

  get diagnostics v_added = row_count;

  insert into messages (conversation_id, sender_id, kind, content_id)
  values (p_conversation_id, v_me, 'content_share', p_content_id);

  return v_added;
end;
$$;

revoke all on function public.share_content(uuid, uuid) from public, anon;
grant execute on function public.share_content(uuid, uuid) to authenticated;

-- Le blocage, côté client.
create or replace function public.block_user(p_user_id uuid)
returns void
language sql
security definer
set search_path = 'public'
as $$
  insert into blocks (blocker_id, blocked_id)
  values (auth.uid(), p_user_id)
  on conflict do nothing;
$$;

create or replace function public.unblock_user(p_user_id uuid)
returns void
language sql
security definer
set search_path = 'public'
as $$
  delete from blocks where blocker_id = auth.uid() and blocked_id = p_user_id;
$$;

revoke all on function public.block_user(uuid) from public, anon;
revoke all on function public.unblock_user(uuid) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;
grant execute on function public.unblock_user(uuid) to authenticated;
