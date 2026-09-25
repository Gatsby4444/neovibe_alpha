-- =============================================================================
-- QUI GÈRE UNE SOIRÉE — une règle, trois origines (revue du 2026-09-25)
-- =============================================================================
--
-- Revue « la règle vit au serveur » (Jay). Reproduit en base sous identité
-- (`scratchpad/failles_open.sql`), tout ACCEPTÉ avant ce correctif :
-- - un inconnu RENOMMAIT la soirée ouverte de quelqu'un d'autre ;
-- - un inconnu la FERMAIT ;
-- - n'importe quel compte créait un ÉTABLISSEMENT (n'importe où, soirée
--   ouverte à tous, sans limite de durée ni preuve d'y être).
--
-- Cause : l'événement ouvert (2026-09-21) est une troisième origine, et les
-- deux vérifications « qui gère ? » ne connaissaient que les deux premières
-- — un `if kind = …` par origine, et celle qui manquait laissait passer tout
-- le monde, en silence. La cause est supprimée : UNE fonction répond
-- « qui gère cet événement ? » pour toutes les origines, énoncée
-- positivement (une origine inconnue ne donne rien).
-- =============================================================================

create function private.may_manage_event(p_event uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.events e
    where e.id = p_event
      and case e.kind
        when 'venue' then private.manages_venue(e.venue_id, p_uid)
        when 'private' then e.created_by = p_uid
        when 'open' then e.created_by = p_uid
        else false
      end
  );
$$;
revoke all on function private.may_manage_event(uuid, uuid) from public, anon, authenticated;

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
                         when p_lat is not null then (select leave_radius_m from public.event_rules)
                         else radius_m end
   where id = p_event;
  if p_title is not null then
    update public.conversations set title = btrim(p_title) where id = e.conversation_id;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.close_event(p_event uuid)
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
  select * into e from public.events where id = p_event;
  if not found then raise exception 'Événement introuvable'; end if;
  -- 2026-09-25 : UNE règle pour les trois origines (l'événement ouvert
  -- n'y était pas : n'importe qui le fermait).
  if not private.may_manage_event(p_event, me) then
    raise exception 'Seul l''organisateur ferme l''événement';
  end if;
  perform private.close_event(p_event, 'host');
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_venue(p_name text, p_lat double precision, p_lon double precision, p_radius_m integer DEFAULT 60, p_address text DEFAULT NULL::text)
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
  values (btrim(p_name), p_address, p_lat, p_lon, coalesce(p_radius_m, 60), me)
  returning id into v;
  insert into public.venue_managers (venue_id, user_id) values (v, me);
  return v;
end;
$function$;

-- Une fonction de maintenance (le job `neovibe_purge_meetings` l'appelle en
-- tant que propriétaire) n'a pas à être appelable par un compte.
revoke all on function public.purge_meetings() from public, anon, authenticated;
