-- =============================================================================
-- LA TAILLE D'UNE SOIRÉE — entrer et sortir, deux règles — 2026-09-25
-- =============================================================================
--
-- Constaté par Jay (position exacte à 5 m près) : il pouvait rejoindre des
-- soirées « dans d'autres rues ». Relevé en base : une soirée ouverte prenait
-- pour rayon d'ENTRÉE `leave_radius_m` (300 m) — le rayon de SORTIE, choisi
-- large pour qu'un GPS d'intérieur n'éjecte personne — plus jusqu'à 100 m de
-- marge de précision : 400 m. Deux règles pour un même nombre : la plus
-- permissive gagnait partout (règle 2 de CLAUDE.md).
--
-- Décision de Jay : **trois tailles au choix**, pour toutes les origines
-- (ouverte, privée avec lieu, établissement) — Bar / appartement 50 m (par
-- défaut), Grand lieu 120 m, Plein air / festival 300 m. **Sortie à deux
-- fois le rayon.** Les nombres sont des lignes d'`event_rules`, pas des
-- constantes :
--
-- | Règle | Valeur |
-- |---|---|
-- | entrer | à ≤ rayon + min(précision, `entry_margin_max_m` = 30 m) du point |
-- | sortir | à > `exit_factor` (2) × rayon + min(précision, 100 m) du cœur (point ou présents) |
-- | taille | posée par l'organisateur (`set_event_size`), une des trois, jamais une autre |
--
-- Sans lieu fixe (soirée privée « chez nous », moment entre amis), rien ne
-- change : pas de rayon, les présents font le lieu, `leave_radius_m`.
-- =============================================================================

alter table public.event_rules
  add column size_bar_m integer not null default 50,
  add column size_grand_m integer not null default 120,
  add column size_plein_air_m integer not null default 300,
  add column exit_factor numeric not null default 2,
  add column entry_margin_max_m integer not null default 30;

-- Le rayon d'une taille. Un rayon demandé qui n'est PAS l'une des trois
-- tailles est refusé ; rien demandé = Bar.
create function private.event_size_radius(p_radius_m integer)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.event_rules;
begin
  select * into r from public.event_rules limit 1;
  if p_radius_m is null then return r.size_bar_m; end if;
  if p_radius_m not in (r.size_bar_m, r.size_grand_m, r.size_plein_air_m) then
    raise exception 'Taille de soirée inconnue (% m)', p_radius_m;
  end if;
  return p_radius_m;
end;
$$;
revoke all on function private.event_size_radius(integer) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.join_event(p_event uuid, p_lat double precision, p_lon double precision, p_acc double precision DEFAULT NULL::double precision)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
  e public.events;
  r public.event_rules;
  presence uuid;
  d double precision;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into e from public.events where id = p_event for update;
  if not found or e.closed_at is not null then raise exception 'Événement fermé'; end if;
  if e.starts_at > now() then raise exception 'L''événement n''a pas commencé'; end if;
  select * into r from public.event_rules;

  -- 🔴 LA RÈGLE D'ENTRÉE, par origine — deux chemins, jamais fusionnés.
  if e.kind = 'private' then
    if not private.is_event_member(p_event, me) then
      raise exception 'Tu n''es pas invité';
    end if;
  end if;

  -- 🔴 LA LOCALISATION : on rejoint EN ÉTANT SUR PLACE.
  if p_lat is null or p_lon is null then raise exception 'Position requise'; end if;
  if e.lat is not null then
    d := private.meters_between(p_lat, p_lon, e.lat, e.lon);
    -- ENTRER : dans le rayon de la soirée, marge de précision plafonnée
    -- (`entry_margin_max_m`, 30 m) — 2026-09-25 : 300 m + 100 m laissaient
    -- entrer à plusieurs rues de là (constaté par Jay).
    if d > coalesce(e.radius_m, r.size_bar_m) + coalesce(least(p_acc, r.entry_margin_max_m), 0) then
      raise exception 'Trop loin : % m', round(d);
    end if;
  elsif private.far_from_event(p_event, me, p_lat, p_lon, p_acc) then
    raise exception 'Trop loin des participants';
  end if;

  -- Un seul événement à la fois : on sort du précédent.
  update public.event_presences
     set left_at = now(), left_reason = 'manual'
   where user_id = me and left_at is null and event_id <> p_event;
  delete from public.event_positions where user_id = me and event_id <> p_event;

  -- Déjà présent ici : on rafraîchit seulement.
  select id into presence from public.event_presences
   where event_id = p_event and user_id = me and left_at is null;
  if presence is null then
    insert into public.event_presences (event_id, user_id, last_position_at)
    values (p_event, me, now()) returning id into presence;
  else
    update public.event_presences set last_position_at = now() where id = presence;
  end if;

  insert into public.event_positions (event_id, user_id, lat, lon, acc, reported_at)
  values (p_event, me, p_lat, p_lon, p_acc, now())
  on conflict (event_id, user_id) do update
    set lat = excluded.lat, lon = excluded.lon, acc = excluded.acc, reported_at = now();

  update public.events set opened_at = coalesce(opened_at, now()) where id = p_event;

  -- Le groupe d'un établissement, c'est ceux qui sont venus.
  insert into public.conversation_members (conversation_id, user_id)
  values (e.conversation_id, me) on conflict do nothing;

  return presence;
