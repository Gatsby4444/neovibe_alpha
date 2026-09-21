-- ===========================================================================
-- L'ADMINISTRATION ET LA MODÉRATION — les fondations (2026-09-21)
--
-- Jay, 2026-09-21 : « il faudra de la modération sur l'app, et on
-- construira toute une plateforme d'administration complète avant la
-- première release de production » (RAPPELS #156).
--
-- Ce que cette migration pose — et rien de plus :
--
--   1. QUI est administrateur : la table `admins`. Aucun client ne l'écrit ;
--      on y entre par SQL, à la main (le premier admin est Jay).
--   2. LE JOURNAL : `moderation_actions` — chaque geste d'un admin, daté,
--      signé, motivé. Rien ne se fait sans ligne ici.
--   3. LES SIGNALEMENTS ont un état (`open` / `resolved` / `dismissed`),
--      un traitant et une date.
--   4. LA SUSPENSION d'un compte : `profiles.suspended_at`. Dite
--      positivement à chaque porte qui crée du contenu ou une soirée :
--      `private.assert_not_suspended()` — une porte qui ne l'appelle pas
--      laisse passer ; la liste des portes est dans docs/administration.md.
--   5. LES RPC d'administration : lire les signalements, trancher, suspendre
--      / rétablir, retirer un contenu, voir les événements ouverts, des
--      compteurs. Toutes `security definer`, toutes refusent un non-admin.
--
-- La console (web, `lib/admin/`) ne connaît que ces RPC.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Les administrateurs
-- ---------------------------------------------------------------------------

create table if not exists public.admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by uuid references public.profiles(id),
  note text
);

alter table public.admins enable row level security;

create or replace function private.is_admin(p_uid uuid)
returns boolean
language sql stable security definer
set search_path = public, private
as $$
  select exists (select 1 from public.admins a where a.user_id = p_uid);
$$;

-- Un admin voit la liste des admins ; personne n'y écrit par l'API.
drop policy if exists "admins_read_by_admins" on public.admins;
create policy "admins_read_by_admins" on public.admins
  for select to authenticated using (private.is_admin(auth.uid()));

create or replace function private.assert_admin()
returns uuid
language plpgsql stable security definer
set search_path = public, private
as $$
declare me uuid := auth.uid();
begin
  if me is null or not private.is_admin(me) then
    raise exception 'Réservé à l''administration';
  end if;
  return me;
end;
$$;

-- Ce que l'app demande au démarrage : « suis-je admin ? » (la console
-- n'affiche rien à quelqu'un qui ne l'est pas).
create or replace function public.am_i_admin()
returns boolean
language sql stable security definer
set search_path = public, private
as $$ select private.is_admin(auth.uid()); $$;

revoke all on function public.am_i_admin() from public;
grant execute on function public.am_i_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Le journal
-- ---------------------------------------------------------------------------

create table if not exists public.moderation_actions (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references public.profiles(id),
  action text not null check (action in (
    'resolve_report', 'dismiss_report', 'suspend_user', 'unsuspend_user',
    'delete_content', 'close_event'
  )),
  target_user uuid,
  target_content uuid,
  target_event uuid,
  report_kind text check (report_kind in ('content', 'profile')),
  report_id uuid,
  reason text,
  created_at timestamptz not null default now()
);

create index if not exists moderation_actions_recent on public.moderation_actions (created_at desc);

alter table public.moderation_actions enable row level security;

drop policy if exists "moderation_actions_read_by_admins" on public.moderation_actions;
create policy "moderation_actions_read_by_admins" on public.moderation_actions
  for select to authenticated using (private.is_admin(auth.uid()));

create or replace function private.log_action(
  p_admin uuid, p_action text, p_user uuid, p_content uuid, p_event uuid,
  p_report_kind text, p_report uuid, p_reason text
) returns void
language sql security definer
set search_path = public, private
as $$
  insert into public.moderation_actions
    (admin_id, action, target_user, target_content, target_event, report_kind, report_id, reason)
  values (p_admin, p_action, p_user, p_content, p_event, p_report_kind, p_report, p_reason);
