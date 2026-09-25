-- =============================================================================
-- OUVRIR UNE SOIRÉE DEPUIS UNE AUTRE — 2026-09-25
-- =============================================================================
--
-- Constaté en créant des soirées de test : un compte déjà présent dans une
-- soirée qui en OUVRE une autre recevait une erreur brute
-- (`event_presences_one_open`, « duplicate key »). `join_event` sortait déjà
-- de la soirée précédente ; `create_open_event` non. Même règle, même geste :
-- un seul événement à la fois, et entrer ailleurs fait sortir d'ici.
-- =============================================================================

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
     coalesce(p_radius_m, r.leave_radius_m), now(), p_ends_at, now())
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