end;
$function$;

CREATE OR REPLACE FUNCTION private.far_from_event(p_event uuid, p_uid uuid, p_lat double precision, p_lon double precision, p_acc double precision)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  r public.event_rules;
  spots integer := 0;
  nearest double precision;
begin
  select * into r from public.event_rules;
  select count(*), min(d) into spots, nearest
  from (
    select private.meters_between(p_lat, p_lon, x.lat, x.lon) as d
    from public.event_positions x
    join public.event_presences pr
      on pr.event_id = x.event_id and pr.user_id = x.user_id and pr.left_at is null
    where x.event_id = p_event and x.user_id <> p_uid
      and x.reported_at > now() - r.away_after
    union all
    select private.meters_between(p_lat, p_lon, e.lat, e.lon)
    from public.events e
    where e.id = p_event and e.lat is not null
  ) s;
  if spots = 0 then return false; end if;
  -- SORTIR : au-delà de `exit_factor` fois le rayon de la soirée (2026-09-25)
  -- — plus loin que l'entrée, pour qu'un GPS qui hésite n'éjecte personne.
  -- Sans lieu fixe (rayon nul), la règle d'avant : `leave_radius_m`.
  return nearest > coalesce(
      (select e.radius_m * r.exit_factor from public.events e where e.id = p_event),
      r.leave_radius_m
    ) + coalesce(least(p_acc, 100), 0);
end;
$function$;

