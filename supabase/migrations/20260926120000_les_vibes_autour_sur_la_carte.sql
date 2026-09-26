-- ═══════════════════════════════════════════════════════════════════════════
-- LES VIBES PUBLIQUES AUTOUR DE MOI, SUR LA CARTE — 2026-09-26
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Jay, 2026-09-26 : *« voir les Vibes publiques les plus populaires et les
-- dernières prises autour de moi sur la carte, dans les 3 km (réglage de la
-- carte, désactivable) »*.
--
-- ## Une seule règle « visible autour de moi »
--
-- Le fil Pulse avait SA copie de la règle (source 3 de `feed_items`) : une
-- Vibe publique, SITUÉE par son auteur (jamais par défaut, ancre gommée à
-- 100 m), récente, non retirée, d'un auteur que je n'ai pas bloqué. La carte
-- en aurait eu une seconde — deux copies, une correction sur deux. La règle
-- devient `private.vibes_autour`, et Pulse comme la carte la lisent.
--
-- ## Deux appels, la même règle
--
--   - `map_vibes_around(lat, lng)` : OÙ sont les Vibes (les plus aimées et
--     les plus récentes, dans `map_rules.vibes_radius_m`), avec leurs
--     « j'aime » ;
--   - `map_vibe_items(ids)` : les Vibes elles-mêmes, pour le lecteur —
--     refiltrées par la même règle (on ne charge que ce qu'on a le droit de
--     voir, quels que soient les identifiants demandés).
--
-- Rayon et nombres dans `map_rules` : réglables au centre de contrôle.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.map_rules
  add column vibes_radius_m integer not null default 3000,
  add column vibes_popular_count integer not null default 10,
  add column vibes_recent_count integer not null default 20;

-- ─── La règle, une fois ───────────────────────────────────────────────────
create function private.vibes_autour(
  p_me uuid, p_lat double precision, p_lng double precision,
  p_radius_m integer, p_since timestamptz
)
returns table (id uuid, owner_id uuid, kind library_kind,
               lat double precision, lng double precision,
               created_at timestamptz)
language plpgsql
stable security definer
set search_path = 'public', 'private'
as $$
declare
  v_dlat double precision;
  v_dlng double precision;
begin
  if p_lat is null or p_lng is null then return; end if;
  -- la boîte englobante du rayon (pré-filtre, la distance exacte après)
  v_dlat := p_radius_m / 111320.0;
  v_dlng := p_radius_m / (111320.0 * greatest(cos(radians(p_lat)), 0.01));
  return query
  select li.id, li.owner_id, li.kind, c.anchor_lat, c.anchor_lng, li.created_at
  from public.library_items li
  join public.contents c on c.id = li.id
  where li.is_public
    and c.anchor_lat is not null
    and c.anchor_lat between p_lat - v_dlat and p_lat + v_dlat
    and c.anchor_lng between p_lng - v_dlng and p_lng + v_dlng
    and private.distance_m(p_lat, p_lng, c.anchor_lat, c.anchor_lng) <= p_radius_m
    and li.created_at > p_since
    and not private.is_revoked(li.id)
    and not private.is_blocked(li.owner_id, p_me);
end;
$$;

-- ─── Pulse lit la règle (source 3), au lieu de sa copie ───────────────────
CREATE OR REPLACE FUNCTION public.feed_items(p_kind library_kind DEFAULT NULL::library_kind, p_mode text DEFAULT 'all'::text, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision)
 RETURNS SETOF library_items
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_me uuid := auth.uid();
  v_rules public.feed_rules%rowtype;
  v_since timestamptz;
begin
  if v_me is null then raise exception 'Authentification requise'; end if;
  select * into v_rules from public.feed_rules where id;
  v_since := now() - v_rules.freshness;

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
    -- 3. autour de moi : LA règle partagée avec la carte (2026-09-26)
    select v.id
    from private.vibes_autour(v_me, p_lat, p_lng, v_rules.around_radius_m, v_since) v
    where p_mode in ('all', 'around')
      and v.owner_id <> v_me
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
$function$;

-- ─── La carte : où sont les Vibes ─────────────────────────────────────────
create function public.map_vibes_around(p_lat double precision, p_lng double precision)
returns table (id uuid, lat double precision, lng double precision,
               likes integer, populaire boolean, created_at timestamptz)
language plpgsql
stable security definer
set search_path = 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  r public.map_rules;
  f public.feed_rules;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into r from public.map_rules;
  select * into f from public.feed_rules where feed_rules.id;
  return query
  with v as (
    select a.id, a.lat, a.lng, a.created_at,
           (select count(*)::integer from public.content_likes l
             where l.content_id = a.id) as likes
    from private.vibes_autour(me, p_lat, p_lng, r.vibes_radius_m,
                              now() - f.freshness) a
    where a.kind = 'card'
  ),
  pop as (
    select v.id from v where v.likes > 0
    order by v.likes desc, v.created_at desc
    limit r.vibes_popular_count
  ),
  rec as (
    select v.id from v order by v.created_at desc limit r.vibes_recent_count
  )
  select v.id, v.lat, v.lng, v.likes, v.id in (select pop.id from pop), v.created_at
  from v
  where v.id in (select pop.id from pop union select rec.id from rec);
end;
$$;
revoke all on function public.map_vibes_around(double precision, double precision) from public, anon;
grant execute on function public.map_vibes_around(double precision, double precision) to authenticated;

-- ─── La carte : les Vibes elles-mêmes, refiltrées par la même règle ───────
create function public.map_vibe_items(
  p_ids uuid[], p_lat double precision, p_lng double precision
)
returns setof public.library_items
language plpgsql
stable security definer
set search_path = 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  r public.map_rules;
  f public.feed_rules;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into r from public.map_rules;
  select * into f from public.feed_rules where feed_rules.id;
  return query
  select li.*
  from public.library_items li
  join private.vibes_autour(me, p_lat, p_lng, r.vibes_radius_m,
                            now() - f.freshness) a on a.id = li.id
  where li.id = any(p_ids) and li.kind = 'card'
  order by li.created_at desc;
end;
$$;
revoke all on function public.map_vibe_items(uuid[], double precision, double precision) from public, anon;
grant execute on function public.map_vibe_items(uuid[], double precision, double precision) to authenticated;
