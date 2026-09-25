-- =============================================================================
-- L'AFFICHE DE LA SOIRÉE, SA DESCRIPTION, LES AMIS QUI Y SONT — 2026-09-25
-- =============================================================================
--
-- Jay : le radar doit présenter les soirées proches comme des cartes — une
-- AFFICHE posée par l'organisateur pour reconnaître la soirée d'un coup
-- d'œil, son nom, sa DESCRIPTION, et les AMIS qui y sont (« oui, afficher les
-- amis et quels amis »). Format 3:4. Modération dès maintenant (« oui »).
--
-- La règle vit au serveur (CLAUDE.md) :
--
-- | Qui | Ce qu'il peut |
-- |---|---|
-- | l'organisateur (`may_manage_event`), soirée EN COURS | poser / changer l'affiche et la description (`set_event_details`) |
-- | quiconque voit la soirée (`can_see_event`) | lire l'affiche COURANTE, la signaler (`report_event`) |
-- | un admin | lire une affiche sous scellé, la retirer (`admin_remove_event_poster`) |
--
-- ⚠️ **L'affiche n'est PAS chiffrée** : c'est un visuel fait pour être vu
-- par ceux qui passent — l'accès reste tenu par le serveur (coffre privé,
-- lecture réservée à qui voit la soirée). Voir une soirée : privée → ses
-- invités ; ouverte ou d'établissement → tout compte (elles sont déjà
-- listées à quiconque passe à 2 km, `nearby_events`).
--
-- ⚠️ **Les amis présents** : seuls MES amis (`are_connected`), jamais un
-- inconnu, jamais quelqu'un avec qui un blocage existe. Décision de Jay,
-- consciente de ce que ça révèle (où sont mes amis), et bornée à eux.
-- =============================================================================

-- ─── 1. Les champs ──────────────────────────────────────────────────────────

alter table public.events
  add column description text
    check (description is null or (description = btrim(description) and char_length(description) between 1 and 200)),
  add column poster_path text;

-- ─── 2. Voir une soirée, lire ses amis présents ─────────────────────────────

create function private.can_see_event(p_event uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.events e
    where e.id = p_event
      and p_uid is not null
      and case e.kind
        when 'private' then private.is_event_member(e.id, p_uid) or e.created_by = p_uid
        when 'open' then true
        when 'venue' then true
        else false
      end
  );
$$;
-- Citée par une politique de `storage` : exécutable par `authenticated`.
revoke all on function private.can_see_event(uuid, uuid) from public, anon;
grant execute on function private.can_see_event(uuid, uuid) to authenticated;

create function private.friends_present(p_event uuid, p_uid uuid)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(p.user_id order by p.joined_at), '{}')
  from public.event_presences p
  where p.event_id = p_event
    and p.left_at is null
    and p.user_id <> p_uid
    and private.are_connected(p_uid, p.user_id)
    and not private.is_blocked(p_uid, p.user_id);
$$;
revoke all on function private.friends_present(uuid, uuid) from public, anon, authenticated;

