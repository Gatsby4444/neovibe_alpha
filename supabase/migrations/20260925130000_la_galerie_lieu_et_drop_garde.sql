-- =============================================================================
-- LA GALERIE : LIEU DE PRISE, NOM DU LIEU, DROP D'ÉVÉNEMENT GARDÉ — 2026-09-25
-- =============================================================================
--
-- Décisions de Jay pour la nouvelle galerie (des Vibes datées et situées, pas
-- des portes vers des récaps) :
--
-- 1. **Le lieu de prise est toujours enregistré, sur le serveur, lisible par
--    son seul auteur** (`capture_places`). Il n'est PARTAGÉ que si l'auteur le
--    choisit (« Localiser », `contents.anchor_*`) — deux objets, deux règles :
--    ce journal privé n'est jamais lu par un autre chemin. Ce qui est gardé
--    est la case de 100 m (`ContentAnchor.gomme`), pas le point exact.
--    ⚠️ Donnée sensible : l'historique des lieux d'un compte. Effaçable par
--    son auteur ; sa durée de conservation reste à trancher (RAPPELS #170).
-- 2. **Le nom du lieu d'un événement** est posé par son créateur
--    (`events.place_name`, `set_event_place`) — un gérant de boîte y met le
--    nom de sa boîte. Pour un établissement, à défaut, le nom du lieu
--    enregistré. Rendu par `my_events` / `nearby_events` dans la colonne
--    existante `venue_name` (« le nom du lieu »), sans changer leur forme.
-- 3. **Un Drop d'événement est gardé par tous ceux qui y étaient**, sauf ses
--    Vibes éphémères : « sauvegardable par les autres » n'y est plus une
--    option — il suit « éphémère », à l'ajout comme à la modification.
-- =============================================================================

-- ─── 1. Le lieu de prise ────────────────────────────────────────────────────

create table public.capture_places (
  -- L'objet serveur né de la prise : une Card, une Vibe de Drop, un contenu
  -- (story, publication). Une prise envoyée à trois endroits = trois lignes.
  object_id uuid primary key,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  taken_at timestamptz not null,
  lat double precision,
  lon double precision,
  created_at timestamptz not null default now(),
  check ((lat is null) = (lon is null))
);
create index capture_places_owner_idx on public.capture_places (owner_id, taken_at);
alter table public.capture_places enable row level security;
-- ⚠️ Son auteur, et personne d'autre — aucune fonction ne le lit pour autrui.
create policy capture_places_select_own on public.capture_places
  for select to authenticated using (owner_id = (select auth.uid()));
create policy capture_places_insert_own on public.capture_places
  for insert to authenticated with check (owner_id = (select auth.uid()));
create policy capture_places_delete_own on public.capture_places
  for delete to authenticated using (owner_id = (select auth.uid()));

-- ─── 2. Le nom du lieu d'un événement ───────────────────────────────────────

alter table public.events add column place_name text
  check (place_name is null or (place_name = btrim(place_name) and char_length(place_name) between 1 and 60));

create function public.set_event_place(p_event uuid, p_place_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := nullif(btrim(coalesce(p_place_name, '')), '');
begin
  if v_name is not null and char_length(v_name) > 60 then
    raise exception 'Nom du lieu trop long (60 caractères au plus)';
  end if;
  update public.events set place_name = v_name
   where id = p_event and created_by = auth.uid();
  if not found then raise exception 'Seul le créateur nomme le lieu'; end if;
end;
$$;
revoke all on function public.set_event_place(uuid, text) from public, anon;
grant execute on function public.set_event_place(uuid, text) to authenticated;

-- « Le nom du lieu » : celui du créateur, sinon celui de l'établissement.
CREATE OR REPLACE FUNCTION public.my_events()
 RETURNS TABLE(id uuid, kind event_kind, title text, venue_name text, created_by uuid, conversation_id uuid, lat double precision, lon double precision, radius_m integer, starts_at timestamp with time zone, scheduled_end_at timestamp with time zone, opened_at timestamp with time zone, closed_at timestamp with time zone, members_can_add boolean, members_can_remove boolean, library_reveal_at timestamp with time zone, present_count integer, guest_count integer, i_am_present boolean, my_role event_role, i_manage boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  return query
  select e.id, e.kind, e.title, coalesce(e.place_name, v.name),
         e.created_by, e.conversation_id,
         e.lat, e.lon, e.radius_m,
         e.starts_at, e.scheduled_end_at, e.opened_at, e.closed_at,
         e.members_can_add, e.members_can_remove, e.library_reveal_at,
         (select count(*)::integer from public.event_presences p
           where p.event_id = e.id and p.left_at is null),
         (select count(*)::integer from public.event_group_members m
           where m.event_id = e.id),
         private.is_present_in_event(e.id, me),
         (select m.role from public.event_group_members m
           where m.event_id = e.id and m.user_id = me),
         (e.venue_id is not null and private.manages_venue(e.venue_id, me))
  from public.events e
  left join public.venues v on v.id = e.venue_id
  where private.concerned_by_event(e.id, me)
  order by (e.closed_at is null) desc, e.starts_at desc;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nearby_events(p_lat double precision, p_lon double precision)
 RETURNS TABLE(id uuid, kind event_kind, title text, venue_name text, venue_address text, lat double precision, lon double precision, radius_m integer, starts_at timestamp with time zone, scheduled_end_at timestamp with time zone, present_count integer, distance_m integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
  r public.event_rules;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into r from public.event_rules;
  return query
  select e.id, e.kind, e.title, coalesce(e.place_name, v.name), v.address, e.lat, e.lon, e.radius_m,
         e.starts_at, e.scheduled_end_at,
         -- « N personnes connectées ici » (Jay, 2026-09-21) : les présents,
         -- c'est-à-dire ceux dont la présence est prouvée en ce moment.
         (select count(*)::integer from public.event_presences p
           where p.event_id = e.id and p.left_at is null),
         round(private.meters_between(p_lat, p_lon, e.lat, e.lon))::integer
  from public.events e
  left join public.venues v on v.id = e.venue_id
  where e.kind in ('venue', 'open') and e.closed_at is null and e.starts_at <= now()
    and e.lat is not null
    and private.meters_between(p_lat, p_lon, e.lat, e.lon) <= r.nearby_radius_m
    and not private.is_blocked(me, e.created_by)
  order by 12;
end;
$function$
;

-- ─── 3. Le Drop d'événement gardé par tous ──────────────────────────────────

create or replace function private.unguarded_add_vibe_to_library(
  p_id uuid,
  p_conversation_id uuid,
  p_placeholder_path text,
  p_sealed_path text,
  p_media_key text,
  p_card_type public.card_type,
  p_front_is_video boolean,
  p_back_is_video boolean,
  p_saveable_by_others boolean,
  p_ephemeral boolean,
  p_placeholder_back_path text,
  p_sealed_back_path text,
  p_challenge_id uuid,
  p_title text,
  p_camera_only boolean
)
returns public.library_vibes
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_timezone text;
  v_type public.conversation_type;
  v_reveal timestamptz;
  v_vibe public.library_vibes;
  v_event public.events;
  -- Un titre vide ou fait d'espaces n'est pas un titre.
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
begin
  if not exists (
    select 1 from conversation_members
    where conversation_id = p_conversation_id and user_id = auth.uid()
  ) then
    raise exception 'Conversation introuvable';
  end if;

  if p_card_type in ('bereal', 'one_of_one') then
    raise exception 'Ce type de vibe n''entre pas en bibliotheque';
  end if;

  -- 2026-09-25 : de vraies photos ou vidéos, déclarées par l'app.
  if p_camera_only is distinct from true then
    raise exception 'Le Drop n''accepte que des photos ou vidéos prises à la caméra';
  end if;

  if v_title is not null and char_length(v_title) > 60 then
    raise exception 'Titre trop long (60 caractères au plus)';
  end if;

  select library_timezone, conversation_type into v_timezone, v_type
  from conversations where id = p_conversation_id;

  if v_type = 'event' then
    -- 2026-09-25 : ouvert, et j'y suis.
    select * into v_event from public.events where conversation_id = p_conversation_id;
    if not found or v_event.closed_at is not null then
      raise exception 'Cet événement est terminé : son Drop est fermé';
    end if;
    if not exists (
      select 1 from public.event_presences
      where event_id = v_event.id and user_id = auth.uid() and left_at is null
    ) then
      raise exception 'Tu n''es plus dans cet événement : son Drop t''est fermé';
    end if;

    -- 2026-09-21 : visible tout de suite, pour les participants (Jay :
    -- « voir ce qui a été publié au cours de la soirée »). Le placeholder
    -- flouté ne sert plus qu'à l'affichage en attendant le scellé.
    v_reveal := now();
    if p_challenge_id is not null and not exists (
      select 1 from public.event_challenges c
      where c.id = p_challenge_id and c.event_id = v_event.id
    ) then
      raise exception 'Défi introuvable';
    end if;
  else
    if p_challenge_id is not null then raise exception 'Un défi appartient à un événement'; end if;
    v_reveal := library_reveal_at(v_timezone);
  end if;

  insert into library_vibes (
    id, conversation_id, author_id, reveal_at,
    card_type, front_is_video, back_is_video,
    saveable_by_others, ephemeral,
    placeholder_path, sealed_path,
    placeholder_back_path, sealed_back_path,
    challenge_id, title
  )
  values (
    p_id, p_conversation_id, auth.uid(),
    v_reveal,
    p_card_type, p_front_is_video, p_back_is_video,
    -- Drop d'ÉVÉNEMENT (2026-09-25) : sauvegardable par tous, sauf éphémère
    -- — ce n'est plus une option de l'auteur.
    case when v_type = 'event' then not p_ephemeral else p_saveable_by_others end,
    p_ephemeral,
    p_placeholder_path, p_sealed_path,
    p_placeholder_back_path, p_sealed_back_path,
    p_challenge_id, v_title
  )
  returning * into v_vibe;

  insert into library_vibe_keys (vibe_id, media_key) values (v_vibe.id, p_media_key);

  insert into messages (conversation_id, sender_id, kind, body)
  values (p_conversation_id, auth.uid(), 'library_add', null);

  return v_vibe;
end;
$$;


create or replace function public.update_drop_vibe(
  p_vibe_id uuid,
  p_title text,
  p_saveable_by_others boolean,
  p_ephemeral boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
begin
  perform private.assert_not_suspended();
  if v_title is not null and char_length(v_title) > 60 then
    raise exception 'Titre trop long (60 caractères au plus)';
  end if;
  update public.library_vibes
     set title = v_title,
         ephemeral = coalesce(p_ephemeral, ephemeral),
         -- Drop d'événement : suit « éphémère », jamais l'auteur (2026-09-25).
         saveable_by_others = case
           when exists (select 1 from public.conversations c
                        where c.id = library_vibes.conversation_id
                          and c.conversation_type = 'event')
             then not coalesce(p_ephemeral, ephemeral)
           else coalesce(p_saveable_by_others, saveable_by_others) end
   where id = p_vibe_id and author_id = auth.uid();
  if not found then raise exception 'Seul son auteur peut modifier cette Vibe'; end if;
end;
$$;


-- Les Vibes déjà dans un Drop d'événement suivent la nouvelle règle.
update public.library_vibes v
   set saveable_by_others = not v.ephemeral
  from public.conversations c
 where c.id = v.conversation_id and c.conversation_type = 'event'
   and v.saveable_by_others is distinct from (not v.ephemeral);
