-- Le socle devient réellement générique (2026-08-11).
--
-- L'étape 2 allait dupliquer, pour les publications, ce qui venait d'être
-- écrit pour les stories : une table de clés, une RPC d'ouverture, une RPC de
-- partage, deux fonctions de statistiques. Or ces quatre choses ne dépendent
-- **pas** du format — elles interrogent le socle `contents`. Les dupliquer
-- aurait installé la même règle à deux endroits, donc deux endroits à corriger
-- le jour où elle change.
--
-- Ce qui reste spécifique au format : l'**audience** (qui a le droit) et la
-- **publication** (les colonnes diffèrent). Tout le reste est commun.

-- 1. La partageabilité appartient au CONTENU, pas au format.
alter table public.contents add column shareable boolean not null default false;
alter table public.stories drop column shareable;
alter table public.library_items drop column shareable;

-- 2. Une seule table de clés.
create table public.content_media_keys (
  content_id uuid primary key references public.contents (id) on delete cascade,
  media_key text not null
);
alter table public.content_media_keys enable row level security;
-- Aucune politique : la clé ne sort que par `open_content_media`.

insert into public.content_media_keys (content_id, media_key)
select story_id, media_key from public.story_media_keys
on conflict do nothing;

drop table if exists public.story_media_keys;
drop table if exists public.library_media_keys;

-- 3. L'audience, aiguillée par contexte.
--
-- Règle **positive** : seul un contexte disposant d'une fonction d'audience
-- enregistrée ici accorde un accès. Les contextes `direct` et
-- `conversation_library` n'y figurent pas — ils ont leurs propres chemins
-- (livraison nominative, appartenance à la conversation) et ne passent pas par
-- le socle.
create or replace function private.content_audience(p_content_id uuid, p_uid uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = 'public', 'private'
as $$
declare
  v_context public.content_context;
begin
  select context into v_context from contents where id = p_content_id;
  if not found then
    return false;
  end if;
  return case v_context
    when 'story' then private.story_audience(p_content_id, p_uid)
    when 'publication' then private.publication_audience(p_content_id, p_uid)
    else false
  end;
end;
$$;

revoke all on function private.content_audience(uuid, uuid) from public, anon, authenticated;

-- 4. Ouvrir : une seule porte, pour tous les formats du socle.
--    AUCUN décompte — ni une story ni une publication n'a de limite de vues.
--    La vue est enregistrée pour les statistiques, pas pour rationner.
create or replace function public.open_content_media(p_content_id uuid)
returns text
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_owner uuid;
begin
  select owner_id into v_owner from contents where id = p_content_id;
  if not found or not private.content_audience(p_content_id, v_me) then
    raise exception 'Contenu introuvable';
  end if;

  -- L'auteur qui relit son propre contenu n'apparaît pas dans ses statistiques.
  if v_owner <> v_me then
    perform private.record_view(p_content_id, v_me);
  end if;

  return (select media_key from content_media_keys where content_id = p_content_id);
end;
$$;

-- 5. Les clés d'une bibliothèque entière, en UN aller-retour.
--    Une grille de publications demanderait sinon une requête par vignette.
--    Les contenus révoqués ou hors de mon audience ne sont pas renvoyés.
create or replace function public.library_media_keys(p_owner_id uuid)
returns table (content_id uuid, media_key text)
language sql
security definer
set search_path = 'public'
as $$
  select k.content_id, k.media_key
  from content_media_keys k
  join library_items li on li.id = k.content_id
  where li.owner_id = p_owner_id
    and private.content_audience(li.id, auth.uid());
$$;

-- 6. Repartager : aucun octet copié, des arêtes ajoutées au graphe.
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

  -- Un partage direct dans le cercle n'est JAMAIS repartageable : il s'adresse
  -- à des personnes nommées, il ne doit pas pouvoir en sortir. Idem pour une
  -- bibliothèque de conversation, qui appartient à ses membres.
  if v_context = 'direct' or v_context = 'conversation_library' then
    raise exception 'Ce contenu n''est pas partageable';
  end if;

  if not v_shareable then
    raise exception 'Ce contenu n''est pas partageable';
  end if;

  -- Faire partie de l'audience suffit pour relayer : c'est cette seule
  -- condition qui produit la propagation **sans limite de sauts** voulue par
  -- Jay — celui qui a reçu par un repartage devient à son tour un relais.
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
    and m.user_id <> v_me;

  get diagnostics v_added = row_count;
  return v_added;
end;
$$;

-- 7. Statistiques, communes à tous les formats.
--
-- Arbitrage de Jay : l'auteur voit qui a vu, mais jamais qui a partagé à qui
-- (la chaîne reste à l'admin). Les spectateurs hors de son cercle ne sont pas
-- nommés — mais le nominatif EST enregistré dans `content_views` : seule
-- l'affichage s'abstient, la base n'aura pas à être remontée le jour où
-- l'option premium l'ouvrira.
create or replace function public.content_viewers(p_content_id uuid)
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
  where v.content_id = p_content_id
    and exists (
      select 1 from contents c
      where c.id = p_content_id and c.owner_id = auth.uid()
    )
    and private.can_view_profile(auth.uid(), v.viewer_id)
  order by v.first_viewed_at desc;
$$;

create or replace function public.content_viewer_count(p_content_id uuid)
returns integer
language sql
stable
security definer
set search_path = 'public'
as $$
  select coalesce(count(*), 0)::integer
  from content_views v
  where v.content_id = p_content_id
    and exists (
      select 1 from contents c
      where c.id = p_content_id and c.owner_id = auth.uid()
    );
$$;

-- 8. Les versions spécifiques aux stories disparaissent.
drop function if exists public.open_story_media(uuid);
drop function if exists public.share_story(uuid, uuid);
drop function if exists public.story_viewers(uuid);
drop function if exists public.story_viewer_count(uuid);

revoke all on function public.open_content_media(uuid) from public, anon;
revoke all on function public.library_media_keys(uuid) from public, anon;
revoke all on function public.share_content(uuid, uuid) from public, anon;
revoke all on function public.content_viewers(uuid) from public, anon;
revoke all on function public.content_viewer_count(uuid) from public, anon;

grant execute on function public.open_content_media(uuid) to authenticated;
grant execute on function public.library_media_keys(uuid) to authenticated;
grant execute on function public.share_content(uuid, uuid) to authenticated;
grant execute on function public.content_viewers(uuid) to authenticated;
grant execute on function public.content_viewer_count(uuid) to authenticated;
