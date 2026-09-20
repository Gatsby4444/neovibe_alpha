-- ============================================================================
-- LE FEED (« Pulse ») — 2026-09-20, tranché par Jay
-- ============================================================================
--
-- Trois sources, toutes humaines, aucun algorithme :
--   1. les CROISÉS : le contenu PUBLIC des gens croisés dans les 3 derniers
--      jours (ping_pairs / event_crossings, fenêtres de `crossing_windows`) ;
--   2. les AJOUTS : ce qu'un AMI a ajouté à mon feed — anonyme jusqu'à ce que
--      je like (`feed_adds`) ;
--   3. le LIEU : ce qui a été LOCALISÉ par son auteur, à moins d'un rayon de
--      l'endroit où je suis (« Autour de moi »).
--
-- Les nombres (fenêtres, gommage, rayon, seuil) vivent dans `feed_rules`,
-- pas dans le code : une ligne à changer, pas une version de l'app.
--
-- ⚠️ La localisation est un CONSENTEMENT à part de « Public » : non par
-- défaut, et l'ancre est GOMMÉE à 100 m avant d'être écrite — jamais le point
-- exact (c'est parfois chez quelqu'un). Un contenu localisé est visible de
-- tous ceux qui passent là : c'est ce que « localiser » veut dire.
-- ============================================================================

-- ─── 1. Les règles ──────────────────────────────────────────────────────────

create table if not exists public.feed_rules (
  id boolean primary key default true check (id),
  -- la fenêtre des croisements, PAR ORIGINE, reste dans `crossing_windows`
  freshness interval not null default interval '3 days',
  anchor_cell_m integer not null default 100,
  around_radius_m integer not null default 1000,
  grid_limit integer not null default 60,
  note text
);

insert into public.feed_rules (id, note)
values (true, 'Tranché par Jay le 2026-09-20 : contenu de moins de 3 jours, ancre gommée à 100 m, « autour de moi » à 1 km, ~60 par fil (seuil du scroll à détailler).')
on conflict (id) do nothing;

alter table public.feed_rules enable row level security;
drop policy if exists feed_rules_read on public.feed_rules;
create policy feed_rules_read on public.feed_rules for select to authenticated using (true);

-- ─── 2. L'ancre d'un contenu ────────────────────────────────────────────────

alter table public.contents
  add column if not exists anchor_lat double precision,
  add column if not exists anchor_lng double precision;

create index if not exists contents_anchor_idx
  on public.contents (anchor_lat, anchor_lng) where anchor_lat is not null;

-- Gomme un point sur la grille de `anchor_cell_m` : on ne retient que la case.
create or replace function private.gomme_ancre(p_lat double precision, p_lng double precision)
returns table (lat double precision, lng double precision)
language sql stable
set search_path to 'public', 'private'
as $$
  with r as (select anchor_cell_m::double precision as cell from public.feed_rules where id),
  s as (
    select cell / 111320.0 as step_lat from r
  ),
  a as (
    select round(p_lat / s.step_lat) * s.step_lat as lat, s.step_lat from s
  )
  select a.lat,
         round(p_lng / (a.step_lat / greatest(cos(radians(a.lat)), 0.01)))
           * (a.step_lat / greatest(cos(radians(a.lat)), 0.01))
  from a;
$$;

-- Distance approchée entre deux points, en mètres (assez pour 1 km).
create or replace function private.distance_m(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision
) returns double precision
language sql immutable
as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

-- ─── 3. Les ajouts au feed ──────────────────────────────────────────────────

create table if not exists public.feed_adds (
  id uuid primary key default gen_random_uuid(),
  content_id uuid not null references public.contents (id) on delete cascade,
  adder_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (content_id, recipient_id)
);
create index if not exists feed_adds_recipient_idx on public.feed_adds (recipient_id, created_at desc);

-- ⚠️ AUCUNE politique de lecture : l'identité de celui qui ajoute est un
-- secret jusqu'au like. Tout passe par les fonctions ci-dessous.
alter table public.feed_adds enable row level security;

-- Ajouter un contenu au feed de mes AMIS (au sens strict : connexion `full`).
create or replace function public.add_to_feed(p_content_id uuid, p_recipient_ids uuid[])
returns integer
language plpgsql security definer
set search_path to 'public', 'private'
as $$
declare
  v_me uuid := auth.uid();
  v_owner uuid;
  v_added integer;