$$;

-- ---------------------------------------------------------------------------
-- 3. Les signalements ont un état
-- ---------------------------------------------------------------------------

alter table public.content_reports
  add column if not exists status text not null default 'open'
    check (status in ('open', 'resolved', 'dismissed')),
  add column if not exists resolved_at timestamptz,
  add column if not exists resolved_by uuid references public.profiles(id);

alter table public.profile_reports
  add column if not exists status text not null default 'open'
    check (status in ('open', 'resolved', 'dismissed')),
  add column if not exists resolved_at timestamptz,
  add column if not exists resolved_by uuid references public.profiles(id);

-- ---------------------------------------------------------------------------
-- 4. La suspension
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists suspended_at timestamptz,
  add column if not exists suspended_reason text;

comment on column public.profiles.suspended_at is
  'Compte suspendu par l''administration (2026-09-21). Les portes qui créent du contenu ou une soirée appellent private.assert_not_suspended().';

create or replace function private.assert_not_suspended()
returns void
language plpgsql stable security definer
set search_path = public, private
as $$
declare me uuid := auth.uid();
begin
  if me is not null and exists (
    select 1 from public.profiles p where p.id = me and p.suspended_at is not null
  ) then
    raise exception 'Ton compte est suspendu';
  end if;
end;
$$;

-- Ce que l'app lit au démarrage pour afficher l'écran de suspension.
create or replace function public.my_suspension()
returns table (suspended_at timestamptz, reason text)
language sql stable security definer
set search_path = public, private
as $$
  select p.suspended_at, p.suspended_reason from public.profiles p
  where p.id = auth.uid() and p.suspended_at is not null;
$$;

revoke all on function public.my_suspension() from public;
grant execute on function public.my_suspension() to authenticated;

-- Les portes. ⚠️ Liste tenue dans docs/administration.md : toute nouvelle
-- porte qui crée du contenu ou une soirée s'y ajoute.
-- (Chaque fonction est réécrite à l'identique avec l'appel en tête ; pour
-- ne pas dupliquer des corps entiers, on passe par un « wrapper » :
-- l'original est renommé, le nom public appelle l'assertion puis l'original.)

do $$
declare
  f record;
begin
  for f in
    select p.proname, p.oid, pg_get_function_identity_arguments(p.oid) as ident,
           pg_get_function_arguments(p.oid) as args, pg_get_function_result(p.oid) as res
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'publish_to_library', 'publish_story', 'add_vibe_to_library',
      'create_open_event', 'create_private_event', 'post_challenge',
      'add_to_feed', 'send_message'
    )
  loop
    -- Un wrapper déjà posé (migration rejouée) : on ne l'enveloppe pas deux fois.
    if exists (select 1 from pg_proc q join pg_namespace m on m.oid = q.pronamespace
               where m.nspname = 'private' and q.proname = 'unguarded_' || f.proname) then
      continue;
    end if;
    execute format('alter function public.%I(%s) rename to %I',
                   f.proname, f.ident, 'unguarded_' || f.proname);
    execute format('alter function public.%I(%s) set schema private',
                   'unguarded_' || f.proname, f.ident);
    execute format(
      'create function public.%I(%s) returns %s language plpgsql security definer set search_path = public, private as $w$ begin perform private.assert_not_suspended(); return private.%I(%s); end; $w$',
      f.proname, f.args, f.res, 'unguarded_' || f.proname,
      (select string_agg(a, ', ') from unnest(regexp_split_to_array(f.ident, ',\s*')) as a0(a0)
         cross join lateral (select split_part(btrim(a0), ' ', 1)) as x(a))
    );
    execute format('revoke all on function public.%I(%s) from public', f.proname, f.ident);
    execute format('grant execute on function public.%I(%s) to authenticated', f.proname, f.ident);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Les RPC d'administration
-- ---------------------------------------------------------------------------

