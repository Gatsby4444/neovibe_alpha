-- ═══════════════════════════════════════════════════════════════════════════
-- LA POSITION DES AMIS SUR LA CARTE — 2026-09-26
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Décisions de Jay (2026-09-26) :
--   - position PRÉCISE, et SEULEMENT si l'ami a choisi de la partager dans
--     les réglages de la carte (éteint par défaut) ; on peut la cacher à
--     certains amis ;
--   - la carte dit de quand elle date (« il y a 45 min ») ;
--   - *« on n'envoie pas la position toutes les secondes »* : au plus toutes
--     les 10 secondes quand on est sur la carte, toutes les 30 minutes
--     sinon — *« il ne faut pas surcharger les services et les serveurs »*.
--
-- ## Un objet à part (règle 2 de CLAUDE.md)
--
-- La balise du ping (`ping_beacons`) sert à se RECONNAÎTRE entre inconnus ;
-- aucun client ne peut la lire. La position montrée aux amis obéit à
-- d'autres règles (partage choisi, amis seulement, masquage) : elle a SA
-- table, `friend_locations`, qui n'existe que pour qui partage.
--
-- ## La cadence est tenue ICI
--
-- `private.record_location` refuse d'écrire plus souvent que la règle
-- (`map_rules`) : 10 s en direct (carte ouverte), 30 min sinon. Le
-- « sinon » ne coûte RIEN au téléphone : la balise du ping, publiée déjà
-- une fois par minute (app ouverte ou fermée, proximité allumée), dépose
-- aussi la position des amis — au plus une fois toutes les 30 minutes.
--
-- ## Une sécurité énoncée positivement
--
-- Ne plus partager EFFACE la position : elle n'existe plus, ce n'est pas
-- « une ligne que rien ne rend lisible ».
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── Les règles, réglables depuis le futur centre de contrôle ─────────────
create table public.map_rules (
  id boolean primary key default true check (id),
  friend_live_every interval not null default interval '10 seconds',
  friend_background_every interval not null default interval '30 minutes',
  friend_position_max_age interval not null default interval '24 hours'
);
insert into public.map_rules default values;
alter table public.map_rules enable row level security;
create policy map_rules_read on public.map_rules
  for select to authenticated using (true);

-- ─── Le choix de partager ─────────────────────────────────────────────────
create table public.location_sharing (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  sharing boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.location_sharing enable row level security;
create policy location_sharing_own on public.location_sharing
  for select to authenticated using (user_id = auth.uid());

-- ─── Les amis à qui je la cache ───────────────────────────────────────────
create table public.location_hidden_from (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  friend_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, friend_id)
);
alter table public.location_hidden_from enable row level security;
create policy location_hidden_from_own on public.location_hidden_from
  for select to authenticated using (owner_id = auth.uid());

-- ─── La dernière position partagée ────────────────────────────────────────
create table public.friend_locations (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  lat double precision not null,
  lon double precision not null,
  acc real,
  at timestamptz not null default now()
);
alter table public.friend_locations enable row level security;

-- Qui peut voir la position de [owner] : lui-même ; ou un AMI (amitié
-- acceptée des deux côtés), si [owner] partage, ne la lui cache pas, et
-- qu'aucun des deux n'a bloqué l'autre.
create function private.may_see_location(owner uuid, viewer uuid)
returns boolean
language sql
stable security definer
set search_path = 'public', 'private'
as $$
  select owner = viewer or (
    exists (select 1 from public.location_sharing s
             where s.user_id = owner and s.sharing)
    and private.are_connected(owner, viewer)
    and not exists (select 1 from public.location_hidden_from h
                     where h.owner_id = owner and h.friend_id = viewer)
    and not private.is_blocked(owner, viewer)
  );
$$;
grant execute on function private.may_see_location(uuid, uuid) to authenticated;

create policy friend_locations_read on public.friend_locations
  for select to authenticated using (private.may_see_location(user_id, auth.uid()));
-- Aucune politique d'écriture : seules les fonctions ci-dessous écrivent.

-- ─── Écrire une position, à la cadence de la règle ────────────────────────
create function private.record_location(
  p_user uuid, p_lat double precision, p_lon double precision,
  p_acc double precision, p_live boolean
)
returns boolean
language plpgsql
security definer
set search_path = 'public', 'private'
as $$
declare
  r public.map_rules;
  v_last timestamptz;
  v_every interval;
