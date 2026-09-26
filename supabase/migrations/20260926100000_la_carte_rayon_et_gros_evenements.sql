-- ═══════════════════════════════════════════════════════════════════════════
-- LA CARTE : LE RAYON RÉGLABLE, ET LES GROS ÉVÉNEMENTS DE LOIN — 2026-09-26
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Jay, 2026-09-26 : *« augmenter soi-même la limite sur laquelle on voit des
-- events autour de nous (jusqu'à 50 km) »* et *« voir les gros événements qui
-- rassemblent beaucoup de monde de loin »* — *« des paramètres réglables
-- depuis le futur centre de contrôle »*.
--
-- ## Une seule porte, et la règle au serveur
--
-- `nearby_events` gagne deux paramètres FACULTATIFS : le rayon voulu, et un
-- minimum de présents. Le serveur BORNE le rayon selon ce qu'on demande :
--
--   - une liste ordinaire (minimum de présents sous le seuil « gros ») :
--     entre `nearby_radius_m` (2 km) et `nearby_radius_max_m` (50 km) ;
--   - les gros événements (minimum ≥ `big_event_min_present`) : jusqu'à
--     `big_event_radius_m`.
--
-- Demander 500 km sans filtre rend 50 km ; demander les gros événements
-- avec un minimum trop bas rend… la liste ordinaire. Aucun appel ne peut
-- élargir la vue au-delà de ce que la règle permet — l'écran ne fait que
-- l'annoncer (règle « la règle vit au serveur »).
--
-- Les seuils sont des LIGNES de `event_rules` : le centre de contrôle les
-- réglera sans nouvelle version de l'app.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.event_rules
  add column nearby_radius_max_m integer not null default 50000,
  add column big_event_min_present integer not null default 30,
  add column big_event_radius_m integer not null default 150000;

alter table public.event_rules
  add constraint event_rules_rayon_max check (nearby_radius_max_m >= nearby_radius_m),
  add constraint event_rules_gros_present check (big_event_min_present >= 2),
  add constraint event_rules_gros_rayon check (big_event_radius_m >= nearby_radius_max_m);

drop function public.nearby_events(double precision, double precision);

create function public.nearby_events(
  p_lat double precision,
  p_lon double precision,
  p_radius_m integer default null,
  p_min_present integer default 0
)
returns table(
  id uuid, kind event_kind, title text, venue_name text, venue_address text,
  lat double precision, lon double precision, radius_m integer,
  starts_at timestamp with time zone, scheduled_end_at timestamp with time zone,
  present_count integer, distance_m integer, description text, poster_path text,
  friends_present uuid[]
)
language plpgsql
stable security definer
set search_path to 'public', 'private'
as $function$
declare
  me uuid := auth.uid();
  r public.event_rules;
  v_gros boolean;
  v_rayon integer;
  v_min integer;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into r from public.event_rules;
  v_min := greatest(coalesce(p_min_present, 0), 0);
  v_gros := v_min >= r.big_event_min_present;
  -- Le rayon, BORNÉ par la règle : jamais sous le rayon par défaut, jamais
  -- au-delà du maximum de ce qui est demandé.
  v_rayon := least(
    greatest(coalesce(p_radius_m, r.nearby_radius_m), r.nearby_radius_m),
    case when v_gros then r.big_event_radius_m else r.nearby_radius_max_m end
  );
  return query
  select * from (
    select e.id, e.kind, e.title, coalesce(e.place_name, v.name), v.address, e.lat, e.lon, e.radius_m,
           e.starts_at, e.scheduled_end_at,
           -- « N personnes connectées ici » (Jay, 2026-09-21) : les présents,
           -- c'est-à-dire ceux dont la présence est prouvée en ce moment.
           (select count(*)::integer from public.event_presences p
             where p.event_id = e.id and p.left_at is null) as presents,
           round(private.meters_between(p_lat, p_lon, e.lat, e.lon))::integer as distance,
           e.description, e.poster_path, private.friends_present(e.id, me)
    from public.events e
    left join public.venues v on v.id = e.venue_id
    where e.kind in ('venue', 'open') and e.closed_at is null and e.starts_at <= now()
      and e.lat is not null
      and private.meters_between(p_lat, p_lon, e.lat, e.lon) <= v_rayon
      and not private.is_blocked(me, e.created_by)
  ) t
  where t.presents >= v_min
  order by t.distance;
end;
$function$;

revoke all on function public.nearby_events(double precision, double precision, integer, integer) from public, anon;
grant execute on function public.nearby_events(double precision, double precision, integer, integer) to authenticated;
