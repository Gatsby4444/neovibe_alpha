-- ===========================================================================
-- LE SCÉNARIO ÉVÉNEMENT DE BOUT EN BOUT — 2026-09-21
--
-- Décisions de Jay du 2026-09-21 (docs/raison-d-entrer-2026-09-21.md §5,
-- RAPPELS #155) : « je me balade dans la rue → je vois les soirées ouvertes
-- → je rejoins → participants, bibliothèque commune PENDANT la soirée → le
-- lendemain et les jours suivants → mes suggestions disent où j'ai croisé
-- les gens → et je les retrouve des mois plus tard ».
--
-- Ce que cette migration change, et ce qu'elle ne change pas :
--
--   1. Une TROISIÈME origine d'événement : `open` — créé par n'importe quel
--      utilisateur, visible de qui passe à portée, on y entre EN ÉTANT SUR
--      PLACE (la règle d'un établissement, sans établissement). Les deux
--      portes d'entrée au réseau ne bougent pas : on découvre une SOIRÉE,
--      jamais une personne.
--   2. La bibliothèque d'un événement est VISIBLE PENDANT (Jay, 2026-09-21 ;
--      elle était retardée à la fermeture + 10 h depuis le 2026-09-12).
--      `reveal_at = now()` au dépôt ; la fermeture ne la touche plus.
--   3. LA MÉMOIRE DES RENCONTRES (`meetings`) : un croisement reste un fait
--      qui EXPIRE (3 jours dans les suggestions, inchangé) ; la rencontre,
--      elle, se GARDE — 2 ans (Jay), effaçable par l'utilisateur. Une ligne
--      par personne, par rencontre (un événement, ou une première vue en
--      ping), avec où et quand. Symétrie intacte : une rencontre ne naît
--      QUE d'un croisement, qui exige que les deux se soient vus.
--   4. Le RÉCAP d'un événement (présents, Vibes, rencontrés, nouveaux amis).
--   5. LES MOMENTS (Jay : « peut-être essentiel ») : quand des amis sont
--      ensemble assez longtemps (vues mutuelles sur 2 créneaux de 15 min),
--      le serveur ouvre SEUL un événement privé `auto_created` avec sa
--      bibliothèque ; en rentrant, on y retrouve les Vibes du moment. Il vit
--      et se ferme par les règles existantes (80 % partis, 30 min sans
--      preuve, 5 jours de survie).
--   6. LES DÉFIS d'un événement (le premier « jeu ») : un présent pose un
--      défi en une phrase, les autres y répondent par une Vibe dans la
--      bibliothèque, marquée du défi.
--
-- Règle 2 de CLAUDE.md : `meetings` est une table à part de `ping_pairs` et
-- `event_crossings` — pas la même durée de vie, pas le même rangement.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. L'événement ouvert
-- ---------------------------------------------------------------------------

alter type public.event_kind add value if not exists 'open';

alter table public.events
  add column if not exists auto_created boolean not null default false;

comment on column public.events.auto_created is
  'Un MOMENT : ouvert par le serveur quand des amis sont ensemble (2026-09-21), jamais par un utilisateur. Vit et se ferme comme un événement privé.';

alter table public.event_rules
  add column if not exists moment_enabled boolean not null default true,
  add column if not exists moment_min_slots integer not null default 2,
  add column if not exists moment_min_friends integer not null default 2;

comment on column public.event_rules.moment_min_slots is
  'Créneaux de 15 min consécutifs avec vues MUTUELLES entre amis avant qu''un moment s''ouvre (2 = ~30 min). Jay, 2026-09-21.';

-- L'événement ouvert : l'organisateur n'est pas un établissement, c'est un
-- utilisateur. Il donne un nom, le lieu (là où il est), une heure de fin.
create or replace function public.create_open_event(
  p_title text,
  p_lat double precision,
  p_lon double precision,
  p_ends_at timestamptz,
  p_radius_m integer default null
) returns uuid
language plpgsql security definer
set search_path = public, private
as $$
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
  insert into public.event_presences (event_id, user_id, last_position_at)
  values (ev, me, now());
  insert into public.event_positions (event_id, user_id, lat, lon, acc, reported_at)
  values (ev, me, p_lat, p_lon, null, now())
  on conflict (event_id, user_id) do update
    set lat = excluded.lat, lon = excluded.lon, reported_at = now();

  return ev;
end;
$$;

revoke all on function public.create_open_event(text, double precision, double precision, timestamptz, integer) from public;
grant execute on function public.create_open_event(text, double precision, double precision, timestamptz, integer) to authenticated;

-- « Autour de moi » : les soirées d'établissement ET les événements ouverts.
-- Remplace `nearby_venue_events` (un seul appelant Dart, mis à jour).
drop function if exists public.nearby_venue_events(double precision, double precision);

create or replace function public.nearby_events(p_lat double precision, p_lon double precision)
returns table (
  id uuid, kind public.event_kind, title text, venue_name text, venue_address text,
  lat double precision, lon double precision, radius_m integer,
  starts_at timestamptz, scheduled_end_at timestamptz,
  present_count integer, distance_m integer
)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  r public.event_rules;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into r from public.event_rules;
  return query
  select e.id, e.kind, e.title, v.name, v.address, e.lat, e.lon, e.radius_m,
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
$$;

revoke all on function public.nearby_events(double precision, double precision) from public;
grant execute on function public.nearby_events(double precision, double precision) to authenticated;

-- Fermer : l'organisateur d'un événement ouvert peut, comme le gérant d'un
-- établissement. (`close_event` public vérifiait admin du groupe OU gérant du
-- lieu ; l'organisateur est admin du groupe — rien à changer.)

-- ---------------------------------------------------------------------------
-- 2. La bibliothèque visible PENDANT l'événement
-- ---------------------------------------------------------------------------

-- ⚠️ La signature change (p_challenge_id) : l'ancienne est SUPPRIMÉE, sinon
-- deux surcharges à défauts rendent tout appel ambigu (42725) — pour
-- PostgREST aussi.
drop function if exists public.add_vibe_to_library(uuid, uuid, text, text, text, public.card_type, boolean, boolean, boolean, boolean, text, text);

create or replace function public.add_vibe_to_library(
  p_id uuid, p_conversation_id uuid, p_placeholder_path text, p_sealed_path text,
  p_media_key text, p_card_type public.card_type default 'standard',
  p_front_is_video boolean default false, p_back_is_video boolean default false,
  p_saveable_by_others boolean default false, p_ephemeral boolean default false,
  p_placeholder_back_path text default null, p_sealed_back_path text default null,
  p_challenge_id uuid default null
) returns public.library_vibes
language plpgsql security definer
set search_path = public, private
as $$
declare
  v_timezone text;
  v_type public.conversation_type;
  v_reveal timestamptz;
  v_vibe public.library_vibes;
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

  select library_timezone, conversation_type into v_timezone, v_type
  from conversations where id = p_conversation_id;

  if v_type = 'event' then
    -- 2026-09-21 : visible tout de suite, pour les participants (Jay :
    -- « voir ce qui a été publié au cours de la soirée »). Le placeholder
    -- flouté ne sert plus qu'à l'affichage en attendant le scellé.
    v_reveal := now();
    if p_challenge_id is not null and not exists (
      select 1 from public.event_challenges c
      join public.events e on e.id = c.event_id
      where c.id = p_challenge_id and e.conversation_id = p_conversation_id
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
    challenge_id
  )
  values (
    p_id, p_conversation_id, auth.uid(),
    v_reveal,
    p_card_type, p_front_is_video, p_back_is_video,
    p_saveable_by_others, p_ephemeral,
    p_placeholder_path, p_sealed_path,
    p_placeholder_back_path, p_sealed_back_path,
    p_challenge_id
  )
  returning * into v_vibe;

  insert into library_vibe_keys (vibe_id, media_key) values (v_vibe.id, p_media_key);

  insert into messages (conversation_id, sender_id, kind, body)
  values (p_conversation_id, auth.uid(), 'library_add', null);

  return v_vibe;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. La mémoire des rencontres
-- ---------------------------------------------------------------------------

create table if not exists public.meetings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  other_id uuid not null references public.profiles(id) on delete cascade,
  -- `ping` (la rue, le bus) ou `event` (une soirée, un moment)
  origin text not null check (origin in ('ping', 'event')),
  event_id uuid,
  event_title text,
  -- Le lieu, GOMMÉ à 100 m comme une ancre de contenu — celui de l'événement
  -- (un ping n'en a pas : le ping ne sait pas où il est à ce grain).
  lat double precision,
  lon double precision,
  met_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

comment on table public.meetings is
  'LA MÉMOIRE DES RENCONTRES (Jay, 2026-09-21) : qui j''ai rencontré, où, quand — gardée 2 ans, effaçable par moi. Une ligne par personne et par rencontre. Ne naît que d''un croisement (symétrique).';

create unique index if not exists meetings_one_per_event
  on public.meetings (user_id, other_id, event_id) where event_id is not null;
create index if not exists meetings_by_user on public.meetings (user_id, last_at desc);

alter table public.meetings enable row level security;

drop policy if exists "meetings_own_read" on public.meetings;
create policy "meetings_own_read" on public.meetings
  for select to authenticated using (user_id = auth.uid());

-- Effacer une rencontre de SA mémoire : l'autre garde la sienne (deux
-- lignes, deux mémoires). Aucune écriture par le client.
drop policy if exists "meetings_own_delete" on public.meetings;
create policy "meetings_own_delete" on public.meetings
  for delete to authenticated using (user_id = auth.uid());

-- `crossing_windows.origin` était borné à ping / event : la mémoire est une
-- troisième origine, avec sa fenêtre.
alter table public.crossing_windows drop constraint if exists crossing_windows_origin_check;
alter table public.crossing_windows
  add constraint crossing_windows_origin_check check (origin in ('ping', 'event', 'meeting'));

insert into public.crossing_windows (origin, fenetre, decide_par, note)
values ('meeting', interval '2 years', 'Jay, 2026-09-21',
        'La mémoire des rencontres : 2 ans de conservation. Effaçable par l''utilisateur avant.')
on conflict (origin) do update set fenetre = excluded.fenetre, decide_par = excluded.decide_par, note = excluded.note;

-- Écrit les deux lignes d'une rencontre (une par personne), sans doublon
-- pour un même événement, et jamais entre bloqués.
create or replace function private.note_meeting(
  a uuid, b uuid, p_origin text, p_event uuid, p_title text,
  p_lat double precision, p_lon double precision, p_at timestamptz
) returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  g record;
begin
  if a = b or private.is_blocked(a, b) then return; end if;
  if p_lat is not null and p_lon is not null then
    select * into g from private.gomme_ancre(p_lat, p_lon);
  end if;
  if p_event is not null then
    insert into public.meetings (user_id, other_id, origin, event_id, event_title, lat, lon, met_at, last_at)
    values (a, b, p_origin, p_event, p_title, g.lat, g.lng, p_at, p_at),
           (b, a, p_origin, p_event, p_title, g.lat, g.lng, p_at, p_at)
    on conflict (user_id, other_id, event_id) where event_id is not null
      do update set last_at = greatest(meetings.last_at, excluded.last_at);
  else
    insert into public.meetings (user_id, other_id, origin, met_at, last_at)
    values (a, b, p_origin, p_at, p_at), (b, a, p_origin, p_at, p_at);
  end if;
end;
$$;

-- Un croisement de ping qui NAÎT (première vue mutuelle, ou revue après
-- l'expiration de la paire) est une rencontre.
create or replace function private.on_ping_pair_born()
returns trigger
language plpgsql security definer
set search_path = public, private
as $$
begin
  perform private.note_meeting(new.user_low, new.user_high, 'ping', null, null, null, null, new.first_seen_at);
  return new;
end;
$$;

drop trigger if exists ping_pairs_meeting on public.ping_pairs;
create trigger ping_pairs_meeting
  after insert on public.ping_pairs
  for each row execute function private.on_ping_pair_born();

-- Un croisement d'événement (écrit à la fermeture) est une rencontre, avec
-- le lieu de l'événement.
create or replace function private.on_event_crossing_born()
returns trigger
language plpgsql security definer
set search_path = public, private
as $$
declare
  e public.events;
begin
  select * into e from public.events where id = new.event_id;
  perform private.note_meeting(new.user_low, new.user_high, 'event', new.event_id,
                               coalesce(new.event_title, e.title), e.lat, e.lon, new.first_at);
  return new;
end;
$$;

drop trigger if exists event_crossings_meeting on public.event_crossings;
create trigger event_crossings_meeting
  after insert on public.event_crossings
  for each row execute function private.on_event_crossing_born();

-- Le balai : 2 ans, lu dans `crossing_windows`. Un job à lui (un job = une
-- transaction, jamais greffé sur un autre).
create or replace function public.purge_meetings()
returns integer
language plpgsql security definer
set search_path = public, private
as $$
declare n integer;
begin
  delete from public.meetings where last_at < now() - private.fenetre_croisement('meeting');
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.purge_meetings() from public;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'neovibe_purge_meetings') then
    perform cron.schedule('neovibe_purge_meetings', '23 4 * * *', 'select public.purge_meetings()');
  end if;
end $$;

-- Ma mémoire, la plus récente d'abord : qui, où, quand, et ce qu'on est
-- devenus (amis ou pas).
create or replace function public.my_meetings()
returns table (
  id uuid, user_id uuid, display_name text, tag_name text, avatar_url text,
  origin text, event_id uuid, event_title text,
  lat double precision, lon double precision,
  met_at timestamptz, last_at timestamptz,
  connected boolean, times integer
)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  return query
  select m.id, m.other_id, p.display_name, p.tag_name, p.avatar_url,
         m.origin, m.event_id, m.event_title, m.lat, m.lon,
         m.met_at, m.last_at,
         private.are_connected(me, m.other_id),
         (select count(*)::integer from public.meetings x where x.user_id = me and x.other_id = m.other_id)
  from public.meetings m
  join public.profiles p on p.id = m.other_id
  where m.user_id = me and not private.is_blocked(me, m.other_id)
  order by m.last_at desc;
end;
$$;

revoke all on function public.my_meetings() from public;
grant execute on function public.my_meetings() to authenticated;

-- « Vous vous êtes déjà rencontrés » : pour des personnes en face de moi
-- (le ping, les suggestions), la dernière rencontre que ma mémoire garde.
create or replace function public.met_before(p_users uuid[])
returns table (user_id uuid, origin text, event_title text, met_at timestamptz, times integer)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  return query
  select d.other_id, d.origin, d.event_title, d.met_at,
         (select count(*)::integer from public.meetings x where x.user_id = me and x.other_id = d.other_id)
  from (
    select distinct on (m.other_id) m.other_id, m.origin, m.event_title, m.met_at
    from public.meetings m
    where m.user_id = me and m.other_id = any(p_users)
    order by m.other_id, m.last_at desc
  ) d;
end;
$$;

revoke all on function public.met_before(uuid[]) from public;
grant execute on function public.met_before(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Les défis (le premier « jeu » du mode événement)
-- ---------------------------------------------------------------------------

create table if not exists public.event_challenges (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  text text not null check (char_length(btrim(text)) between 3 and 140),
  created_at timestamptz not null default now()
);

alter table public.library_vibes
  add column if not exists challenge_id uuid references public.event_challenges(id) on delete set null;

alter table public.event_challenges enable row level security;

drop policy if exists "event_challenges_read" on public.event_challenges;
create policy "event_challenges_read" on public.event_challenges
  for select to authenticated using (private.concerned_by_event(event_id, auth.uid()));

-- Poser un défi : il faut être SUR PLACE (présent), pas seulement invité.
create or replace function public.post_challenge(p_event uuid, p_text text)
returns uuid
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  e public.events;
  c uuid;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into e from public.events where id = p_event;
  if not found or e.closed_at is not null then raise exception 'Événement fermé'; end if;
  if not private.is_present_in_event(p_event, me) then raise exception 'Il faut être sur place'; end if;
  insert into public.event_challenges (event_id, author_id, text)
  values (p_event, me, btrim(p_text)) returning id into c;
  insert into public.messages (conversation_id, sender_id, kind, body)
  values (e.conversation_id, me, 'text', '🎯 Défi : ' || btrim(p_text));
  return c;
end;
$$;

revoke all on function public.post_challenge(uuid, text) from public;
grant execute on function public.post_challenge(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Le récap d'un événement
-- ---------------------------------------------------------------------------

create or replace function public.event_recap(p_event uuid)
returns table (
  present_count integer, vibe_count integer, met_count integer,
  new_friend_count integer, friends_present uuid[]
)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  e public.events;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into e from public.events where id = p_event;
  if not found or not private.concerned_by_event(p_event, me) then
    raise exception 'Événement introuvable';
  end if;
  return query
  select
    (select count(distinct p.user_id)::integer from public.event_presences p where p.event_id = p_event),
    (select count(*)::integer from public.library_vibes v where v.conversation_id = e.conversation_id),
    (select count(*)::integer from public.meetings m where m.user_id = me and m.event_id = p_event),
    (select count(*)::integer from public.connections c
      where c.status = 'full' and c.established_at >= e.starts_at
        and ((c.user_low = me and exists (select 1 from public.event_presences p where p.event_id = p_event and p.user_id = c.user_high))
          or (c.user_high = me and exists (select 1 from public.event_presences p where p.event_id = p_event and p.user_id = c.user_low)))),
    (select coalesce(array_agg(distinct p.user_id), '{}'::uuid[]) from public.event_presences p
      where p.event_id = p_event and p.user_id <> me and private.are_connected(me, p.user_id));
end;
$$;

revoke all on function public.event_recap(uuid) from public;
grant execute on function public.event_recap(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. La fermeture : plus de retard de bibliothèque ; les rencontres suivent
--    par déclencheur (on_event_crossing_born).
-- ---------------------------------------------------------------------------

create or replace function private.close_event(p_event uuid, p_reason text)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  e public.events;
  r public.event_rules;
begin
  select * into e from public.events where id = p_event for update;
  if not found or e.closed_at is not null then
    return;
  end if;
  select * into r from public.event_rules;

  -- 2026-09-21 : la bibliothèque est visible depuis le dépôt ; la fermeture
  -- ne la date plus. `library_reveal_at` ne sert plus qu'à dire « depuis ».
  update public.events
     set closed_at = now(),
         close_reason = p_reason,
         library_reveal_at = coalesce(library_reveal_at, opened_at, now())
   where id = p_event;

  -- Les croisements par PRÉSENCE : présents ensemble au moins
  -- `crossing_min_overlap`, toutes présences cumulées. Le déclencheur
  -- `event_crossings_meeting` en fait des rencontres.
  insert into public.event_crossings
    (event_id, event_title, user_low, user_high, first_at, last_at, source)
  select e.id, e.title, o.user_low, o.user_high, o.first_at, o.last_at, 'presence'
  from (
    select least(a.user_id, b.user_id) as user_low,
           greatest(a.user_id, b.user_id) as user_high,
           min(greatest(a.joined_at, b.joined_at)) as first_at,
           max(least(coalesce(a.left_at, now()), coalesce(b.left_at, now()))) as last_at,
           sum(least(coalesce(a.left_at, now()), coalesce(b.left_at, now()))
               - greatest(a.joined_at, b.joined_at)) as overlap
    from public.event_presences a
    join public.event_presences b
      on b.event_id = a.event_id and b.user_id > a.user_id
    where a.event_id = e.id
      and least(coalesce(a.left_at, now()), coalesce(b.left_at, now()))
          > greatest(a.joined_at, b.joined_at)
    group by 1, 2
  ) o
  where o.overlap >= r.crossing_min_overlap
    and not private.is_blocked(o.user_low, o.user_high)
  on conflict (event_id, user_low, user_high) do update
    set last_at = greatest(event_crossings.last_at, excluded.last_at);

  update public.event_presences
     set left_at = now(), left_reason = 'closed'
   where event_id = p_event and left_at is null;

  delete from public.event_positions where event_id = p_event;
end;
$$;

-- Les Vibes déjà déposées dans des événements ouverts (reveal « jamais »)
-- deviennent visibles : c'est la nouvelle règle.
update public.library_vibes v
   set reveal_at = least(v.reveal_at, now())
  from public.conversations c
 where c.id = v.conversation_id and c.conversation_type = 'event'
   and v.reveal_at > now();

-- ---------------------------------------------------------------------------
-- 7. Les moments : un événement privé ouvert par le serveur quand des amis
--    sont ensemble
-- ---------------------------------------------------------------------------

-- Deux amis sont « ensemble » quand ils se sont vus MUTUELLEMENT (sightings
-- dans les deux sens, à un créneau près) sur `moment_min_slots` créneaux
-- consécutifs récents. La preuve est celle des paliers d'amitié — rien de
-- nouveau n'est collecté.
create or replace function private.friends_together_now()
returns table (user_low uuid, user_high uuid)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  r public.event_rules;
  now_slot bigint := floor(extract(epoch from now()) / private.slot_seconds());
begin
  select * into r from public.event_rules;
  return query
  select m.lo, m.hi
  from (
    select least(a.observer_id, a.seen_id) as lo, greatest(a.observer_id, a.seen_id) as hi, a.slot
    from public.sightings a
    join public.sightings b
      on b.observer_id = a.seen_id and b.seen_id = a.observer_id
     and b.slot between a.slot - 1 and a.slot + 1
    where a.observer_id < a.seen_id
      and a.slot >= now_slot - r.moment_min_slots
  ) m
  group by m.lo, m.hi
  having count(distinct m.slot) >= r.moment_min_slots
     and max(m.slot) >= now_slot - 1
     -- Dit positivement : des AMIS. (`sightings` n'est écrit qu'entre amis,
     -- mais la règle ne repose pas sur ce que fait un autre code.)
     and private.are_connected(m.lo, m.hi);
end;
$$;

create or replace function private.form_moments()
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  r public.event_rules;
  pair record;
  ev uuid;
  conv uuid;
  a_ev uuid;
  b_ev uuid;
  who uuid;
  titre text;
begin
  select * into r from public.event_rules;
  if not r.moment_enabled then return; end if;

  for pair in select * from private.friends_together_now() loop
    -- Chacun est-il déjà dans un événement ouvert ?
    select p.event_id into a_ev from public.event_presences p
     where p.user_id = pair.user_low and p.left_at is null limit 1;
    select p.event_id into b_ev from public.event_presences p
     where p.user_id = pair.user_high and p.left_at is null limit 1;

    if a_ev is not null and b_ev is not null then
      -- Déjà ensemble quelque part : rien à ouvrir.
      continue;
    end if;

    ev := coalesce(a_ev, b_ev);
    if ev is not null then
      -- L'un est dans un événement : l'autre y entre seulement si c'est un
      -- MOMENT (un événement privé ou d'établissement garde ses règles
      -- d'entrée — on n'y invite personne à sa place).
      if not exists (select 1 from public.events e where e.id = ev and e.auto_created and e.closed_at is null) then
        continue;
      end if;
      who := case when a_ev is null then pair.user_low else pair.user_high end;
    else
      -- Personne nulle part : un moment s'ouvre pour les deux.
      titre := 'Moment du ' || to_char(now() at time zone 'Europe/Paris', 'DD/MM à HH24:MI');
      insert into public.conversations (conversation_type, title, created_by)
      values ('event', titre, pair.user_low) returning id into conv;
      insert into public.events
        (kind, title, created_by, conversation_id, starts_at, opened_at, auto_created)
      values ('private', titre, pair.user_low, conv, now(), now(), true)
      returning id into ev;
      perform private.add_to_moment(ev, pair.user_low);
      who := pair.user_high;
    end if;

    perform private.add_to_moment(ev, who);
  end loop;

  -- La preuve de présence d'un moment, c'est la vue mutuelle : on la
  -- rafraîchit pour les paires encore ensemble.
  update public.event_presences p
     set last_ping_at = now()
    from public.events e, private.friends_together_now() t
   where e.id = p.event_id and e.auto_created and e.closed_at is null and p.left_at is null
     and p.user_id in (t.user_low, t.user_high)
     and exists (select 1 from public.event_presences q
                  where q.event_id = p.event_id and q.left_at is null
                    and q.user_id = case when p.user_id = t.user_low then t.user_high else t.user_low end);
end;
$$;

-- Entrer dans un moment : membre du groupe (admin, comme un invité d'événement
-- privé), membre de la conversation, présent — sans position, la preuve est
-- le ping.
create or replace function private.add_to_moment(p_event uuid, p_user uuid)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  conv uuid;
begin
  select conversation_id into conv from public.events where id = p_event;
  insert into public.event_group_members (event_id, user_id, role, added_by)
  values (p_event, p_user, 'admin', p_user) on conflict do nothing;
  insert into public.conversation_members (conversation_id, user_id)
  values (conv, p_user) on conflict do nothing;
  -- Un seul événement à la fois.
  update public.event_presences set left_at = now(), left_reason = 'manual'
   where user_id = p_user and left_at is null and event_id <> p_event;
  if not exists (select 1 from public.event_presences where event_id = p_event and user_id = p_user and left_at is null) then
    insert into public.event_presences (event_id, user_id, last_ping_at)
    values (p_event, p_user, now());
  end if;
end;
$$;

create or replace function private.sweep_events()
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  r public.event_rules;
  e record;
  ever integer;
  still integer;
begin
  select * into r from public.event_rules;

  -- 0. Les moments : des amis ensemble → un événement s'ouvre seul (2026-09-21).
  perform private.form_moments();

  -- 1. Sans aucune preuve de présence depuis `away_after` : sorti.
  update public.event_presences p
     set left_at = now(), left_reason = 'away'
   where p.left_at is null
     and greatest(coalesce(p.last_position_at, p.joined_at),
                  coalesce(p.last_ping_at, p.joined_at)) < now() - r.away_after;
  delete from public.event_positions x
   where not exists (
     select 1 from public.event_presences p
     where p.event_id = x.event_id and p.user_id = x.user_id and p.left_at is null
   );

  -- 2. L'horaire de fermeture d'un établissement ou d'un événement ouvert.
  for e in select id from public.events
            where closed_at is null and kind in ('venue', 'open')
              and scheduled_end_at is not null and scheduled_end_at <= now()
  loop
    perform private.close_event(e.id, 'schedule');
  end loop;

  -- 3. Les 80 % d'un événement privé (et d'un moment), après le délai de grâce.
  for e in select id from public.events
            where closed_at is null and kind = 'private'
              and opened_at is not null and opened_at < now() - r.private_close_grace
  loop
    select count(distinct user_id) into ever from public.event_presences where event_id = e.id;
    select count(*) into still from public.event_presences where event_id = e.id and left_at is null;
    if ever > 0 and still <= (1 - r.private_close_ratio) * ever then
      perform private.close_event(e.id, 'deserted');
    end if;
  end loop;

  -- 4. La purge : `survival` après la fermeture, l'événement ET sa conversation
  --    (donc son chat et sa bibliothèque) disparaissent. Les croisements
  --    restent (event_id devient nul, le titre est copié) ; les rencontres
  --    (`meetings`) aussi, elles ont leur propre balai.
  for e in select id, conversation_id from public.events
            where closed_at is not null and closed_at < now() - r.survival
  loop
    delete from public.events where id = e.id;
    delete from public.conversations where id = e.conversation_id;
  end loop;
end;
$$;

-- `meetings.event_id` n'est PAS une clé étrangère : l'événement est purgé
-- après 5 jours, la rencontre reste avec son titre et son lieu copiés.