begin
  if v_me is null then raise exception 'Authentification requise'; end if;

  select owner_id into v_owner from contents
  where id = p_content_id and context = 'publication' and revoked_at is null and shareable;
  if not found then raise exception 'Ce contenu n''est pas partageable'; end if;
  if not private.content_audience(p_content_id, v_me) then
    raise exception 'Contenu introuvable';
  end if;

  insert into feed_adds (content_id, adder_id, recipient_id)
  select p_content_id, v_me, r
  from unnest(p_recipient_ids) as r
  where r <> v_me
    and private.are_connected(v_me, r)
    and not private.is_blocked(v_me, r)
    and not private.is_blocked(v_owner, r)
  on conflict (content_id, recipient_id) do nothing;

  get diagnostics v_added = row_count;
  return v_added;
end;
$$;
revoke all on function public.add_to_feed(uuid, uuid[]) from public;
grant execute on function public.add_to_feed(uuid, uuid[]) to authenticated;

-- Ce contenu m'a-t-il été ajouté par quelqu'un que je n'ai pas bloqué depuis ?
create or replace function private.feed_added_to(p_content_id uuid, p_uid uuid)
returns boolean
language sql stable security definer
set search_path to 'public', 'private'
as $$
  select exists (
    select 1 from public.feed_adds a
    where a.content_id = p_content_id
      and a.recipient_id = p_uid
      and not private.is_blocked(a.adder_id, p_uid)
  );
$$;

-- Croisé dans la fenêtre de son origine (la même source que `crossed_recently`).
create or replace function private.crossed_within_window(a uuid, b uuid)
returns boolean
language sql stable security definer
set search_path to 'public', 'private'
as $$
  select exists (
    select 1 from public.ping_pairs pp
    where pp.user_low = least(a, b) and pp.user_high = greatest(a, b)
      and pp.last_seen_at > now() - private.fenetre_croisement('ping')
  ) or exists (
    select 1 from public.event_crossings c
    where c.user_low = least(a, b) and c.user_high = greatest(a, b)
      and c.last_at > now() - private.fenetre_croisement('event')
  );
$$;

-- ─── 4. Le seul juge : qui peut voir une publication ────────────────────────
--
-- Trois portes de plus, et rien d'autre ne change :
--   · public ET croisé dans la fenêtre ;
--   · public ET localisé (l'auteur l'a voulu visible de qui passe là) ;
--   · ajouté à mon feed par un ami.

create or replace function private.publication_audience(p_item_id uuid, p_uid uuid)
returns boolean
language sql stable security definer
set search_path to 'public', 'private'
as $$
  select exists (
    select 1 from library_items li
    where li.id = p_item_id
      and not private.is_revoked(li.id)
      and (
        li.owner_id = p_uid
        or (
          not private.is_blocked(li.owner_id, p_uid)
          and (
            can_view_library(li.owner_id, p_uid)
            or (li.is_public and can_view_profile(p_uid, li.owner_id))
            or (li.is_public and private.crossed_within_window(li.owner_id, p_uid))
            or (li.is_public and exists (
              select 1 from contents c where c.id = li.id and c.anchor_lat is not null
            ))
            or private.feed_added_to(li.id, p_uid)
            or exists (
              select 1 from content_grants g
              where g.content_id = li.id
                and g.grantee_id = p_uid
                and not private.is_blocked(g.granted_by, p_uid)
            )
          )
        )
      )
  );
$$;

