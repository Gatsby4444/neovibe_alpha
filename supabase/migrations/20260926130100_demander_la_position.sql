-- ═══════════════════════════════════════════════════════════════════════════
-- DEMANDER SA POSITION À UN AMI ; REJOINDRE UN AMI — 2026-09-26
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Jay, 2026-09-26 : *« demander la position actuelle (envoie une
-- notification et une demande dans le chat) : il doit accepter pour
-- révéler »* ; *« rejoindre cet ami : le trajet à pied le plus court — on le
-- code pour tester, mais bloqué au premier lancement »*.
--
-- ## Une demande, c'est deux choses
--
--   - `location_requests` : le FAIT (qui demande à qui, quand, la réponse) ;
--   - un message `location_request` dans leur conversation, qui porte
--     l'identifiant de la demande. Le déclencheur du chat n'accepte ce type
--     de message QUE s'il correspond à une vraie demande de son auteur :
--     personne ne fabrique une fausse demande en écrivant dans le chat.
--
-- ## Accepter RÉVÈLE, une fois
--
-- `location_reveals` : la position donnée en réponse, visible par le SEUL
-- demandeur, pour une durée (`map_rules.location_reveal_for`) — même si
-- l'ami ne partage pas sa position d'ordinaire. C'est un geste, pas un
-- réglage.
--
-- ## Rejoindre : un interrupteur au serveur
--
-- `map_rules.walking_route_enabled` : vrai pour tester, À ÉTEINDRE avant le
-- premier lancement public (décision de Jay, RAPPELS). L'app le lit et
-- cache le bouton.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.map_rules
  add column location_request_ttl interval not null default interval '15 minutes',
  add column location_request_gap interval not null default interval '2 minutes',
  add column location_reveal_for interval not null default interval '1 hour',
  add column walking_route_enabled boolean not null default true;

-- ─── Les demandes ─────────────────────────────────────────────────────────
create table public.location_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  target_id uuid not null references public.profiles(id) on delete cascade,
  message_id uuid not null unique,
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  accepted boolean
);
create index location_requests_pair on public.location_requests (requester_id, target_id, created_at desc);
alter table public.location_requests enable row level security;
create policy location_requests_parties on public.location_requests
  for select to authenticated
  using (auth.uid() in (requester_id, target_id));

-- ─── Les positions révélées en réponse ────────────────────────────────────
create table public.location_reveals (
  requester_id uuid not null references public.profiles(id) on delete cascade,
  target_id uuid not null references public.profiles(id) on delete cascade,
  lat double precision not null,
  lon double precision not null,
  acc real,
  at timestamptz not null default now(),
  expires_at timestamptz not null,
  primary key (requester_id, target_id)
);
alter table public.location_reveals enable row level security;
create policy location_reveals_parties on public.location_reveals
  for select to authenticated
  using (auth.uid() in (requester_id, target_id));

-- ─── Le chat n'accepte une demande que si elle existe ─────────────────────
CREATE OR REPLACE FUNCTION public.enforce_message_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ctype public.conversation_type;
  other_replied boolean;
  my_count integer;
begin
  -- 2026-09-25 : membre, compte actif, et conversation ouverte à l'écriture
  -- — quel que soit le chemin (insertion directe ou fonction du serveur).
  if not private.is_conversation_member(new.conversation_id, new.sender_id) then
    raise exception 'Conversation introuvable';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = new.sender_id and p.suspended_at is not null
  ) then
    raise exception 'Ton compte est suspendu';
  end if;
  if not private.can_write_in_conversation(new.conversation_id, new.sender_id) then
    if exists (
      select 1 from public.events e
      where e.conversation_id = new.conversation_id and e.closed_at is not null
    ) then
      raise exception 'Cette soirée est terminée : son chat est fermé';
    end if;
    raise exception 'Tu ne peux plus écrire dans cette conversation';
  end if;

  -- 2026-09-26 : une demande de position n'entre QUE si elle est vraie —
  -- enregistrée par le serveur (`request_location`), au nom de son auteur.
  if new.kind = 'location_request' and not exists (
    select 1 from public.location_requests r
    where r.message_id = new.id and r.requester_id = new.sender_id
  ) then
    raise exception 'Demande de position invalide';
  end if;

  select conversation_type into ctype from conversations where id = new.conversation_id;

  if ctype = 'proximity' then
    if new.kind <> 'text' then
      raise exception 'Le canal de proximité est limité au texte';
    end if;
    select exists (
      select 1 from messages
      where conversation_id = new.conversation_id and sender_id <> new.sender_id
    ) into other_replied;
    if not other_replied then
      select count(*) into my_count
      from messages
      where conversation_id = new.conversation_id and sender_id = new.sender_id;
      if my_count >= 3 then
        raise exception 'Limite de 3 messages sans réponse atteinte';
      end if;
    end if;
  end if;

  -- Une Card jointe doit appartenir à l'expéditeur
  if new.card_id is not null then
    if not exists (select 1 from cards where id = new.card_id and owner_id = new.sender_id) then
      raise exception 'Card invalide';
    end if;
  end if;

  return new;
end;
$function$;

