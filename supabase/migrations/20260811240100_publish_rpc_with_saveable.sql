-- Les deux RPC de publication acceptent `saveable`.
--
-- ⚠️ **Les anciennes signatures sont supprimées explicitement.** Ajouter un
-- paramètre avec valeur par défaut CRÉE UNE SURCHARGE, elle ne remplace pas :
-- les deux versions coexistaient, et PostgREST n'aurait pas su laquelle
-- appeler (« could not choose the best candidate function »). Erreur qui ne se
-- serait vue qu'à l'exécution — relevée ici en vérifiant `pg_proc` après
-- application, pas en relisant le code.
--
-- Règle : en faisant évoluer une RPC, supprimer l'ancienne signature dans la
-- même migration.

drop function if exists public.publish_story(uuid, public.card_type, text, text, boolean, boolean, boolean, text);
drop function if exists public.publish_to_library(uuid, public.card_type, text, text, boolean, boolean, text, boolean, boolean, text);

create or replace function public.publish_story(
  p_story_id uuid,
  p_card_type public.card_type,
  p_front_path text,
  p_back_path text,
  p_front_is_video boolean,
  p_back_is_video boolean,
  p_shareable boolean,
  p_media_key text,
  p_saveable boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Authentification requise';
  end if;

  insert into contents (id, owner_id, context, shareable, saveable)
  values (p_story_id, v_me, 'story', coalesce(p_shareable, false),
          coalesce(p_saveable, false));

  insert into stories (
    id, owner_id, card_type, front_path, back_path,
    front_is_video, back_is_video
  )
  values (
    p_story_id, v_me, p_card_type, p_front_path, p_back_path,
    coalesce(p_front_is_video, false), coalesce(p_back_is_video, false)
  );

  insert into content_media_keys (content_id, media_key)
  values (p_story_id, p_media_key);

  return p_story_id;
end;
$$;

create or replace function public.publish_to_library(
  p_item_id uuid,
  p_card_type public.card_type,
  p_front_path text,
  p_back_path text,
  p_front_is_video boolean,
  p_back_is_video boolean,
  p_caption text,
  p_is_public boolean,
  p_shareable boolean,
  p_media_key text,
  p_saveable boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Authentification requise';
  end if;

  insert into contents (id, owner_id, context, shareable, saveable)
  values (p_item_id, v_me, 'publication', coalesce(p_shareable, false),
          coalesce(p_saveable, false));

  insert into library_items (
    id, owner_id, card_type, front_path, back_path,
    front_is_video, back_is_video, caption, is_public
  )
  values (
    p_item_id, v_me, p_card_type, p_front_path, p_back_path,
    coalesce(p_front_is_video, false), coalesce(p_back_is_video, false),
    nullif(p_caption, ''), coalesce(p_is_public, false)
  );

  insert into content_media_keys (content_id, media_key)
  values (p_item_id, p_media_key);

  return p_item_id;
end;
$$;

revoke all on function public.publish_story(uuid, public.card_type, text, text, boolean, boolean, boolean, text, boolean) from public, anon;
revoke all on function public.publish_to_library(uuid, public.card_type, text, text, boolean, boolean, text, boolean, boolean, text, boolean) from public, anon;
grant execute on function public.publish_story(uuid, public.card_type, text, text, boolean, boolean, boolean, text, boolean) to authenticated;
grant execute on function public.publish_to_library(uuid, public.card_type, text, text, boolean, boolean, text, boolean, boolean, text, boolean) to authenticated;
