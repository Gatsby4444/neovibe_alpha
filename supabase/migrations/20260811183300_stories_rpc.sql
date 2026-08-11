-- Les RPC des stories — la seule porte d'entrée du client.
--
-- `publish_story` crée l'identité, le format et la clé dans UNE transaction :
-- il ne peut exister ni story sans Content ID, ni fichier sans clé.
-- L'identifiant est fabriqué par le client (il en a besoin pour nommer les
-- fichiers avant de les téléverser), comme pour les Cards.
--
-- `open_story_media` ne DÉCOMPTE RIEN, contrairement à `open_card_media` :
-- une story n'a pas de limite de vues. C'est exactement ce que la séparation
-- des formats a rendu possible — la limite appartient au partage direct, la
-- story a sa propre règle. La vue est enregistrée pour les statistiques, pas
-- pour rationner.
--
-- `share_story` ne copie AUCUN octet : elle ajoute des arêtes au graphe,
-- c'est-à-dire des chemins vers l'unique média (définition de Jay : « la
-- référence n'est pas un fichier copié de la source, c'est un chemin »).

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

  insert into contents (id, owner_id, context)
  values (p_story_id, v_me, 'story');

  insert into stories (
    id, owner_id, card_type, front_path, back_path,
    front_is_video, back_is_video, shareable
  )
  values (
    p_story_id, v_me, p_card_type, p_front_path, p_back_path,
    coalesce(p_front_is_video, false), coalesce(p_back_is_video, false),
    coalesce(p_shareable, false)
  );

  insert into story_media_keys (story_id, media_key)
  values (p_story_id, p_media_key);

  return p_story_id;
end;
$$;

create or replace function public.open_story_media(p_story_id uuid)
returns text
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_owner uuid;
begin
  select owner_id into v_owner from stories where id = p_story_id;
  if not found then
    raise exception 'Story introuvable';
  end if;

  if not private.story_audience(p_story_id, v_me) then
    raise exception 'Story introuvable';
  end if;

  -- L'auteur qui relit sa propre story n'apparaît pas dans ses statistiques.
  if v_owner <> v_me then
    perform private.record_view(p_story_id, v_me);
  end if;

  return (select media_key from story_media_keys where story_id = p_story_id);
end;
$$;

create or replace function public.share_story(
  p_story_id uuid,
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
  v_added integer;
begin
  select shareable into v_shareable
  from stories
  where id = p_story_id and expires_at > now();

  if not found then
    raise exception 'Story introuvable';
  end if;

  if not v_shareable then
    raise exception 'Cette story n''est pas partageable';
  end if;

  -- Il faut faire partie de l'audience pour relayer. Cette seule condition
  -- suffit à produire la propagation sans limite de sauts voulue par Jay :
  -- celui qui a reçu par un repartage devient à son tour un relais possible.
  if not private.story_audience(p_story_id, v_me) then
    raise exception 'Story introuvable';
  end if;

  if not exists (
    select 1 from conversation_members
    where conversation_id = p_conversation_id and user_id = v_me
  ) then
    raise exception 'Conversation introuvable';
  end if;

  insert into content_grants (content_id, grantee_id, granted_by, conversation_id)
  select p_story_id, m.user_id, v_me, p_conversation_id
  from conversation_members m
  where m.conversation_id = p_conversation_id
    and m.user_id <> v_me;

  get diagnostics v_added = row_count;
  return v_added;
end;
$$;

-- Statistiques — DEUX fonctions, une question chacune.
--
-- Arbitrage de Jay : l'auteur voit qui a vu sa story, mais jamais qui a
-- partagé à qui (la chaîne reste à l'admin). L'agrégé suffit hors du cercle,
-- le nominatif complet est réservé à la future option premium. Le nominatif
-- est **enregistré** dans tous les cas (`content_views`) : seul l'affichage
-- est restreint, la base n'aura pas à être remontée le jour du premium.

-- Les spectateurs que l'auteur connaît, nommément.
create or replace function public.story_viewers(p_story_id uuid)
returns table (
  viewer_id uuid,
  display_name text,
  tag_name text,
  avatar_url text,
  first_viewed_at timestamptz
)
language sql
stable
security definer
set search_path = 'public'
as $$
  select v.viewer_id, p.display_name, p.tag_name, p.avatar_url, v.first_viewed_at
  from content_views v
  join profiles p on p.id = v.viewer_id
  where v.content_id = p_story_id
    and exists (
      select 1 from stories s
      where s.id = p_story_id and s.owner_id = auth.uid()
    )
    and private.can_view_profile(auth.uid(), v.viewer_id)
  order by v.first_viewed_at desc;
$$;

-- Le nombre de PERSONNES ayant vu, cercle compris. La différence avec
-- `story_viewers` est le nombre de spectateurs atteints par propagation.
-- (Compte des personnes, pas des ouvertures : `content_views` porte une ligne
-- par spectateur, avec son propre `view_count`.)
create or replace function public.story_viewer_count(p_story_id uuid)
returns integer
language sql
stable
security definer
set search_path = 'public'
as $$
  select coalesce(count(*), 0)::integer
  from content_views v
  where v.content_id = p_story_id
    and exists (
      select 1 from stories s
      where s.id = p_story_id and s.owner_id = auth.uid()
    );
$$;

revoke all on function public.publish_story(uuid, public.card_type, text, text, boolean, boolean, boolean, text) from public, anon;
revoke all on function public.open_story_media(uuid) from public, anon;
revoke all on function public.share_story(uuid, uuid) from public, anon;
revoke all on function public.story_viewers(uuid) from public, anon;
revoke all on function public.story_viewer_count(uuid) from public, anon;

grant execute on function public.publish_story(uuid, public.card_type, text, text, boolean, boolean, boolean, text) to authenticated;
grant execute on function public.open_story_media(uuid) to authenticated;
grant execute on function public.share_story(uuid, uuid) to authenticated;
grant execute on function public.story_viewers(uuid) to authenticated;
grant execute on function public.story_viewer_count(uuid) to authenticated;