-- ─── Demander ─────────────────────────────────────────────────────────────
create function public.request_location(p_friend uuid)
returns uuid
language plpgsql
security definer
set search_path = 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  r public.map_rules;
  v_conv uuid;
  v_msg uuid := gen_random_uuid();
  v_id uuid := gen_random_uuid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  perform private.assert_not_suspended();
  if p_friend = me then raise exception 'Demande impossible'; end if;
  if not private.are_connected(me, p_friend) or private.is_blocked(me, p_friend) then
    raise exception 'Seulement entre amis';
  end if;
  select * into r from public.map_rules;
  if exists (select 1 from public.location_requests
              where requester_id = me and target_id = p_friend
                and created_at > now() - r.location_request_gap) then
    raise exception 'Demande déjà envoyée : patiente un peu';
  end if;
  v_conv := public.get_or_create_direct_conversation(p_friend);
  insert into public.location_requests (id, requester_id, target_id, message_id)
  values (v_id, me, p_friend, v_msg);
  insert into public.messages (id, conversation_id, sender_id, kind, body)
  values (v_msg, v_conv, me, 'location_request', v_id::text);
  return v_id;
end;
$$;
revoke all on function public.request_location(uuid) from public, anon;
grant execute on function public.request_location(uuid) to authenticated;

-- ─── Répondre ─────────────────────────────────────────────────────────────
create function public.answer_location_request(
  p_request uuid, p_accept boolean,
  p_lat double precision default null, p_lon double precision default null,
  p_acc double precision default 0
)
returns void
language plpgsql
security definer
set search_path = 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  r public.map_rules;
  q public.location_requests;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  perform private.assert_not_suspended();
  select * into r from public.map_rules;
  select * into q from public.location_requests
   where id = p_request and target_id = me for update;
  if not found then raise exception 'Demande introuvable'; end if;
  if q.answered_at is not null then raise exception 'Déjà répondu'; end if;
  if q.created_at < now() - r.location_request_ttl then
    raise exception 'Demande expirée';
  end if;
  if p_accept and (p_lat is null or p_lon is null
     or p_lat < -90 or p_lat > 90 or p_lon < -180 or p_lon > 180) then
    raise exception 'Position hors bornes';
  end if;
  update public.location_requests
     set answered_at = now(), accepted = p_accept
   where id = p_request;
  if p_accept then
    insert into public.location_reveals
      (requester_id, target_id, lat, lon, acc, at, expires_at)
    values (q.requester_id, me, p_lat, p_lon, greatest(0, coalesce(p_acc, 0)),
            now(), now() + r.location_reveal_for)
    on conflict (requester_id, target_id) do update
      set lat = excluded.lat, lon = excluded.lon, acc = excluded.acc,
          at = excluded.at, expires_at = excluded.expires_at;
  end if;
end;
$$;
revoke all on function public.answer_location_request(uuid, boolean, double precision, double precision, double precision) from public, anon;
grant execute on function public.answer_location_request(uuid, boolean, double precision, double precision, double precision) to authenticated;

-- ─── L'état d'une demande (pour la bulle du chat) ─────────────────────────
create function public.location_request_state(p_request uuid)
returns table (state text, requester_id uuid, target_id uuid,
               created_at timestamptz, expires_at timestamptz)
language plpgsql
stable security definer
set search_path = 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  r public.map_rules;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into r from public.map_rules;
  return query
  select case
           when q.answered_at is null and q.created_at < now() - r.location_request_ttl then 'expiree'
           when q.answered_at is null then 'en_attente'
           when q.accepted then 'acceptee'
           else 'refusee'
         end,
         q.requester_id, q.target_id, q.created_at,
         q.created_at + r.location_request_ttl
  from public.location_requests q
  where q.id = p_request and me in (q.requester_id, q.target_id);
end;
$$;
revoke all on function public.location_request_state(uuid) from public, anon;
grant execute on function public.location_request_state(uuid) to authenticated;

-- ─── La carte : les positions partagées ET révélées ───────────────────────
drop function public.friends_on_map();
create function public.friends_on_map()
returns table (
  user_id uuid, lat double precision, lon double precision, acc real,
  at timestamptz, display_name text, avatar_url text, revealed boolean
)
language plpgsql
stable security definer
set search_path = 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  r public.map_rules;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into r from public.map_rules;
  return query
  with vus as (
    select f.user_id, f.lat, f.lon, f.acc, f.at, false as revealed
    from public.friend_locations f
    where f.user_id <> me
      and f.at > now() - r.friend_position_max_age
      and private.may_see_location(f.user_id, me)
    union all
    -- une position donnée en réponse à MA demande, le temps qu'elle vaut
    select v.target_id, v.lat, v.lon, v.acc, v.at, true
    from public.location_reveals v
    where v.requester_id = me
      and v.expires_at > now()
      and private.are_connected(v.target_id, me)
      and not private.is_blocked(v.target_id, me)
  ),
  dernier as (
    select distinct on (vus.user_id) vus.*
    from vus order by vus.user_id, vus.at desc
  )
  select d.user_id, d.lat, d.lon, d.acc, d.at, p.display_name, p.avatar_url, d.revealed
  from dernier d
  join public.profiles p on p.id = d.user_id;
end;
$$;
revoke all on function public.friends_on_map() from public, anon;
grant execute on function public.friends_on_map() to authenticated;

-- ─── Le balai des demandes et des révélations ─────────────────────────────
select cron.schedule(
  'neovibe_purge_location_requests',
  '37 * * * *',
  $$delete from public.location_reveals where expires_at < now();
    delete from public.location_requests where created_at < now() - interval '2 days'$$
);