-- Gérer ET en cours : une soirée terminée ne se retouche plus.
create function private.may_manage_event_open(p_event uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_event is not null
     and private.may_manage_event(p_event, p_uid)
     and exists (select 1 from public.events e where e.id = p_event and e.closed_at is null);
$$;
revoke all on function private.may_manage_event_open(uuid, uuid) from public, anon;
grant execute on function private.may_manage_event_open(uuid, uuid) to authenticated;

-- ─── 3. Le coffre des affiches ──────────────────────────────────────────────

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('event_posters', 'event_posters', false, 3145728, array['image/jpeg']);

-- Chemin : <organisateur>/<événement>/poster_<horodatage>.jpg — chaque dépôt
-- a un nom neuf (même raison que les photos de profil : aucun cache ne peut
-- confondre deux images). Le dossier de l'événement se lit sans lever.
create function private.poster_event(p_name text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  return (storage.foldername(p_name))[2]::uuid;
exception when others then
  return null;
end;
$$;
grant execute on function private.poster_event(text) to authenticated;

create policy event_posters_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'event_posters'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and private.may_manage_event_open(private.poster_event(name), (select auth.uid()))
);

-- Lire : l'affiche COURANTE d'une soirée que je vois — pas les anciennes.
create policy event_posters_read on storage.objects for select to authenticated using (
  bucket_id = 'event_posters'
  and exists (
    select 1 from public.events e
    where e.poster_path = storage.objects.name
      and private.can_see_event(e.id, (select auth.uid()))
  )
);

create policy event_posters_delete on storage.objects for delete to authenticated using (
  bucket_id = 'event_posters'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and not private.is_held(bucket_id, name)
);

-- ─── 4. Poser l'affiche et la description ───────────────────────────────────

-- Une affiche remplacée ou retirée part au balai de son propriétaire.
create function private.oublie_l_affiche(p_path text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after)
  select 'event_posters', p_path, (storage.foldername(p_path))[1]::uuid, now() + interval '7 days'
  where p_path is not null
  on conflict (bucket_id, object_name) do nothing;
$$;
revoke all on function private.oublie_l_affiche(text) from public, anon, authenticated;

create function public.set_event_details(
  p_event uuid,
  p_description text,
  p_poster_path text,
  p_clear_poster boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_old text;
  v_desc text := nullif(btrim(coalesce(p_description, '')), '');
begin
  perform private.assert_not_suspended();
  if not private.may_manage_event_open(p_event, me) then
    raise exception 'Seul l''organisateur modifie la soirée, et pendant qu''elle a lieu';
  end if;
  if v_desc is not null and char_length(v_desc) > 200 then
    raise exception 'Description trop longue (200 caractères au plus)';
  end if;
  select poster_path into v_old from public.events where id = p_event;

  if p_poster_path is not null then
    -- L'affiche doit être celle que JE viens de déposer POUR cette soirée.
    if (storage.foldername(p_poster_path))[1] <> me::text
       or private.poster_event(p_poster_path) is distinct from p_event
       or not exists (
         select 1 from storage.objects o
         where o.bucket_id = 'event_posters' and o.name = p_poster_path
       ) then
      raise exception 'Affiche introuvable';
    end if;
  end if;

  update public.events
     set description = v_desc,
         poster_path = case
           when p_clear_poster then null
           else coalesce(p_poster_path, poster_path) end
   where id = p_event;

  if v_old is not null and (p_clear_poster or (p_poster_path is not null and p_poster_path <> v_old)) then
    perform private.oublie_l_affiche(v_old);
  end if;
end;
$$;
revoke all on function public.set_event_details(uuid, text, text, boolean) from public, anon;
grant execute on function public.set_event_details(uuid, text, text, boolean) to authenticated;

-- L'événement purgé emporte son affiche au balai.
create function private.affiche_d_un_evenement_parti()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.oublie_l_affiche(old.poster_path);
  return old;
end;
$$;
create trigger events_affiche_au_balai before delete on public.events
  for each row execute function private.affiche_d_un_evenement_parti();

-- ─── 5. Signaler une soirée ─────────────────────────────────────────────────

create table public.event_reports (
  id uuid primary key default gen_random_uuid(),
  event_id uuid references public.events(id) on delete set null,
  author_id uuid not null references public.profiles(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (reason in ('inappropriate', 'harassment', 'impersonation', 'minor', 'other')),
  details text check (details is null or char_length(details) <= 500),
  status text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id),
  unique (event_id, reporter_id)
);
alter table public.event_reports enable row level security;
create policy event_reports_select_own on public.event_reports
  for select to authenticated using (reporter_id = (select auth.uid()));

create function public.report_event(p_event uuid, p_reason text, p_details text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author uuid;
begin
  select created_by into v_author from public.events where id = p_event;
  if v_author is null or not private.can_see_event(p_event, auth.uid()) then
    raise exception 'Soirée introuvable';
  end if;
  if v_author = auth.uid() then raise exception 'On ne signale pas sa propre soirée'; end if;
  insert into public.event_reports (event_id, author_id, reporter_id, reason, details)
  values (p_event, v_author, auth.uid(), p_reason, nullif(btrim(coalesce(p_details, '')), ''))
  on conflict (event_id, reporter_id) do nothing;
end;
$$;
revoke all on function public.report_event(uuid, text, text) from public, anon;
grant execute on function public.report_event(uuid, text, text) to authenticated;

alter table public.moderation_holds drop constraint moderation_holds_report_kind_check;
alter table public.moderation_holds add constraint moderation_holds_report_kind_check
  check (report_kind in ('content', 'drop_vibe', 'sent_vibe', 'event'));
alter table public.moderation_actions drop constraint moderation_actions_report_kind_check;
alter table public.moderation_actions add constraint moderation_actions_report_kind_check
  check (report_kind = any (array['content', 'profile', 'drop_vibe', 'sent_vibe', 'event']));
alter table public.moderation_actions drop constraint moderation_actions_action_check;
alter table public.moderation_actions add constraint moderation_actions_action_check
  check (action = any (array['resolve_report', 'dismiss_report', 'suspend_user',
    'unsuspend_user', 'delete_content', 'close_event', 'view_evidence', 'remove_poster']));

-- ─── Les listes d'événements portent la description, l'affiche et les amis ─

drop function public.my_events();
drop function public.nearby_events(double precision, double precision);

CREATE FUNCTION public.my_events()
 RETURNS TABLE(id uuid, kind event_kind, title text, venue_name text, created_by uuid, conversation_id uuid, lat double precision, lon double precision, radius_m integer, starts_at timestamp with time zone, scheduled_end_at timestamp with time zone, opened_at timestamp with time zone, closed_at timestamp with time zone, members_can_add boolean, members_can_remove boolean, library_reveal_at timestamp with time zone, present_count integer, guest_count integer, i_am_present boolean, my_role event_role, i_manage boolean, description text, poster_path text, friends_present uuid[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  return query
  select e.id, e.kind, e.title, coalesce(e.place_name, v.name),
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
         (e.venue_id is not null and private.manages_venue(e.venue_id, me)),
         e.description, e.poster_path, private.friends_present(e.id, me)
  from public.events e
  left join public.venues v on v.id = e.venue_id
  where private.concerned_by_event(e.id, me)
  order by (e.closed_at is null) desc, e.starts_at desc;
end;
$function$;

CREATE FUNCTION public.nearby_events(p_lat double precision, p_lon double precision)
 RETURNS TABLE(id uuid, kind event_kind, title text, venue_name text, venue_address text, lat double precision, lon double precision, radius_m integer, starts_at timestamp with time zone, scheduled_end_at timestamp with time zone, present_count integer, distance_m integer, description text, poster_path text, friends_present uuid[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
  r public.event_rules;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into r from public.event_rules;
  return query
  select e.id, e.kind, e.title, coalesce(e.place_name, v.name), v.address, e.lat, e.lon, e.radius_m,
         e.starts_at, e.scheduled_end_at,
         -- « N personnes connectées ici » (Jay, 2026-09-21) : les présents,
         -- c'est-à-dire ceux dont la présence est prouvée en ce moment.
         (select count(*)::integer from public.event_presences p
           where p.event_id = e.id and p.left_at is null),
         round(private.meters_between(p_lat, p_lon, e.lat, e.lon))::integer,
         e.description, e.poster_path, private.friends_present(e.id, me)
  from public.events e
  left join public.venues v on v.id = e.venue_id
  where e.kind in ('venue', 'open') and e.closed_at is null and e.starts_at <= now()
    and e.lat is not null
    and private.meters_between(p_lat, p_lon, e.lat, e.lon) <= r.nearby_radius_m
    and not private.is_blocked(me, e.created_by)
  order by 12;
end;
$function$;

revoke all on function public.my_events() from public, anon;
grant execute on function public.my_events() to authenticated;
revoke all on function public.nearby_events(double precision, double precision) from public, anon;
grant execute on function public.nearby_events(double precision, double precision) to authenticated;

-- ─── Le scellé et la console : la sorte « event » ────────────────────────────

CREATE OR REPLACE FUNCTION private.scelle_la_preuve()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_kind text := case tg_table_name
    when 'library_vibe_reports' then 'drop_vibe'
    when 'card_reports' then 'sent_vibe'
    when 'event_reports' then 'event'
    else 'content' end;
begin
  if v_kind = 'event' then
    -- L'affiche, en clair (elle est faite pour être vue autour) : pas de clé.
    insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
    select v_kind, new.id, 'event_posters', e.poster_path, 0, false, null
    from public.events e
    where e.id = new.event_id and e.poster_path is not null
    on conflict do nothing;

  elsif v_kind = 'drop_vibe' then
    insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
    select v_kind, new.id, 'library_vault', f.chemin, f.rang, f.video, k.media_key
    from public.library_vibes v
    left join public.library_vibe_keys k on k.vibe_id = v.id
    cross join lateral (values
      (v.sealed_path, 0::smallint, v.front_is_video),
      (v.sealed_back_path, 1::smallint, v.back_is_video)
    ) as f(chemin, rang, video)
    where v.id = new.vibe_id and f.chemin is not null
    on conflict do nothing;

  elsif v_kind = 'sent_vibe' then
    insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
    select v_kind, new.id, 'cards', f.chemin, f.rang, f.video,
           case when c.encrypted then k.media_key end
    from public.cards c
    left join public.card_media_keys k on k.card_id = c.id
    cross join lateral (values
      (c.front_path, 0::smallint, c.front_is_video),
      (c.back_path, 1::smallint, c.back_is_video)
    ) as f(chemin, rang, video)
    where c.id = new.card_id and f.chemin is not null
    on conflict do nothing;

  else
    -- Une story…
    insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
    select v_kind, new.id, 'stories', f.chemin, f.rang, f.video,
           case when s.encrypted then k.media_key end
    from public.stories s
    left join public.content_media_keys k on k.content_id = s.id
    cross join lateral (values
      (s.front_path, 0::smallint, s.front_is_video),
      (s.back_path, 1::smallint, s.back_is_video)
    ) as f(chemin, rang, video)
    where s.id = new.content_id and f.chemin is not null
    on conflict do nothing;
    -- …ou une publication (ses diapos).
    insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
    select v_kind, new.id, 'library', m.path, m.slot, m.is_video, k.media_key
    from public.library_media m
    left join public.content_media_keys k on k.content_id = m.item_id
    where m.item_id = new.content_id and m.path is not null
    on conflict do nothing;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION private.libere_la_preuve()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_kind text := case tg_table_name
    when 'library_vibe_reports' then 'drop_vibe'
    when 'card_reports' then 'sent_vibe'
    when 'event_reports' then 'event'
    else 'content' end;
begin
  -- Tranché ou écarté (mise à jour), ou disparu (suppression) : libéré.
  if tg_op = 'DELETE' or new.status <> 'open' then
    delete from public.moderation_holds
    where report_kind = v_kind and report_id = old.id;
  end if;
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_reports(p_status text DEFAULT 'open'::text)
 RETURNS TABLE(kind text, id uuid, reason text, details text, status text, created_at timestamp with time zone, reporter_id uuid, reporter_name text, target_user uuid, target_name text, target_suspended boolean, content_id uuid, content_context text, content_owner uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
  union all
  select 'drop_vibe', r.id, r.reason, r.details, r.status, r.created_at,
         r.reporter_id, rp.display_name,
         r.author_id, ap.display_name, ap.suspended_at is not null,
         r.vibe_id, case when r.vibe_id is null then null else 'drop' end, r.author_id
  from public.library_vibe_reports r
  join public.profiles rp on rp.id = r.reporter_id
  join public.profiles ap on ap.id = r.author_id
  where p_status is null or r.status = p_status
  union all
  select 'sent_vibe', r.id, r.reason, r.details, r.status, r.created_at,
         r.reporter_id, rp.display_name,
         r.author_id, ap.display_name, ap.suspended_at is not null,
         r.card_id, case when r.card_id is null then null else 'envoyée' end, r.author_id
  from public.card_reports r
  join public.profiles rp on rp.id = r.reporter_id
  join public.profiles ap on ap.id = r.author_id
  where p_status is null or r.status = p_status
  union all
  select 'event', r.id, r.reason, r.details, r.status, r.created_at,
         r.reporter_id, rp.display_name,
         r.author_id, ap.display_name, ap.suspended_at is not null,
         r.event_id, case when r.event_id is null then null else 'événement' end, r.author_id
  from public.event_reports r
  join public.profiles rp on rp.id = r.reporter_id
  join public.profiles ap on ap.id = r.author_id
  where p_status is null or r.status = p_status
  order by 6 desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_resolve_report(p_kind text, p_report uuid, p_dismiss boolean DEFAULT false, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
  elsif p_kind = 'drop_vibe' then
    update public.library_vibe_reports set status = st, resolved_at = now(), resolved_by = me
     where id = p_report returning author_id into u;
  elsif p_kind = 'sent_vibe' then
    update public.card_reports set status = st, resolved_at = now(), resolved_by = me
     where id = p_report returning author_id into u;
  elsif p_kind = 'event' then
    update public.event_reports set status = st, resolved_at = now(), resolved_by = me
     where id = p_report returning author_id into u;
  else
    raise exception 'kind : content, profile, drop_vibe, sent_vibe ou event';
  end if;
  if not found then raise exception 'Signalement introuvable'; end if;
  perform private.log_action(me, case when p_dismiss then 'dismiss_report' else 'resolve_report' end,
                             u, c, null, p_kind, p_report, p_note);
end;
$function$;

create trigger event_reports_scelle after insert on public.event_reports
  for each row execute function private.scelle_la_preuve();
create trigger event_reports_libere after update of status or delete on public.event_reports
  for each row execute function private.libere_la_preuve();

-- ─── 6. La modération retire une affiche ────────────────────────────────────

create function public.admin_remove_event_poster(p_event uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  me uuid := private.assert_admin();
  v_old text;
begin
  select poster_path into v_old from public.events where id = p_event;
  if not found then raise exception 'Soirée introuvable'; end if;
  -- L'affiche ET la description : c'est le « profil » public de la soirée.
  update public.events set poster_path = null, description = null where id = p_event;
  perform private.oublie_l_affiche(v_old);
  perform private.log_action(me, 'remove_poster', null, null, p_event, null, null, p_reason);
end;
$$;
revoke all on function public.admin_remove_event_poster(uuid, text) from public, anon;
grant execute on function public.admin_remove_event_poster(uuid, text) to authenticated;