create or replace function public.admin_stats()
returns table (
  users integer, suspended integer, open_reports integer,
  open_events integer, contents integer, actions_24h integer
)
language plpgsql stable security definer
set search_path = public, private
as $$
begin
  perform private.assert_admin();
  return query select
    (select count(*)::integer from public.profiles),
    (select count(*)::integer from public.profiles where suspended_at is not null),
    (select count(*)::integer from public.content_reports where status = 'open')
      + (select count(*)::integer from public.profile_reports where status = 'open'),
    (select count(*)::integer from public.events where closed_at is null),
    (select count(*)::integer from public.contents),
    (select count(*)::integer from public.moderation_actions where created_at > now() - interval '24 hours');
end;
$$;

create or replace function public.admin_reports(p_status text default 'open')
returns table (
  kind text, id uuid, reason text, details text, status text, created_at timestamptz,
  reporter_id uuid, reporter_name text,
  target_user uuid, target_name text, target_suspended boolean,
  content_id uuid, content_context text, content_owner uuid
)
language plpgsql stable security definer
set search_path = public, private
as $$
begin
  perform private.assert_admin();
  return query
  select 'content', r.id, r.reason, r.details, r.status, r.created_at,
         r.reporter_id, rp.display_name,
         c.owner_id, op.display_name, op.suspended_at is not null,
         r.content_id, c.context::text, c.owner_id
  from public.content_reports r
  join public.profiles rp on rp.id = r.reporter_id
  left join public.contents c on c.id = r.content_id
  left join public.profiles op on op.id = c.owner_id
  where p_status is null or r.status = p_status
  union all
  select 'profile', r.id, r.reason, r.details, r.status, r.created_at,
         r.reporter_id, rp.display_name,
         r.target_id, tp.display_name, tp.suspended_at is not null,
         null, null, null
  from public.profile_reports r
  join public.profiles rp on rp.id = r.reporter_id
  join public.profiles tp on tp.id = r.target_id
  where p_status is null or r.status = p_status
  order by 6 desc;
end;
$$;

create or replace function public.admin_resolve_report(
  p_kind text, p_report uuid, p_dismiss boolean default false, p_note text default null
) returns void
language plpgsql security definer
set search_path = public, private
as $$
declare
  me uuid := private.assert_admin();
  st text := case when p_dismiss then 'dismissed' else 'resolved' end;
  u uuid; c uuid;
begin
  if p_kind = 'content' then
    update public.content_reports set status = st, resolved_at = now(), resolved_by = me
     where id = p_report returning content_id into c;
  elsif p_kind = 'profile' then
    update public.profile_reports set status = st, resolved_at = now(), resolved_by = me
     where id = p_report returning target_id into u;
  else
    raise exception 'kind : content ou profile';
  end if;
  if not found then raise exception 'Signalement introuvable'; end if;
  perform private.log_action(me, case when p_dismiss then 'dismiss_report' else 'resolve_report' end,
                             u, c, null, p_kind, p_report, p_note);
end;
$$;

create or replace function public.admin_suspend_user(p_user uuid, p_reason text)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare me uuid := private.assert_admin();
begin
  if p_user = me then raise exception 'On ne se suspend pas soi-même'; end if;
  if private.is_admin(p_user) then raise exception 'Un administrateur se retire d''abord de la liste'; end if;
  update public.profiles set suspended_at = now(), suspended_reason = p_reason where id = p_user;
  if not found then raise exception 'Compte introuvable'; end if;
  -- Sorti de tout événement en cours.
  update public.event_presences set left_at = now(), left_reason = 'manual'
   where user_id = p_user and left_at is null;
  perform private.log_action(me, 'suspend_user', p_user, null, null, null, null, p_reason);
end;
$$;

create or replace function public.admin_unsuspend_user(p_user uuid, p_note text default null)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare me uuid := private.assert_admin();
begin
  update public.profiles set suspended_at = null, suspended_reason = null where id = p_user;
  if not found then raise exception 'Compte introuvable'; end if;
  perform private.log_action(me, 'unsuspend_user', p_user, null, null, null, null, p_note);
