-- Les deux RPC de publication, alignées sur le socle unifié (2026-08-11).
--
-- Chacune crée, en UNE transaction : l'identité (avec sa partageabilité), la
-- ligne de format, et la clé. Il ne peut donc exister ni contenu sans Content
-- ID, ni fichier sans clé — et donc aucun fichier illisible faute de clé, ni
-- aucune clé orpheline.
--
-- L'identifiant est fabriqué par le client : il nomme les fichiers avant leur
-- téléversement.

create or replace function public.publish_story(
  p_story_id uuid,
  p_card_type public.card_type,
  p_front_path text,
  p_back_path text,
  p_front_is_video boolean,
  p_back_is_video boolean,
  p_shareable boolean,
  p_media_key text
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

  insert into contents (id, owner_id, context, shareable)
  values (p_story_id, v_me, 'story', coalesce(p_shareable, false));

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
  p_media_key text
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

  insert into contents (id, owner_id, context, shareable)
  values (p_item_id, v_me, 'publication', coalesce(p_shareable, false));

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

revoke all on function public.publish_story(uuid, public.card_type, text, text, boolean, boolean, boolean, text) from public, anon;
revoke all on function public.publish_to_library(uuid, public.card_type, text, text, boolean, boolean, text, boolean, boolean, text) from public, anon;
grant execute on function public.publish_story(uuid, public.card_type, text, text, boolean, boolean, boolean, text) to authenticated;
grant execute on function public.publish_to_library(uuid, public.card_type, text, text, boolean, boolean, text, boolean, boolean, text) to authenticated;