-- ─── 5. L'ordre du fil ──────────────────────────────────────────────────────
--
-- Aujourd'hui : le plus récent d'abord. Demain : une pondération (distance,
-- fraîcheur, likes, qui l'a ajouté) — elle se branche ICI, et seulement ici.

create or replace function private.feed_rank(p_item_id uuid, p_created_at timestamptz)
returns double precision
language sql stable
as $$
  select extract(epoch from p_created_at);
$$;

-- ─── 6. Le feed ─────────────────────────────────────────────────────────────
--
-- Rend des lignes de `library_items` : le client embarque `contents(...)` et
-- `library_media(*)` comme pour un profil, et leurs politiques (le juge
-- ci-dessus) s'appliquent à ce qu'il embarque.
--
--   p_kind : null (tout), 'card' (Vibes), 'flow', 'album' (publications)
--   p_mode : 'all' | 'friends' | 'around'
--   p_lat / p_lng : où je suis (mode 'around' et, s'ils sont donnés, 'all')

create or replace function public.feed_items(
  p_kind public.library_kind default null,
  p_mode text default 'all',
  p_lat double precision default null,
  p_lng double precision default null
)
returns setof public.library_items
language plpgsql stable security definer
set search_path to 'public', 'private'
as $$
declare
  v_me uuid := auth.uid();
  v_rules public.feed_rules%rowtype;
  v_since timestamptz;
  v_dlat double precision;
  v_dlng double precision;
begin
  if v_me is null then raise exception 'Authentification requise'; end if;
  select * into v_rules from public.feed_rules where id;
  v_since := now() - v_rules.freshness;
  -- la boîte englobante du rayon (pré-filtre, la distance exacte trie après)
  v_dlat := v_rules.around_radius_m / 111320.0;
  v_dlng := v_rules.around_radius_m / (111320.0 * greatest(cos(radians(coalesce(p_lat, 0))), 0.01));

  return query
  with croises as (
    select case when pp.user_low = v_me then pp.user_high else pp.user_low end as autre
    from public.ping_pairs pp
    where (pp.user_low = v_me or pp.user_high = v_me)
      and pp.last_seen_at > now() - private.fenetre_croisement('ping')
    union
    select case when c.user_low = v_me then c.user_high else c.user_low end
    from public.event_crossings c
    where (c.user_low = v_me or c.user_high = v_me)
      and c.last_at > now() - private.fenetre_croisement('event')
  ),
  candidats as (
    -- 1. les croisés, contenu public
    select li.id
    from library_items li
    where p_mode = 'all'
      and li.is_public
      and li.owner_id <> v_me
      and li.owner_id in (select autre from croises)
      and li.created_at > v_since
    union
    -- 2. les ajouts de mes amis
    select a.content_id
    from public.feed_adds a
    join library_items li on li.id = a.content_id
    where p_mode in ('all', 'friends')
      and a.recipient_id = v_me
      and a.created_at > v_since
      and not private.is_blocked(a.adder_id, v_me)
    union
    -- 3. autour de moi : localisé, public, dans le rayon
    select li.id
    from library_items li
    join contents c on c.id = li.id
    where p_mode in ('all', 'around')
      and p_lat is not null and p_lng is not null
      and li.is_public
      and li.owner_id <> v_me
      and c.anchor_lat is not null
      and c.anchor_lat between p_lat - v_dlat and p_lat + v_dlat
      and c.anchor_lng between p_lng - v_dlng and p_lng + v_dlng
      and private.distance_m(p_lat, p_lng, c.anchor_lat, c.anchor_lng) <= v_rules.around_radius_m
      and li.created_at > v_since
  )
  select li.*
  from library_items li
  join candidats k on k.id = li.id
  where (p_kind is null or li.kind = p_kind)
    and not private.is_revoked(li.id)
    and not private.is_blocked(li.owner_id, v_me)
  order by private.feed_rank(li.id, li.created_at) desc
  limit 200;
end;
$$;
revoke all on function public.feed_items(public.library_kind, text, double precision, double precision) from public;
grant execute on function public.feed_items(public.library_kind, text, double precision, double precision) to authenticated;

-- Qui m'a ajouté ces contenus — révélé SEULEMENT pour ceux que j'ai likés.
create or replace function public.feed_adders(p_content_ids uuid[])
returns table (content_id uuid, adder_id uuid, display_name text)
language sql stable security definer
set search_path to 'public', 'private'
as $$
  select a.content_id, a.adder_id, p.display_name
  from public.feed_adds a
  join public.profiles p on p.id = a.adder_id
  where a.recipient_id = auth.uid()
    and a.content_id = any (p_content_ids)
    and exists (
      select 1 from public.content_likes l
      where l.content_id = a.content_id and l.user_id = auth.uid()
    );
$$;
revoke all on function public.feed_adders(uuid[]) from public;
grant execute on function public.feed_adders(uuid[]) to authenticated;

-- ─── 7. Publier avec une ancre ──────────────────────────────────────────────
--
-- La même fonction, deux paramètres de plus, gommés ICI avant l'écriture :
-- le point exact n'est jamais stocké, quoi que l'app envoie.

CREATE OR REPLACE FUNCTION public.publish_to_library(p_item_id uuid, p_kind library_kind, p_card_type card_type, p_media jsonb, p_caption text, p_is_public boolean, p_shareable boolean, p_saveable boolean, p_media_key text, p_aspect_w smallint DEFAULT NULL::smallint, p_aspect_h smallint DEFAULT NULL::smallint, p_caption_font text DEFAULT NULL::text, p_anchor_lat double precision DEFAULT NULL, p_anchor_lng double precision DEFAULT NULL)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_me uuid := auth.uid();
  v_count integer;
  v_slot integer := 0;
  v_m jsonb;
  v_path text;
  v_poster text;
  v_is_video boolean;
  v_duration integer;
  v_lat double precision;
  v_lng double precision;
begin
  if v_me is null then
    raise exception 'Authentification requise';
  end if;
  if p_media is null or jsonb_typeof(p_media) <> 'array' then
    raise exception 'MÃ©dias manquants';
  end if;
  v_count := jsonb_array_length(p_media);
  if p_kind = 'card' and v_count not between 1 and 2 then
    raise exception 'Une Card a une ou deux faces';
  end if;
  if p_kind = 'album' and v_count not between 1 and 20 then
    raise exception 'Une publication contient de 1 Ã  20 mÃ©dias';
  end if;
  -- Un Flow est une vidÃ©o publiÃ©e SEULE : c'est sa dÃ©finition, pas une
  -- prÃ©fÃ©rence d'affichage. Deux mÃ©dias, ou une photo, et ce n'est plus un
  -- Flow â€” c'est une publication ordinaire, qui a son propre kind.
  if p_kind = 'flow' and (
       v_count <> 1
       or not coalesce((p_media -> 0 ->> 'is_video')::boolean, false)
     ) then
    raise exception 'Un Flow est une vidÃ©o, et une seule';
  end if;

  -- L'ancre, GOMMÉE ici avant l'écriture : le point exact n'est jamais stocké,
  -- quoi que l'app envoie (feed « Pulse », 2026-09-20).
  if p_anchor_lat is not null and p_anchor_lng is not null then
    select g.lat, g.lng into v_lat, v_lng from private.gomme_ancre(p_anchor_lat, p_anchor_lng) g;
  end if;

  insert into contents (id, owner_id, context, shareable, saveable, anchor_lat, anchor_lng)
  values (p_item_id, v_me, 'publication', coalesce(p_shareable, false),
          coalesce(p_saveable, false), v_lat, v_lng);

  insert into library_items (id, owner_id, kind, card_type, caption, caption_font, is_public, aspect_w, aspect_h)
  values (
    p_item_id, v_me, p_kind, coalesce(p_card_type, 'standard'),
    nullif(p_caption, ''), nullif(p_caption_font, ''),
    coalesce(p_is_public, false),
    case when p_kind in ('album', 'flow') then p_aspect_w end,
    case when p_kind in ('album', 'flow') then p_aspect_h end
  );

  for v_m in select * from jsonb_array_elements(p_media) loop
    v_path := v_m ->> 'path';
    v_poster := v_m ->> 'poster_path';
    v_is_video := coalesce((v_m ->> 'is_video')::boolean, false);
    v_duration := (v_m ->> 'duration_ms')::integer;
    if v_path is null or (storage.foldername(v_path))[1] <> v_me::text then
      raise exception 'Chemin de mÃ©dia hors du dossier du propriÃ©taire';
    end if;
    if v_poster is not null and (storage.foldername(v_poster))[1] <> v_me::text then
      raise exception 'Chemin de couverture hors du dossier du propriÃ©taire';
    end if;
    -- Un Flow va jusqu'Ã  trois minutes (Jay, 2026-09-18) ; une vidÃ©o de
    -- publication reste Ã  une minute â€” deux formats, deux rÃ¨gles.
    if v_is_video and v_duration is not null
       and v_duration > (case when p_kind = 'flow' then 180000 else 60000 end) then
      raise exception 'Une vidÃ©o dure au plus % ',
        case when p_kind = 'flow' then 'trois minutes' else 'une minute' end;
    end if;
    insert into library_media (item_id, owner_id, slot, path, is_video, duration_ms, poster_path, width, height)
    values (
      p_item_id, v_me, v_slot, v_path, v_is_video,
      case when v_is_video then v_duration end,
      case when v_is_video then v_poster end,
      (v_m ->> 'width')::integer,
      (v_m ->> 'height')::integer
    );
    v_slot := v_slot + 1;
  end loop;

  insert into content_media_keys (content_id, media_key)
  values (p_item_id, p_media_key);

  return p_item_id;
end;
$function$;