end;
$$;

-- Retirer un contenu (publication, story) : la ligne `contents` part, et
-- tout ce qui en dépend (médias → tombstones, likes, ajouts au feed) avec.
-- Les copies locales chez les gens sont révoquées par `purgeRevoked`
-- côté app (l'identifiant ne répond plus).
create or replace function public.admin_delete_content(p_content uuid, p_reason text)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare me uuid := private.assert_admin(); o uuid;
begin
  select owner_id into o from public.contents where id = p_content;
  if o is null then raise exception 'Contenu introuvable'; end if;
  delete from public.contents where id = p_content;
  update public.content_reports set status = 'resolved', resolved_at = now(), resolved_by = me
   where content_id = p_content and status = 'open';
  perform private.log_action(me, 'delete_content', o, p_content, null, null, null, p_reason);
end;
$$;

create or replace function public.admin_events()
returns table (
  id uuid, kind public.event_kind, title text, auto_created boolean,
  created_by uuid, creator_name text, opened_at timestamptz, scheduled_end_at timestamptz,
  present_count integer, vibe_count integer
)
language plpgsql stable security definer
set search_path = public, private
as $$
begin
  perform private.assert_admin();
  return query
  select e.id, e.kind, e.title, e.auto_created, e.created_by, p.display_name,
         e.opened_at, e.scheduled_end_at,
         (select count(*)::integer from public.event_presences x where x.event_id = e.id and x.left_at is null),
         (select count(*)::integer from public.library_vibes v where v.conversation_id = e.conversation_id)
  from public.events e
  left join public.profiles p on p.id = e.created_by
  where e.closed_at is null
  order by e.opened_at desc nulls last;
end;
$$;

create or replace function public.admin_close_event(p_event uuid, p_reason text)
returns void
language plpgsql security definer
set search_path = public, private
as $$
declare me uuid := private.assert_admin();
begin
  perform private.close_event(p_event, 'admin');
  perform private.log_action(me, 'close_event', null, null, p_event, null, null, p_reason);
end;
$$;

create or replace function public.admin_actions(p_limit integer default 100)
returns table (
  id uuid, admin_name text, action text, target_user uuid, target_name text,
  target_content uuid, target_event uuid, reason text, created_at timestamptz
)
language plpgsql stable security definer
set search_path = public, private
as $$
begin
  perform private.assert_admin();
  return query
  select a.id, ap.display_name, a.action, a.target_user, tp.display_name,
         a.target_content, a.target_event, a.reason, a.created_at
  from public.moderation_actions a
  join public.profiles ap on ap.id = a.admin_id
  left join public.profiles tp on tp.id = a.target_user
  order by a.created_at desc
  limit greatest(1, least(p_limit, 500));
end;
$$;

create or replace function public.admin_users(p_query text default null, p_limit integer default 50)
returns table (
  id uuid, display_name text, tag_name text, created_at timestamptz,
  suspended_at timestamptz, suspended_reason text, reports integer, is_admin boolean
)
language plpgsql stable security definer
set search_path = public, private
as $$
begin
  perform private.assert_admin();
  return query
  select p.id, p.display_name, p.tag_name, p.created_at, p.suspended_at, p.suspended_reason,
         (select count(*)::integer from public.profile_reports r where r.target_id = p.id),
         private.is_admin(p.id)
  from public.profiles p
  where p_query is null or p.display_name ilike '%' || p_query || '%' or p.tag_name ilike '%' || p_query || '%'
  order by p.created_at desc
  limit greatest(1, least(p_limit, 500));
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_stats()', 'admin_reports(text)', 'admin_resolve_report(text, uuid, boolean, text)',
    'admin_suspend_user(uuid, text)', 'admin_unsuspend_user(uuid, text)',
    'admin_delete_content(uuid, text)', 'admin_events()', 'admin_close_event(uuid, text)',
    'admin_actions(integer)', 'admin_users(text, integer)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