begin
  if not exists (select 1 from public.location_sharing
                  where user_id = p_user and sharing) then
    return false;
  end if;
  if p_lat is null or p_lon is null
     or p_lat < -90 or p_lat > 90 or p_lon < -180 or p_lon > 180 then
    return false;
  end if;
  select * into r from public.map_rules;
  select at into v_last from public.friend_locations where user_id = p_user;
  -- (Calculé à part : un CASE dans la condition d'un IF plpgsql est lu
  -- jusqu'à son propre THEN.)
  v_every := case when p_live then r.friend_live_every
                  else r.friend_background_every end;
  if v_last is not null and now() - v_last < v_every then
    return false;
  end if;
  insert into public.friend_locations (user_id, lat, lon, acc, at)
  values (p_user, p_lat, p_lon, greatest(0, coalesce(p_acc, 0)), now())
  on conflict (user_id) do update
    set lat = excluded.lat, lon = excluded.lon, acc = excluded.acc, at = now();
  return true;
end;
$$;

-- En direct, carte ouverte : au plus toutes les 10 s (la règle).
create function public.share_my_location(
  p_lat double precision, p_lon double precision, p_acc double precision default 0
)
returns boolean
language plpgsql
security definer
set search_path = 'public', 'private'
as $$
begin
  if auth.uid() is null then raise exception 'Non authentifié'; end if;
  perform private.assert_not_suspended();
  return private.record_location(auth.uid(), p_lat, p_lon, p_acc, true);
end;
$$;
revoke all on function public.share_my_location(double precision, double precision, double precision) from public, anon;
grant execute on function public.share_my_location(double precision, double precision, double precision) to authenticated;

-- Partager ou non. Arrêter EFFACE la position.
create function public.set_location_sharing(p_on boolean)
returns void
language plpgsql
security definer
set search_path = 'public', 'private'
as $$
begin
  if auth.uid() is null then raise exception 'Non authentifié'; end if;
  insert into public.location_sharing (user_id, sharing, updated_at)
  values (auth.uid(), p_on, now())
  on conflict (user_id) do update set sharing = excluded.sharing, updated_at = now();
  if not p_on then
    delete from public.friend_locations where user_id = auth.uid();
  end if;
end;
$$;
revoke all on function public.set_location_sharing(boolean) from public, anon;
grant execute on function public.set_location_sharing(boolean) to authenticated;

-- Cacher ma position à un ami, ou la lui rendre.
create function public.set_location_hidden(p_friend uuid, p_hidden boolean)
returns void
language plpgsql
security definer
set search_path = 'public', 'private'
as $$
begin
  if auth.uid() is null then raise exception 'Non authentifié'; end if;
  if p_hidden then
    insert into public.location_hidden_from (owner_id, friend_id)
    values (auth.uid(), p_friend) on conflict do nothing;
  else
    delete from public.location_hidden_from
     where owner_id = auth.uid() and friend_id = p_friend;
  end if;
end;
$$;
revoke all on function public.set_location_hidden(uuid, boolean) from public, anon;
grant execute on function public.set_location_hidden(uuid, boolean) to authenticated;

-- Les amis visibles sur MA carte : position, âge, nom, photo. Rien au-delà
-- de l'âge maximal de la règle.
create function public.friends_on_map()
returns table (
  user_id uuid, lat double precision, lon double precision, acc real,
  at timestamptz, display_name text, avatar_url text
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
  select f.user_id, f.lat, f.lon, f.acc, f.at, p.display_name, p.avatar_url
  from public.friend_locations f
  join public.profiles p on p.id = f.user_id
  where f.user_id <> me
    and f.at > now() - r.friend_position_max_age
    and private.may_see_location(f.user_id, me);
end;
$$;
revoke all on function public.friends_on_map() from public, anon;
grant execute on function public.friends_on_map() to authenticated;

-- ─── La balise du ping dépose aussi la position des amis (≤ 30 min) ───────
CREATE OR REPLACE FUNCTION public.publish_ping_beacon(p_lat double precision, p_lon double precision, p_token text, p_slot bigint, p_acc double precision DEFAULT 0)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;
  if p_token is null or length(p_token) = 0 then
    raise exception 'Jeton manquant';
  end if;
  -- ⚠️ **Les bornes du monde se vérifient.** Le serveur dérivait auparavant le
  -- carreau d'une position forcément plausible ; maintenant qu'il conserve la
  -- valeur, une coordonnée absurde s'écrirait telle quelle et fausserait toute
  -- distance calculée ensuite.
  if p_lat is null or p_lon is null
     or p_lat < -90 or p_lat > 90 or p_lon < -180 or p_lon > 180 then
    raise exception 'Position hors bornes';
  end if;

  insert into public.ping_beacons (
    user_id, cell_lat, cell_lon, lat, lon, acc, token, slot
  )
  values (
    me,
    floor(p_lat / private.ping_cell_size())::int,
    floor(p_lon / private.ping_cell_size())::int,
    p_lat,
    p_lon,
    -- ⚠️ **`acc` n'est plus lue par aucune règle depuis le 2026-08-28**, et
    -- c'est délibéré : elle décidait qui était visible, en croyant une précision
    -- que l'appareil n'atteignait pas. Elle reste **enregistrée** parce que
    -- c'est une mesure — celle qui a permis de diagnostiquer la panne, celle qui
    -- part dans les rapports, celle dont le feed local aura besoin. Une valeur
    -- négative vaut « inconnue », donc 0.
    greatest(0, coalesce(p_acc, 0)),
    p_token,
    p_slot
  )
  on conflict (user_id) do update
    set cell_lat = excluded.cell_lat,
        cell_lon = excluded.cell_lon,
        lat = excluded.lat,
        lon = excluded.lon,
        acc = excluded.acc,
        token = excluded.token,
        slot = excluded.slot,
        updated_at = now();

  -- La position des AMIS (2026-09-26) : un autre objet, d'autres règles —
  -- déposée seulement si l'utilisateur partage, et au plus toutes les
  -- 30 minutes (`map_rules.friend_background_every`). Le téléphone n'en
  -- sait rien : il publie sa balise comme avant.
  perform private.record_location(me, p_lat, p_lon, p_acc, false);
end;
$function$;

-- ─── Le balai : une position trop vieille n'existe plus ───────────────────
select cron.schedule(
  'neovibe_purge_friend_locations',
  '29 * * * *',
  $$delete from public.friend_locations
     where at < now() - (select friend_position_max_age from public.map_rules)$$
);
