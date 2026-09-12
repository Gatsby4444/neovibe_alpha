-- ===========================================================================
-- LES ÉVÉNEMENTS, LE MODE ÉVÉNEMENT, ET LES ÉTATS DE RELATION
-- décisions de Jay du 2026-09-12 (vision : docs/vision-produit.md §8)
-- ===========================================================================
--
-- Ce que Jay a tranché, dans l'ordre :
--
--   · **Cercle** reste l'onglet ; **Événement** = ce qu'on appelait « le cercle
--     d'un lieu » ; **Groupe** = l'objet existant ; le **mode événement**
--     n'apparaît que si on a rejoint un événement, **un seul à la fois**.
--   · Deux origines d'événement : **privé** (un groupe d'événement éphémère,
--     construit pour l'occasion — jamais un groupe existant) et
--     **d'établissement** (déclaré par le commerçant).
--   · Invités d'un événement privé : **les amis au sens strict**. Tout le
--     monde peut inviter, **tous admin par défaut**, le créateur règle.
--   · La présence se prouve par un **système mixte : ping ET localisation**.
--   · Fermeture : privé → **80 % des participants partis** ; établissement →
--     **l'hôte ou l'horaire**. Sortie **automatique en s'éloignant des points
--     chauds**, ou manuelle. Le groupe survit **5 jours** puis est purgé.
--   · La fenêtre des suggestions **dépend de l'origine du croisement** : 3 jours
--     par ping ; l'événement, à choisir — *« d'abord les bases, ensuite les
--     règles précises »*.
--
-- ---------------------------------------------------------------------------
-- L'ARCHITECTURE — trois étages qui ne se mélangent pas (règle de CLAUDE.md)
-- ---------------------------------------------------------------------------
--
--   ACQUISITION   `event_positions` (où sont les présents, DERNIÈRE position
--                 seulement), `event_sightings` (qui a entendu qui, en BLE).
--                 Écrites par deux RPC, elles ne décident de rien.
--
--   DÉRIVATION    les points chauds (`event_hot_spots`) se RECALCULENT à
--                 partir des positions — jamais stockés comme un fait ; le
--                 croisement (`event_crossings`) se déduit des présences.
--
--   DÉCISION      `private.sweep_events` (sortie « away », fermeture, purge)
--                 lit `event_rules` : chaque seuil est une LIGNE, pas une
--                 constante — c'est ce que Jay a demandé pour la fenêtre.
--
-- ⚠️ **Deux règles d'entrée, deux rangements** (règle 2). Le droit d'entrer
-- dans un événement privé vit dans `event_group_members` ; celui d'un
-- établissement, dans la géographie du lieu (`venues`). `events` porte ce qui
-- est COMMUN (lieu, durée, présents, conversation) et ne décide de rien.
--
-- ⚠️ **Présence ≠ amitié ≠ croisement** (#99, #127 ④). Une présence est
-- temporaire et révocable (`event_presences`) ; l'amitié est un lien accepté
-- (`connections`) ; le croisement est un fait daté (`ping_pairs`,
-- `event_crossings`). Aucun des trois ne partage la table d'un autre.
--
-- ---------------------------------------------------------------------------
-- LES ÉTATS DE RELATION — d'abord, comme Jay l'a exigé (#99)
-- ---------------------------------------------------------------------------
--
-- Tout ce qui entrait au carnet de clés était présenté comme un ami. Ici, le
-- carnet gagne un LIBELLÉ : `private.relation_kind(me, other)` énumère
-- POSITIVEMENT qui je peux reconnaître, et pourquoi — `friend` ou `event`.
-- La politique de `device_keys` et la vue `key_book` lisent LA MÊME fonction :
-- un seul prédicat, deux consommateurs, pas de désaccord possible.
--
-- ⚠️ La valeur `event` du type `conversation_type` est ajoutée par une
-- requête SÉPARÉE, avant ce fichier (une valeur d'enum ne s'utilise pas dans
-- la transaction qui l'ajoute).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 0. Les types
-- ---------------------------------------------------------------------------

create type public.event_kind as enum ('private', 'venue');
create type public.event_role as enum ('admin', 'member');
create type public.event_leave_reason as enum ('manual', 'away', 'closed', 'removed');

-- ---------------------------------------------------------------------------
-- 1. Les PARAMÈTRES — des lignes, pas des constantes
-- ---------------------------------------------------------------------------

-- La fenêtre pendant laquelle un croisement nourrit les suggestions, PAR
-- ORIGINE. Jay, 2026-09-12 : « 3 jours pour un croisement par ping ; pour un
-- événement, les règles diffèrent — d'abord les bases, ensuite les règles ».
create table public.crossing_windows (
  origin     text primary key check (origin in ('ping', 'event')),
  fenetre    interval not null,
  decide_par text not null,
  note       text
);
insert into public.crossing_windows (origin, fenetre, decide_par, note) values
  ('ping',  interval '3 days', 'Jay, 2026-09-12',
   'Croisé en ping (le bus, la rue) : 3 jours dans les suggestions.'),
  ('event', interval '3 days', 'défaut provisoire, 2026-09-12',
   'À trancher par Jay. Même valeur que le ping en attendant, pour ne rien décider seul.');

alter table public.crossing_windows enable row level security;
create policy "crossing_windows_read" on public.crossing_windows
  for select to authenticated using (true);
revoke insert, update, delete on public.crossing_windows from anon, authenticated;

-- Les seuils du mode événement. UNE ligne. Modifier une règle = un `update`.
create table public.event_rules (
  id                    boolean primary key default true check (id),
  -- Jay, 2026-09-12 : « une soirée privée se ferme après que 80 % des
  -- participants se soient quittés ».
  private_close_ratio   numeric  not null default 0.8,
  -- Le temps qu'un événement privé doit avoir été ouvert avant que la règle
  -- des 80 % s'applique — sinon le créateur qui entre et ressort ferme tout.
  private_close_grace   interval not null default interval '30 minutes',
  -- Jay, 2026-09-12 : « 5 jours ».
  survival              interval not null default interval '5 days',
  -- Sans aucune preuve de présence (position ni ping) pendant ce délai, on
  -- est sorti. Choix du 2026-09-12, à peaufiner.
  away_after            interval not null default interval '30 minutes',
  -- Au-delà de cette distance de TOUS les points chauds, on est sorti.
  leave_radius_m        integer  not null default 300,
  -- La taille d'une case de la carte de chaleur (« comme sur Snap »).
  hot_spot_cell_m       integer  not null default 50,
  -- Les événements d'établissement proposés « autour de moi ».
  nearby_radius_m       integer  not null default 2000,
  -- Le temps passé ensemble pour qu'un croisement en événement compte
  -- (question 6 du §12, non tranchée : défaut provisoire).
  crossing_min_overlap  interval not null default interval '30 minutes',
  -- La bibliothèque « retardée » du groupe d'événement se révèle après la
  -- fermeture, plus ce délai.
  library_reveal_delay  interval not null default interval '10 hours'
);
insert into public.event_rules default values;

alter table public.event_rules enable row level security;
create policy "event_rules_read" on public.event_rules
  for select to authenticated using (true);
revoke insert, update, delete on public.event_rules from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Les ÉTABLISSEMENTS — le socle de la plateforme d'inscription
-- ---------------------------------------------------------------------------
--
-- La plateforme elle-même (le site du commerçant) est un produit à part, non
-- construit ici. Ce fichier pose le CONTRAT : un établissement, ses gérants,
-- et les RPC qu'un gérant appelle (`create_venue`, `open_venue_event`,
-- `close_event`). Voir docs/plateforme-etablissements.md.

create table public.venues (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 1 and 80),
  address    text,
  lat        double precision not null,
  lon        double precision not null,
  -- Le rayon dans lequel on est « chez lui ». Une terrasse de bar : 60 m.
  radius_m   integer not null default 60 check (radius_m between 10 and 2000),
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.venue_managers (
  venue_id uuid not null references public.venues(id) on delete cascade,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (venue_id, user_id)
);

alter table public.venues enable row level security;
alter table public.venue_managers enable row level security;

-- Un lieu se voit : c'est ce qui permet « autour de moi ». Il ne s'écrit que
-- par RPC.
create policy "venues_read" on public.venues
  for select to authenticated using (true);
create policy "venue_managers_own" on public.venue_managers
  for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.venues, public.venue_managers
  from anon, authenticated;

create or replace function private.manages_venue(p_venue uuid, p_uid uuid)
returns boolean
language sql stable security definer
set search_path = public, private
as $$
  select exists (
    select 1 from public.venue_managers
    where venue_id = p_venue and user_id = p_uid
  );
$$;
grant execute on function private.manages_venue(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. L'ÉVÉNEMENT — ce qui est commun aux deux origines
-- ---------------------------------------------------------------------------

create table public.events (
  id                   uuid primary key default gen_random_uuid(),
  kind                 public.event_kind not null,
  title                text not null check (length(btrim(title)) between 1 and 80),
  created_by           uuid not null references public.profiles(id) on delete cascade,
  -- Renseigné SI ET SEULEMENT SI l'événement est d'établissement.
  venue_id             uuid references public.venues(id) on delete cascade,
  -- Le groupe d'événement : une conversation de type `event`, éphémère.
  conversation_id      uuid not null references public.conversations(id) on delete cascade,
  -- Le lieu déclaré. Copié du lieu pour un établissement ; facultatif pour un
  -- événement privé (un voyage n'a pas de lieu fixe — §8.4.2 ④).
  lat                  double precision,
  lon                  double precision,
  radius_m             integer,
  starts_at            timestamptz not null default now(),
  -- Établissement : l'horaire de fermeture paramétré. Privé : fin prévue,
  -- indicative.
  scheduled_end_at     timestamptz,
  -- La première présence. Tant que c'est nul, la règle des 80 % ne joue pas.
  opened_at            timestamptz,
  closed_at            timestamptz,
  close_reason         text,
  -- Les paramètres du créateur (« comme sur WhatsApp ») — privé seulement.
  members_can_add      boolean not null default true,
  members_can_remove   boolean not null default true,
  -- La bibliothèque retardée : nul tant que l'événement est ouvert.
  library_reveal_at    timestamptz,
  created_at           timestamptz not null default now(),
  constraint events_venue_iff_kind check ((kind = 'venue') = (venue_id is not null)),
  constraint events_place_complete check ((lat is null) = (lon is null))
);
create index events_open_idx on public.events (kind) where closed_at is null;
create index events_conversation_idx on public.events (conversation_id);

-- Le GROUPE D'ÉVÉNEMENT (privé) : qui est invité, avec quel rôle.
-- ⚠️ Ce n'est PAS `conversation_members` : la conversation en est le miroir
-- (tenue par les RPC), mais le droit d'inviter et de retirer vit ici.
create table public.event_group_members (
  event_id  uuid not null references public.events(id) on delete cascade,
  user_id   uuid not null references public.profiles(id) on delete cascade,
  role      public.event_role not null default 'admin',
  added_by  uuid references public.profiles(id) on delete set null,
  joined_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

-- LA PRÉSENCE : « j'y suis » — temporaire, révocable, historisée.
create table public.event_presences (
  id               uuid primary key default gen_random_uuid(),
  event_id         uuid not null references public.events(id) on delete cascade,
  user_id          uuid not null references public.profiles(id) on delete cascade,
  joined_at        timestamptz not null default now(),
  left_at          timestamptz,
  left_reason      public.event_leave_reason,
  -- Les deux preuves du système mixte, chacune datée.
  last_position_at timestamptz,
  last_ping_at     timestamptz,
  constraint event_presences_left_complete check ((left_at is null) = (left_reason is null))
);
-- ⚠️ « On ne peut rejoindre qu'un événement à la fois » — tenu par la base.
create unique index event_presences_one_open
  on public.event_presences (user_id) where left_at is null;
create index event_presences_event_open
  on public.event_presences (event_id) where left_at is null;
create index event_presences_event_user
  on public.event_presences (event_id, user_id);

-- LA POSITION : la DERNIÈRE seulement, effacée à la sortie. Rien d'autre
-- n'est gardé — une trajectoire n'est pas une preuve de présence.
create table public.event_positions (
  event_id    uuid not null references public.events(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  lat         double precision not null,
  lon         double precision not null,
  acc         double precision,
  reported_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

-- LES CONSTATS BLE entre co-participants. Distincts de `sightings` : ceux-là
-- sont entre amis et nourrissent les paliers ; ceux-ci ne prouvent que la
-- présence et disparaissent avec l'événement.
create table public.event_sightings (
  event_id    uuid not null references public.events(id) on delete cascade,
  observer_id uuid not null references public.profiles(id) on delete cascade,
  seen_id     uuid not null references public.profiles(id) on delete cascade,
  slot        bigint not null,
  created_at  timestamptz not null default now(),
  primary key (event_id, observer_id, seen_id, slot)
);

-- LE CROISEMENT EN ÉVÉNEMENT : un fait daté, de personne à personne, qui
-- porte son origine. `event_title` est copié parce que le croisement doit
-- pouvoir dire « au Temple » après que l'événement a été purgé.
create table public.event_crossings (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid references public.events(id) on delete set null,
  event_title text not null,
  user_low    uuid not null references public.profiles(id) on delete cascade,
  user_high   uuid not null references public.profiles(id) on delete cascade,
  first_at    timestamptz not null default now(),
  last_at     timestamptz not null default now(),
  -- 'ping' : entendus mutuellement ; 'presence' : présents ensemble assez
  -- longtemps (calculé à la fermeture).
  source      text not null check (source in ('ping', 'presence')),
  unique (event_id, user_low, user_high),
  check (user_low < user_high)
);
create index event_crossings_pair on public.event_crossings (user_low, user_high, last_at desc);

-- ---------------------------------------------------------------------------
-- 4. Les prédicats
-- ---------------------------------------------------------------------------

-- « Jamais » : une date que l'app sait lire, là où `infinity` la ferait
-- planter (`DateTime.parse`). Une bibliothèque d'événement encore ouvert.
create or replace function private.jamais()
returns timestamptz
language sql immutable
as $$ select '9999-12-31T00:00:00Z'::timestamptz $$;

create or replace function private.is_event_member(p_event uuid, p_uid uuid)
returns boolean
language sql stable security definer
set search_path = public, private
as $$
  select exists (
    select 1 from public.event_group_members
    where event_id = p_event and user_id = p_uid
  );
$$;

create or replace function private.is_present_in_event(p_event uuid, p_uid uuid)
returns boolean
language sql stable security definer
set search_path = public, private
as $$
  select exists (
    select 1 from public.event_presences
    where event_id = p_event and user_id = p_uid and left_at is null
  );
$$;

-- « Concerné » par un événement : invité (privé) ou y a été présent (les
-- deux). C'est le droit de LIRE l'événement.
create or replace function private.concerned_by_event(p_event uuid, p_uid uuid)
returns boolean
language sql stable security definer
set search_path = public, private
as $$
  select private.is_event_member(p_event, p_uid)
      or exists (
        select 1 from public.event_presences
        where event_id = p_event and user_id = p_uid
      )
      or exists (
        select 1 from public.events e
        where e.id = p_event and private.manages_venue(e.venue_id, p_uid)
      );
$$;

-- 🔴 L'ÉTAT DE RELATION — l'énumération POSITIVE de qui je peux reconnaître.
--
--   'friend' : une amitié acceptée des deux côtés ;
--   'event'  : nous sommes présents dans le même événement ouvert, ou invités
--              au même événement privé encore en vie.
--   null     : personne d'autre — et jamais quelqu'un qui m'a bloqué.
--
-- ⚠️ Lue par la politique de `device_keys` ET par la vue `key_book`. C'est
-- voulu : une seule définition, deux lecteurs.
create or replace function private.relation_kind(me uuid, other uuid)
returns text
language sql stable security definer
set search_path = public, private
as $$
  select case
    when me is null or other is null or me = other then null
    when private.a_bloque(other, me) then null
    when private.are_connected(me, other) then 'friend'
    when exists (
      select 1
      from public.event_presences a
      join public.event_presences b on b.event_id = a.event_id
      join public.events e on e.id = a.event_id
      where a.user_id = me and b.user_id = other
        and a.left_at is null and b.left_at is null
        and e.closed_at is null
    ) then 'event'
    when exists (
      select 1
      from public.event_group_members a
      join public.event_group_members b on b.event_id = a.event_id
      join public.events e on e.id = a.event_id
      where a.user_id = me and b.user_id = other
        and e.kind = 'private' and e.closed_at is null
    ) then 'event'
    else null
  end;
$$;
grant execute on function private.relation_kind(uuid, uuid) to authenticated;
grant execute on function private.is_event_member(uuid, uuid) to authenticated;
grant execute on function private.is_present_in_event(uuid, uuid) to authenticated;
grant execute on function private.concerned_by_event(uuid, uuid) to authenticated;

-- La fenêtre d'un croisement, PAR ORIGINE — lue dans la table.
create or replace function private.fenetre_croisement(p_origin text)
returns interval
language sql stable
set search_path = public, private
as $$
  select fenetre from public.crossing_windows where origin = p_origin;
$$;

-- La signature historique reste : elle vaut désormais « par ping ». Ses
-- lecteurs (`crossed_recently`, `request_connection_with_vibe`) sont réécrits
-- plus bas pour passer par `crossing_within_window`.
create or replace function private.fenetre_croisement()
returns interval
language sql stable
set search_path = public, private
as $$
  select private.fenetre_croisement('ping');
$$;

-- « Nous sommes-nous croisés, dans la fenêtre de l'origine ? » — les deux
-- origines, chacune avec SA fenêtre. La seule question que posent la demande
-- d'ami avec Vibe et la liste des suggestions.
create or replace function private.crossing_within_window(a uuid, b uuid)
returns boolean
language sql stable security definer
set search_path = public, private
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
grant execute on function private.crossing_within_window(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Les politiques
-- ---------------------------------------------------------------------------

alter table public.events enable row level security;
alter table public.event_group_members enable row level security;
alter table public.event_presences enable row level security;
alter table public.event_positions enable row level security;
alter table public.event_sightings enable row level security;
alter table public.event_crossings enable row level security;

-- Un événement se lit si l'on est concerné ; un événement d'établissement
-- OUVERT se lit par tout le monde (c'est « autour de moi »).
create policy "events_read" on public.events
  for select to authenticated
  using (
    private.concerned_by_event(id, (select auth.uid()))
    or (kind = 'venue' and closed_at is null)
  );

create policy "event_group_members_read" on public.event_group_members
  for select to authenticated
  using (private.is_event_member(event_id, (select auth.uid())));

-- Les présences : les miennes, et celles des événements qui me concernent.
create policy "event_presences_read" on public.event_presences
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or private.concerned_by_event(event_id, (select auth.uid()))
  );

-- ⚠️ Une position ne se lit JAMAIS par quelqu'un d'autre. Les autres ne
-- voient que les points chauds (`event_hot_spots`), agrégés.
create policy "event_positions_own" on public.event_positions
  for select to authenticated using (user_id = (select auth.uid()));

create policy "event_sightings_own" on public.event_sightings
  for select to authenticated using (observer_id = (select auth.uid()));

create policy "event_crossings_own" on public.event_crossings
  for select to authenticated
  using (user_low = (select auth.uid()) or user_high = (select auth.uid()));

-- Tout s'écrit par RPC. Aucune écriture directe.
revoke insert, update, delete on
  public.events, public.event_group_members, public.event_presences,
  public.event_positions, public.event_sightings, public.event_crossings
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Le CARNET DE CLÉS reconnaît par ÉTAT DE RELATION
-- ---------------------------------------------------------------------------
--
-- Avant : `device_keys_friends` — les amis, moins ceux qui m'ont bloqué.
-- Après : la même chose, PLUS les co-participants d'un événement — et le
-- client sait POURQUOI il reçoit chaque ligne, par la vue `key_book`.

drop policy if exists "device_keys_friends" on public.device_keys;
create policy "device_keys_recognizable" on public.device_keys
  for select to authenticated
  using (private.relation_kind((select auth.uid()), user_id) is not null);

-- `security_invoker` : la vue passe par la politique de la table. Elle ne
-- rend donc que ce que `device_keys` rend, avec le libellé en plus.
create view public.key_book
with (security_invoker = true) as
  select k.user_id,
         k.x25519_pub,
         k.updated_at,
         private.relation_kind((select auth.uid()), k.user_id) as relation
  from public.device_keys k
  where k.user_id <> (select auth.uid());
grant select on public.key_book to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Fermer un événement — UN seul endroit
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

  update public.events
     set closed_at = now(),
         close_reason = p_reason,
         library_reveal_at = now() + coalesce(r.library_reveal_delay, interval '10 hours')
   where id = p_event;

  -- La bibliothèque retardée se date à la fermeture : jusque-là ses Vibes
  -- portaient `private.jamais()`.
  update public.library_vibes
     set reveal_at = now() + coalesce(r.library_reveal_delay, interval '10 hours')
   where conversation_id = e.conversation_id;

  -- Les croisements par PRÉSENCE : présents ensemble au moins
  -- `crossing_min_overlap`, toutes présences cumulées.
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

-- ---------------------------------------------------------------------------
-- 8. Les points chauds — une VUE DÉRIVÉE des positions, jamais un fait
-- ---------------------------------------------------------------------------
--
-- Une case de `hot_spot_cell_m` de côté ; on rend le centre des cases
-- occupées par des présents dont la position est fraîche, avec le nombre.
-- Le lieu déclaré compte comme un point chaud permanent (poids 0).

create or replace function private.event_hot_spots_raw(p_event uuid)
returns table (lat double precision, lon double precision, headcount integer)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  r public.event_rules;
  e public.events;
  cell_deg double precision;
begin
  select * into r from public.event_rules;
  select * into e from public.events where id = p_event;
  if not found then return; end if;
  -- ~111 km par degré de latitude ; on tolère l'approximation en longitude.
  cell_deg := r.hot_spot_cell_m / 111000.0;

  return query
  select (floor(p.lat / cell_deg) * cell_deg + cell_deg / 2)::double precision,
         (floor(p.lon / cell_deg) * cell_deg + cell_deg / 2)::double precision,
         count(*)::integer
  from public.event_positions p
  join public.event_presences pr
    on pr.event_id = p.event_id and pr.user_id = p.user_id and pr.left_at is null
  where p.event_id = p_event
    and p.reported_at > now() - r.away_after
  group by 1, 2
  union all
  select e.lat, e.lon, 0
  where e.lat is not null;
end;
$$;

create or replace function public.event_hot_spots(p_event uuid)
returns table (lat double precision, lon double precision, headcount integer)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if not private.concerned_by_event(p_event, me) then
    raise exception 'Événement introuvable';
  end if;
  return query select * from private.event_hot_spots_raw(p_event);
end;
$$;
revoke all on function public.event_hot_spots(uuid) from public, anon;
grant execute on function public.event_hot_spots(uuid) to authenticated;

-- Loin de TOUS les points chauds ? Pour la décision qui concerne UNE
-- personne, les points chauds sont : le lieu déclaré, et les positions
-- fraîches des AUTRES présents. (Sans lieu ni autre présent, on n'est jamais
-- loin de rien.)
create or replace function private.far_from_event(
  p_event uuid, p_uid uuid, p_lat double precision, p_lon double precision, p_acc double precision
) returns boolean
language plpgsql stable security definer
set search_path = public, private
as $$
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
  return nearest > r.leave_radius_m + coalesce(least(p_acc, 100), 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Les RPC de l'événement PRIVÉ — le groupe d'événement
-- ---------------------------------------------------------------------------

create or replace function public.create_private_event(
  p_title text,
  p_starts_at timestamptz default now(),
  p_ends_at timestamptz default null,
  p_lat double precision default null,
  p_lon double precision default null,
  p_member_ids uuid[] default '{}'
) returns uuid
language plpgsql security definer
set search_path = public, private
as $$
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
     case when p_lat is null then null else (select leave_radius_m from public.event_rules) end,
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
$$;

-- Qui peut inviter : le créateur toujours ; un admin si `members_can_add`.
create or replace function private.may_invite_to_event(p_event uuid, p_uid uuid)
returns boolean
language sql stable security definer
set search_path = public, private
as $$
  select exists (
    select 1 from public.events e
    join public.event_group_members m on m.event_id = e.id and m.user_id = p_uid
    where e.id = p_event and e.kind = 'private' and e.closed_at is null
      and (e.created_by = p_uid or (m.role = 'admin' and e.members_can_add))
  );
$$;

create or replace function private.may_remove_from_event(p_event uuid, p_uid uuid)
returns boolean
language sql stable security definer
set search_path = public, private
as $$
  select exists (
    select 1 from public.events e
    join public.event_group_members m on m.event_id = e.id and m.user_id = p_uid
    where e.id = p_event and e.kind = 'private' and e.closed_at is null
      and (e.created_by = p_uid or (m.role = 'admin' and e.members_can_remove))
  );
$$;
grant execute on function private.may_invite_to_event(uuid, uuid) to authenticated;
grant execute on function private.may_remove_from_event(uuid, uuid) to authenticated;

create or replace function public.invite_to_event(p_event uuid, p_user uuid)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  conv uuid;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if not private.may_invite_to_event(p_event, me) then
    raise exception 'Tu ne peux pas inviter ici';
  end if;
  -- 🔴 LA RÈGLE DE JAY : on n'invite que SES amis, au sens strict.
  if not private.are_connected(me, p_user) or private.is_blocked(me, p_user) then
    raise exception 'On n''invite que ses amis';
  end if;
  select conversation_id into conv from public.events where id = p_event;
  insert into public.event_group_members (event_id, user_id, role, added_by)
  values (p_event, p_user, 'admin', me) on conflict do nothing;
  insert into public.conversation_members (conversation_id, user_id)
  values (conv, p_user) on conflict do nothing;
end;
$$;

create or replace function public.remove_from_event(p_event uuid, p_user uuid)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  e public.events;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into e from public.events where id = p_event;
  if not found or e.kind <> 'private' then raise exception 'Événement introuvable'; end if;
  if p_user = e.created_by then raise exception 'Le créateur ne se retire pas'; end if;
  if p_user <> me and not private.may_remove_from_event(p_event, me) then
    raise exception 'Tu ne peux pas retirer quelqu''un ici';
  end if;
  update public.event_presences
     set left_at = now(), left_reason = case when p_user = me then 'manual' else 'removed' end
   where event_id = p_event and user_id = p_user and left_at is null;
  delete from public.event_positions where event_id = p_event and user_id = p_user;
  delete from public.event_group_members where event_id = p_event and user_id = p_user;
  delete from public.conversation_members
   where conversation_id = e.conversation_id and user_id = p_user;
end;
$$;

create or replace function public.set_event_member_role(
  p_event uuid, p_user uuid, p_role public.event_role
) returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if not exists (
    select 1 from public.events where id = p_event and created_by = me and closed_at is null
  ) then
    raise exception 'Seul le créateur règle les rôles';
  end if;
  if p_user = me then raise exception 'Le créateur reste admin'; end if;
  update public.event_group_members set role = p_role
   where event_id = p_event and user_id = p_user;
end;
$$;

-- Les réglages du créateur — privé. Un gérant règle son événement
-- d'établissement par `update_venue_event`.
create or replace function public.update_event_settings(
  p_event uuid,
  p_title text default null,
  p_members_can_add boolean default null,
  p_members_can_remove boolean default null,
  p_ends_at timestamptz default null,
  p_lat double precision default null,
  p_lon double precision default null,
  p_clear_place boolean default false
) returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  e public.events;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into e from public.events where id = p_event for update;
  if not found or e.closed_at is not null then raise exception 'Événement introuvable'; end if;
  if e.kind = 'private' and e.created_by <> me then
    raise exception 'Seul le créateur règle l''événement';
  end if;
  if e.kind = 'venue' and not private.manages_venue(e.venue_id, me) then
    raise exception 'Seul un gérant règle l''événement';
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
$$;

-- ---------------------------------------------------------------------------
-- 10. Les RPC de l'ÉTABLISSEMENT — le contrat de la plateforme
-- ---------------------------------------------------------------------------

create or replace function public.create_venue(
  p_name text, p_lat double precision, p_lon double precision,
  p_radius_m integer default 60, p_address text default null
) returns uuid
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  v uuid;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  insert into public.venues (name, address, lat, lon, radius_m, created_by)
  values (btrim(p_name), p_address, p_lat, p_lon, coalesce(p_radius_m, 60), me)
  returning id into v;
  insert into public.venue_managers (venue_id, user_id) values (v, me);
  return v;
end;
$$;

create or replace function public.open_venue_event(
  p_venue uuid, p_title text, p_closes_at timestamptz, p_starts_at timestamptz default now()
) returns uuid
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  v public.venues;
  conv uuid;
  ev uuid;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if not private.manages_venue(p_venue, me) then raise exception 'Lieu introuvable'; end if;
  select * into v from public.venues where id = p_venue;
  if p_closes_at is null or p_closes_at <= coalesce(p_starts_at, now()) then
    raise exception 'Un événement d''établissement a un horaire de fermeture';
  end if;

  insert into public.conversations (conversation_type, title, created_by)
  values ('event', btrim(p_title), me)
  returning id into conv;

  insert into public.events
    (kind, title, created_by, venue_id, conversation_id, lat, lon, radius_m,
     starts_at, scheduled_end_at)
  values
    ('venue', btrim(p_title), me, p_venue, conv, v.lat, v.lon, v.radius_m,
     coalesce(p_starts_at, now()), p_closes_at)
  returning id into ev;

  -- Le gérant suit la conversation de sa soirée.
  insert into public.conversation_members (conversation_id, user_id) values (conv, me);
  return ev;
end;
$$;

-- Fermer : le gérant (établissement) ou le créateur (privé, pour ne pas
-- attendre les 80 %).
create or replace function public.close_event(p_event uuid)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  e public.events;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into e from public.events where id = p_event;
  if not found then raise exception 'Événement introuvable'; end if;
  if e.kind = 'venue' and not private.manages_venue(e.venue_id, me) then
    raise exception 'Seul un gérant ferme la soirée';
  end if;
  if e.kind = 'private' and e.created_by <> me then
    raise exception 'Seul le créateur ferme l''événement';
  end if;
  perform private.close_event(p_event, 'host');
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. La PRÉSENCE — rejoindre, se signaler, sortir
-- ---------------------------------------------------------------------------

create or replace function public.join_event(
  p_event uuid, p_lat double precision, p_lon double precision, p_acc double precision default null
) returns uuid
language plpgsql security definer
set search_path = public, private
as $$
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
    if d > coalesce(e.radius_m, r.leave_radius_m) + coalesce(least(p_acc, 100), 0) then
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
$$;

create or replace function public.leave_event(p_event uuid)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  update public.event_presences
     set left_at = now(), left_reason = 'manual'
   where event_id = p_event and user_id = me and left_at is null;
  delete from public.event_positions where event_id = p_event and user_id = me;
end;
$$;

-- L'ACQUISITION de la position, pendant l'événement. Elle constate, et une
-- seule décision en découle — être loin de tout point chaud, c'est être sorti.
create or replace function public.report_event_position(
  p_lat double precision, p_lon double precision, p_acc double precision default null
) returns text
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  p public.event_presences;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into p from public.event_presences where user_id = me and left_at is null;
  if not found then return 'none'; end if;
  if p_lat is null or p_lon is null then return 'present'; end if;

  if private.far_from_event(p.event_id, me, p_lat, p_lon, p_acc) then
    update public.event_presences
       set left_at = now(), left_reason = 'away' where id = p.id;
    delete from public.event_positions where event_id = p.event_id and user_id = me;
    return 'away';
  end if;

  insert into public.event_positions (event_id, user_id, lat, lon, acc, reported_at)
  values (p.event_id, me, p_lat, p_lon, p_acc, now())
  on conflict (event_id, user_id) do update
    set lat = excluded.lat, lon = excluded.lon, acc = excluded.acc, reported_at = now();
  update public.event_presences set last_position_at = now() where id = p.id;
  return 'present';
end;
$$;

revoke all on function
  public.create_private_event(text, timestamptz, timestamptz, double precision, double precision, uuid[]),
  public.invite_to_event(uuid, uuid),
  public.remove_from_event(uuid, uuid),
  public.set_event_member_role(uuid, uuid, public.event_role),
  public.update_event_settings(uuid, text, boolean, boolean, timestamptz, double precision, double precision, boolean),
  public.create_venue(text, double precision, double precision, integer, text),
  public.open_venue_event(uuid, text, timestamptz, timestamptz),
  public.close_event(uuid),
  public.join_event(uuid, double precision, double precision, double precision),
  public.leave_event(uuid),
  public.report_event_position(double precision, double precision, double precision)
  from public, anon;
grant execute on function
  public.create_private_event(text, timestamptz, timestamptz, double precision, double precision, uuid[]),
  public.invite_to_event(uuid, uuid),
  public.remove_from_event(uuid, uuid),
  public.set_event_member_role(uuid, uuid, public.event_role),
  public.update_event_settings(uuid, text, boolean, boolean, timestamptz, double precision, double precision, boolean),
  public.create_venue(text, double precision, double precision, integer, text),
  public.open_venue_event(uuid, text, timestamptz, timestamptz),
  public.close_event(uuid),
  public.join_event(uuid, double precision, double precision, double precision),
  public.leave_event(uuid),
  public.report_event_position(double precision, double precision, double precision)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 12. Les LECTURES — ce que l'app affiche
-- ---------------------------------------------------------------------------

-- Mes événements : ceux où je suis invité (privé), ceux où j'ai été présent
-- (les deux), ceux que je gère — tant qu'ils ne sont pas purgés.
create or replace function public.my_events()
returns table (
  id uuid, kind public.event_kind, title text, venue_name text,
  created_by uuid, conversation_id uuid,
  lat double precision, lon double precision, radius_m integer,
  starts_at timestamptz, scheduled_end_at timestamptz,
  opened_at timestamptz, closed_at timestamptz,
  members_can_add boolean, members_can_remove boolean,
  library_reveal_at timestamptz,
  present_count integer, guest_count integer,
  i_am_present boolean, my_role public.event_role, i_manage boolean
)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  return query
  select e.id, e.kind, e.title, v.name,
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
$$;

-- Les gens d'un événement : invités (privé) et présents, avec leur relation
-- avec moi. C'est la liste du mode événement.
create or replace function public.event_people(p_event uuid)
returns table (
  user_id uuid, display_name text, tag_name text, avatar_url text,
  role public.event_role, invited boolean, present boolean,
  relation text, joined_at timestamptz
)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if not private.concerned_by_event(p_event, me) then
    raise exception 'Événement introuvable';
  end if;
  return query
  with gens as (
    select m.user_id, m.role, true as invited, m.joined_at
    from public.event_group_members m where m.event_id = p_event
    union
    select p.user_id, null::public.event_role, false, p.joined_at
    from public.event_presences p
    where p.event_id = p_event and p.left_at is null
      and not exists (select 1 from public.event_group_members m
                      where m.event_id = p_event and m.user_id = p.user_id)
  )
  select g.user_id, pr.display_name, pr.tag_name, pr.avatar_url,
         g.role, g.invited,
         private.is_present_in_event(p_event, g.user_id),
         case when g.user_id = me then 'me' else private.relation_kind(me, g.user_id) end,
         g.joined_at
  from gens g
  join public.profiles pr on pr.id = g.user_id
  where not private.is_blocked(me, g.user_id)
  order by private.is_present_in_event(p_event, g.user_id) desc, pr.display_name;
end;
$$;

-- « Autour de moi » : les événements d'établissement ouverts, à portée.
create or replace function public.nearby_venue_events(p_lat double precision, p_lon double precision)
returns table (
  id uuid, title text, venue_name text, venue_address text,
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
  select e.id, e.title, v.name, v.address, e.lat, e.lon, e.radius_m,
         e.starts_at, e.scheduled_end_at,
         (select count(*)::integer from public.event_presences p
           where p.event_id = e.id and p.left_at is null),
         round(private.meters_between(p_lat, p_lon, e.lat, e.lon))::integer
  from public.events e
  join public.venues v on v.id = e.venue_id
  where e.kind = 'venue' and e.closed_at is null and e.starts_at <= now()
    and private.meters_between(p_lat, p_lon, e.lat, e.lon) <= r.nearby_radius_m
  order by 11;
end;
$$;

revoke all on function public.my_events(), public.event_people(uuid),
  public.nearby_venue_events(double precision, double precision) from public, anon;
grant execute on function public.my_events(), public.event_people(uuid),
  public.nearby_venue_events(double precision, double precision) to authenticated;

-- ---------------------------------------------------------------------------
-- 13. Le BALAI — sortie « away », fermetures, purge. Un job à lui seul.
-- ---------------------------------------------------------------------------

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

  -- 2. L'horaire de fermeture d'un établissement.
  for e in select id from public.events
            where closed_at is null and kind = 'venue'
              and scheduled_end_at is not null and scheduled_end_at <= now()
  loop
    perform private.close_event(e.id, 'schedule');
  end loop;

  -- 3. Les 80 % d'un événement privé (après le délai de grâce).
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

  -- 4. La purge : 5 jours après la fermeture, l'événement ET sa conversation
  --    (donc son chat et sa bibliothèque) disparaissent. Les croisements
  --    restent (event_id devient nul, le titre est copié).
  for e in select id, conversation_id from public.events
            where closed_at is not null and closed_at < now() - r.survival
  loop
    delete from public.events where id = e.id;
    delete from public.conversations where id = e.conversation_id;
  end loop;
end;
$$;

select cron.schedule(
  'neovibe_events',
  '* * * * *',
  $$ select private.sweep_events() $$
);

-- ---------------------------------------------------------------------------
-- 14. Ce qui EXISTAIT et qui apprend l'événement
-- ---------------------------------------------------------------------------

-- 14a. `report_sightings` : les constats entre AMIS suivent le chemin connu ;
--      ceux entre CO-PARTICIPANTS vont dans `event_sightings`, prouvent la
--      présence, et font un croisement d'événement s'ils sont mutuels.
--      ⚠️ Ils ne touchent ni `sightings`, ni `encounters`, ni `meeting_days` :
--      un inconnu de soirée ne monte pas un palier d'amitié.
create or replace function public.report_sightings(items jsonb)
returns integer
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  item jsonb;
  peer uuid;
  s bigint;
  now_slot bigint := floor(extract(epoch from now()) / private.slot_seconds());
  retenus int := 0;
  ajoutes int;
  lo uuid;
  hi uuid;
  ev record;
begin
  if me is null then
    raise exception 'Non authentifie';
  end if;

  for item in select * from jsonb_array_elements(items) loop
    peer := (item->>'peer')::uuid;
    s := (item->>'slot')::bigint;

    if peer is null or s is null or peer = me then
      continue;
    end if;

    if s > now_slot + 1 or s < now_slot - (48 * 3600 / private.slot_seconds()) then
      continue;
    end if;

    if private.are_connected(me, peer) then
      insert into public.sightings (observer_id, seen_id, slot, band)
      values (me, peer, s, item->>'band')
      on conflict (observer_id, seen_id, slot) do nothing;

      get diagnostics ajoutes = row_count;
      retenus := retenus + ajoutes;

      if exists (
        select 1 from public.sightings m
        where m.observer_id = peer
          and m.seen_id = me
          and m.slot between s - 1 and s + 1
      ) then
        lo := least(me, peer);
        hi := greatest(me, peer);
        insert into public.encounters
          (user_low, user_high, first_seen_at, last_seen_at, proof)
        values (lo, hi, now(), now(), 'mutual_sighting')
        on conflict (user_low, user_high) do update
          set last_seen_at = greatest(excluded.last_seen_at, encounters.last_seen_at),
              proof = case
                        when encounters.proof = 'certificate' then 'certificate'
                        else excluded.proof
                      end;

        insert into public.meeting_days (user_low, user_high, day)
        values (lo, hi, (now() at time zone 'utc')::date)
        on conflict do nothing;

        if found then
          perform private.refresh_tier(lo, hi);
        end if;
      end if;
      continue;
    end if;

    -- Pas amis : le seul autre cas où je peux l'avoir reconnu, c'est un
    -- événement ouvert où nous sommes présents tous les deux.
    select e.id, e.title into ev
    from public.events e
    join public.event_presences a on a.event_id = e.id and a.user_id = me and a.left_at is null
    join public.event_presences b on b.event_id = e.id and b.user_id = peer and b.left_at is null
    where e.closed_at is null
    limit 1;
    if not found then
      continue;
    end if;

    insert into public.event_sightings (event_id, observer_id, seen_id, slot)
    values (ev.id, me, peer, s)
    on conflict do nothing;
    get diagnostics ajoutes = row_count;
    retenus := retenus + ajoutes;

    -- Entendre un co-participant, c'est être là : la preuve « ping ».
    update public.event_presences
       set last_ping_at = now()
     where event_id = ev.id and user_id = me and left_at is null;

    if exists (
      select 1 from public.event_sightings m
      where m.event_id = ev.id and m.observer_id = peer and m.seen_id = me
        and m.slot between s - 1 and s + 1
    ) and not private.is_blocked(me, peer) then
      lo := least(me, peer);
      hi := greatest(me, peer);
      insert into public.event_crossings
        (event_id, event_title, user_low, user_high, first_at, last_at, source)
      values (ev.id, ev.title, lo, hi, now(), now(), 'ping')
      on conflict (event_id, user_low, user_high) do update
        set last_at = now();
    end if;
  end loop;

  return retenus;
end;
$$;

-- 14b. `crossed_recently` : les deux origines, chacune avec SA fenêtre, et
--      le croisement DIT d'où il vient (« au Temple »).
drop function if exists public.crossed_recently();
create or replace function public.crossed_recently()
returns table (
  user_id uuid, display_name text, tag_name text, avatar_url text,
  crossed_at timestamptz, already_requested boolean,
  origin text, event_title text
)
language plpgsql stable security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  return query
  -- ⚠️ Les alias internes ne reprennent PAS les noms des colonnes de sortie
  -- (`origin`, `event_title`) : en PL/pgSQL, ce serait ambigu.
  with croisements as (
    select case when pp.user_low = me then pp.user_high else pp.user_low end as autre,
           pp.last_seen_at as quand, 'ping'::text as orig, null::text as titre
    from public.ping_pairs pp
    where (pp.user_low = me or pp.user_high = me)
      and pp.last_seen_at > now() - private.fenetre_croisement('ping')
    union all
    select case when c.user_low = me then c.user_high else c.user_low end,
           c.last_at, 'event', c.event_title
    from public.event_crossings c
    where (c.user_low = me or c.user_high = me)
      and c.last_at > now() - private.fenetre_croisement('event')
  ),
  dernier as (
    select distinct on (autre) autre, quand, orig, titre
    from croisements
    order by autre, quand desc
  )
  select p.id, p.display_name, p.tag_name, p.avatar_url, d.quand,
         exists (
           select 1 from public.connection_requests r
           where r.sender_id = me and r.receiver_id = p.id
             and r.status = 'pending' and r.expires_at > now()
         ),
         d.orig, d.titre
  from dernier d
  join public.profiles p on p.id = d.autre
  where not private.are_connected(me, p.id)
    and not private.is_blocked(me, p.id)
  order by d.quand desc;
end;
$$;
revoke all on function public.crossed_recently() from public, anon;
grant execute on function public.crossed_recently() to authenticated;

-- 14c. La demande d'ami AVEC Vibe : le croisement ouvre la porte, quelle que
--      soit son origine, dans la fenêtre de cette origine.
create or replace function public.request_connection_with_vibe(peer uuid, p_card_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  req_id uuid;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;
  if peer is null or peer = me then
    raise exception 'Destinataire invalide';
  end if;

  if not exists (
    select 1 from public.cards c where c.id = p_card_id and c.owner_id = me
  ) then
    raise exception 'Vibe introuvable';
  end if;

  if are_connected(me, peer) then
    raise exception 'Vous êtes déjà connectés';
  end if;

  -- 🔴 LA BARRIÈRE FONDATRICE, par origine de croisement (2026-09-12).
  if not private.crossing_within_window(me, peer) then
    raise exception 'Croisement non constaté';
  end if;

  if private.is_blocked(me, peer) then
    raise exception 'Envoi impossible';
  end if;

  select id into req_id
  from public.connection_requests
  where sender_id = me and receiver_id = peer and status = 'pending'
    and expires_at > now()
  limit 1;

  if req_id is not null then
    update public.connection_requests set card_id = p_card_id where id = req_id;
  else
    insert into public.connection_requests
      (sender_id, receiver_id, status, expires_at, card_id)
    values (me, peer, 'pending', now() + interval '7 days', p_card_id)
    returning id into req_id;
  end if;

  insert into public.card_deliveries (card_id, recipient_id, message_id)
  values (p_card_id, peer, null)
  on conflict do nothing;

  return req_id;
end;
$$;

-- 14d. La purge du ping suit la fenêtre du ping (3 jours), plus 24 h fixes.
create or replace function public.purge_ping()
returns void
language plpgsql security definer
set search_path = public, private
as $$
begin
  delete from public.ping_beacons
   where updated_at < now() - (private.ping_beacon_ttl() * 2);
  delete from public.ping_confirmations where created_at < now() - interval '1 hour';
  -- Une paire au-delà de sa fenêtre n'ouvre plus rien.
  delete from public.ping_pairs
   where last_seen_at < now() - private.fenetre_croisement('ping');
  -- Un croisement d'événement, pareil.
  delete from public.event_crossings
   where last_at < now() - private.fenetre_croisement('event');
end;
$$;

-- 14e. Écrire dans le groupe d'événement : en être membre suffit (la
--      conversation survit 5 jours après la fermeture, comme le groupe).
create or replace function private.can_write_in_conversation(conv_id uuid, uid uuid)
returns boolean
language sql stable security definer
set search_path = public, private
as $$
  select case
    when c.conversation_type in ('group', 'event') then true
    when exists (
      select 1 from public.conversation_members autre
      where autre.conversation_id = c.id
        and autre.user_id <> uid
        and private.is_blocked(uid, autre.user_id)
    ) then false
    when c.conversation_type <> 'proximity' then true
    else exists (
      select 1
      from public.conversation_members autre
      join public.ping_pairs pp
        on (pp.user_low = least(uid, autre.user_id)
            and pp.user_high = greatest(uid, autre.user_id))
      where autre.conversation_id = c.id
        and autre.user_id <> uid
        and pp.last_seen_at > now() - private.fenetre_canal()
    )
  end
  from public.conversations c
  where c.id = conv_id;
$$;

-- 14f. La bibliothèque d'un groupe d'événement est RETARDÉE : ses Vibes se
--      révèlent après la fermeture (voir `private.close_event`). Tant que
--      l'événement est ouvert, `reveal_at` vaut `private.jamais()`.
create or replace function public.add_vibe_to_library(
  p_id uuid, p_conversation_id uuid, p_placeholder_path text, p_sealed_path text,
  p_media_key text, p_card_type public.card_type default 'standard',
  p_front_is_video boolean default false, p_back_is_video boolean default false,
  p_saveable_by_others boolean default false, p_ephemeral boolean default false,
  p_placeholder_back_path text default null, p_sealed_back_path text default null
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
    select coalesce(e.library_reveal_at, private.jamais()) into v_reveal
    from public.events e where e.conversation_id = p_conversation_id;
    v_reveal := coalesce(v_reveal, private.jamais());
  else
    v_reveal := library_reveal_at(v_timezone);
  end if;

  insert into library_vibes (
    id, conversation_id, author_id, reveal_at,
    card_type, front_is_video, back_is_video,
    saveable_by_others, ephemeral,
    placeholder_path, sealed_path,
    placeholder_back_path, sealed_back_path
  )
  values (
    p_id, p_conversation_id, auth.uid(),
    v_reveal,
    p_card_type, p_front_is_video, p_back_is_video,
    p_saveable_by_others, p_ephemeral,
    p_placeholder_path, p_sealed_path,
    p_placeholder_back_path, p_sealed_back_path
  )
  returning * into v_vibe;

  insert into library_vibe_keys (vibe_id, media_key) values (v_vibe.id, p_media_key);

  insert into messages (conversation_id, sender_id, kind, body)
  values (p_conversation_id, auth.uid(), 'library_add', null);

  return v_vibe;
end;
$$;

-- ---------------------------------------------------------------------------
-- 15. Le temps réel — ce que l'app écoute
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table
  public.events, public.event_presences, public.event_group_members;