CREATE OR REPLACE FUNCTION private.unguarded_create_open_event(p_title text, p_lat double precision, p_lon double precision, p_ends_at timestamp with time zone, p_radius_m integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
  r public.event_rules;
  conv uuid;
  ev uuid;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'Un événement a un nom';
  end if;
  if p_lat is null or p_lon is null then
    raise exception 'Un événement ouvert a un lieu : là où tu es';
  end if;
  if p_ends_at is null or p_ends_at <= now() then
    raise exception 'Un événement ouvert a une heure de fin';
  end if;
  if p_ends_at > now() + interval '24 hours' then
    raise exception 'Un événement ouvert dure au plus 24 h';
  end if;
  select * into r from public.event_rules;

  insert into public.conversations (conversation_type, title, created_by)
  values ('event', btrim(p_title), me)
  returning id into conv;

  insert into public.events
    (kind, title, created_by, conversation_id, lat, lon, radius_m,
     starts_at, scheduled_end_at, opened_at)
  values
    ('open', btrim(p_title), me, conv, p_lat, p_lon,
     private.event_size_radius(p_radius_m), now(), p_ends_at, now())
  returning id into ev;

  -- L'organisateur est du groupe (il règle et ferme), et présent : il l'a
  -- ouvert là où il est.
  insert into public.event_group_members (event_id, user_id, role, added_by)
  values (ev, me, 'admin', me);
  insert into public.conversation_members (conversation_id, user_id)
  values (conv, me);
  -- 2026-09-25 : un seul événement à la fois — comme `join_event`, ouvrir
  -- une soirée fait sortir de celle où l'on était. Sans ça, la contrainte
  -- `event_presences_one_open` levait une erreur brute (« duplicate key »)
  -- à quiconque ouvrait sa soirée depuis une autre.
  update public.event_presences
     set left_at = now(), left_reason = 'manual'
   where user_id = me and left_at is null;
  delete from public.event_positions where user_id = me;

  insert into public.event_presences (event_id, user_id, last_position_at)
  values (ev, me, now());
  insert into public.event_positions (event_id, user_id, lat, lon, acc, reported_at)
  values (ev, me, p_lat, p_lon, null, now())
  on conflict (event_id, user_id) do update
    set lat = excluded.lat, lon = excluded.lon, reported_at = now();

  return ev;
end;
$function$;

CREATE OR REPLACE FUNCTION private.unguarded_create_private_event(p_title text, p_starts_at timestamp with time zone DEFAULT now(), p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_lat double precision DEFAULT NULL::double precision, p_lon double precision DEFAULT NULL::double precision, p_member_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
  conv uuid;
  ev uuid;
  m uuid;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'Un événement a un nom';
  end if;

  insert into public.conversations (conversation_type, title, created_by)
  values ('event', btrim(p_title), me)
  returning id into conv;

  insert into public.events
    (kind, title, created_by, conversation_id, lat, lon, radius_m, starts_at, scheduled_end_at)
  values
    ('private', btrim(p_title), me, conv, p_lat, p_lon,
     case when p_lat is null then null else (select size_bar_m from public.event_rules) end,
     coalesce(p_starts_at, now()), p_ends_at)
  returning id into ev;

  insert into public.event_group_members (event_id, user_id, role, added_by)
  values (ev, me, 'admin', me);
  insert into public.conversation_members (conversation_id, user_id)
  values (conv, me);

  foreach m in array coalesce(p_member_ids, '{}') loop
    if m <> me and private.are_connected(me, m) and not private.is_blocked(me, m) then
      insert into public.event_group_members (event_id, user_id, role, added_by)
      values (ev, m, 'admin', me) on conflict do nothing;
      insert into public.conversation_members (conversation_id, user_id)
      values (conv, m) on conflict do nothing;
    end if;
  end loop;

  return ev;
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_event_settings(p_event uuid, p_title text DEFAULT NULL::text, p_members_can_add boolean DEFAULT NULL::boolean, p_members_can_remove boolean DEFAULT NULL::boolean, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_lat double precision DEFAULT NULL::double precision, p_lon double precision DEFAULT NULL::double precision, p_clear_place boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
  e public.events;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into e from public.events where id = p_event for update;
  if not found or e.closed_at is not null then raise exception 'Événement introuvable'; end if;
  -- 2026-09-25 : UNE règle pour les trois origines (l'événement ouvert
  -- n'y était pas : n'importe qui le réglait).
  if not private.may_manage_event(p_event, me) then
    raise exception 'Seul l''organisateur règle l''événement';
  end if;
  update public.events
     set title = coalesce(nullif(btrim(p_title), ''), title),
         members_can_add = coalesce(p_members_can_add, members_can_add),
         members_can_remove = coalesce(p_members_can_remove, members_can_remove),
         scheduled_end_at = coalesce(p_ends_at, scheduled_end_at),
         lat = case when p_clear_place then null else coalesce(p_lat, lat) end,
         lon = case when p_clear_place then null else coalesce(p_lon, lon) end,
         radius_m = case when p_clear_place then null
                         when p_lat is not null then coalesce(radius_m, (select size_bar_m from public.event_rules))
                         else radius_m end
   where id = p_event;
  if p_title is not null then
    update public.conversations set title = btrim(p_title) where id = e.conversation_id;
  end if;
end;
$function$;

drop function public.create_venue(text, double precision, double precision, integer, text);
CREATE FUNCTION public.create_venue(p_name text, p_lat double precision, p_lon double precision, p_radius_m integer DEFAULT NULL::integer, p_address text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
  v uuid;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  -- 2026-09-25 : un établissement est déclaré par la plateforme des
  -- commerçants (non construite, docs/plateforme-etablissements.md), pas par
  -- n'importe quel compte — sinon chacun posait un « club » n'importe où,
  -- ouvert à tous, sans limite de durée. En attendant : l'administration.
  if not private.is_admin(me) then
    raise exception 'Réservé à la plateforme des établissements';
  end if;
  insert into public.venues (name, address, lat, lon, radius_m, created_by)
  values (btrim(p_name), p_address, p_lat, p_lon, private.event_size_radius(p_radius_m), me)
  returning id into v;
  insert into public.venue_managers (venue_id, user_id) values (v, me);
  return v;
end;
$function$;
revoke all on function public.create_venue(text, double precision, double precision, integer, text) from public, anon;
grant execute on function public.create_venue(text, double precision, double precision, integer, text) to authenticated;

-- ─── L'organisateur change la taille ────────────────────────────────────────

create function public.set_event_size(p_event uuid, p_size text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.event_rules;
  v_radius integer;
begin
  perform private.assert_not_suspended();
  if not private.may_manage_event_open(p_event, auth.uid()) then
    raise exception 'Seul l''organisateur règle la soirée, et pendant qu''elle a lieu';
  end if;
  select * into r from public.event_rules limit 1;
  v_radius := case p_size
    when 'bar' then r.size_bar_m
    when 'grand' then r.size_grand_m
    when 'plein_air' then r.size_plein_air_m
  end;
  if v_radius is null then raise exception 'Taille inconnue : %', p_size; end if;
  update public.events set radius_m = v_radius
   where id = p_event and lat is not null;
  if not found then raise exception 'Une soirée sans lieu fixe n''a pas de taille'; end if;
  return v_radius;
end;
$$;
revoke all on function public.set_event_size(uuid, text) from public, anon;
grant execute on function public.set_event_size(uuid, text) to authenticated;

-- ─── Les soirées en cours prennent la taille par défaut ─────────────────────
-- (le rayon d'avant, 300 m, n'était pas un choix : c'était le rayon de
-- sortie réutilisé). Les soirées d'établissement gardent le rayon de leur lieu.
update public.events e
   set radius_m = (select size_bar_m from public.event_rules limit 1)
 where e.closed_at is null and e.lat is not null and e.kind in ('open', 'private');
