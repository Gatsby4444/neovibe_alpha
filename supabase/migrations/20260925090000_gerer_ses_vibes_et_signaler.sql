-- =============================================================================
-- GÉRER SES VIBES, CACHER, SIGNALER — 2026-09-25
-- =============================================================================
--
-- Consigne de Jay : sur une Vibe du **Drop** comme sur une Vibe **envoyée**,
-- - son auteur peut **modifier ses réglages** et la **supprimer** (pour tout le
--   monde) ;
-- - l'**organisateur** d'une soirée peut aussi supprimer une Vibe de son Drop ;
-- - les autres peuvent la **cacher pour eux** (« Supprimer pour moi ») et la
--   **signaler** (formulaire simple).
--
-- ⚠️ Ce que chaque geste touche, et seulement ça (règle 2 de `CLAUDE.md`) :
--
-- | Geste | Objet | Effet |
-- |---|---|---|
-- | supprimer (Drop) | `library_vibes` | la ligne part ; ses octets vont au balai (`library_vibes_octets_a_supprimer`) |
-- | supprimer (envoyée) | `cards` + ses `messages` | le container disparaît du chat de tous ; octets au balai (`cards_octets_a_supprimer`) |
-- | cacher (Drop) | `library_vibe_hidden` | la Vibe n'est plus lisible par MOI (politique de lecture) |
-- | cacher (envoyée) | `hidden_messages` | le container n'est plus lisible par MOI — un message, pas la Vibe : le même contenu envoyé ailleurs reste où il est |
-- | signaler | `library_vibe_reports` / `card_reports` | une ligne pour la modération |
--
-- ⚠️ **Cacher = une règle de lecture, pas un filtre d'écran.** Posée dans la
-- politique RLS, elle vaut pour tous les chemins : la grille du Drop, son flux
-- en direct, l'écran de soirée, le générique de fin, le chat.
--
-- ⚠️ **Un signalement survit à la suppression de ce qu'il vise** : la clé
-- étrangère passe à NULL (jamais `cascade`) et l'auteur est recopié dans la
-- ligne. Sans ça, supprimer sa Vibe effacerait la plainte contre elle.
-- =============================================================================

-- ─── 1. Cacher ───────────────────────────────────────────────────────────────

create table public.library_vibe_hidden (
  user_id uuid not null references public.profiles(id) on delete cascade,
  vibe_id uuid not null references public.library_vibes(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, vibe_id)
);
alter table public.library_vibe_hidden enable row level security;
create policy library_vibe_hidden_select_own on public.library_vibe_hidden
  for select to authenticated using (user_id = (select auth.uid()));

create table public.hidden_messages (
  user_id uuid not null references public.profiles(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, message_id)
);
create index hidden_messages_message_idx on public.hidden_messages (message_id);
alter table public.hidden_messages enable row level security;
create policy hidden_messages_select_own on public.hidden_messages
  for select to authenticated using (user_id = (select auth.uid()));

-- La lecture du Drop : membre, et pas cachée par moi.
drop policy library_vibes_select on public.library_vibes;
create policy library_vibes_select on public.library_vibes
  for select using (
    exists (
      select 1 from public.conversation_members m
      where m.conversation_id = library_vibes.conversation_id
        and m.user_id = auth.uid()
    )
    and not exists (
      select 1 from public.library_vibe_hidden h
      where h.vibe_id = library_vibes.id and h.user_id = auth.uid()
    )
  );

-- La lecture du chat : la règle d'hier, et pas caché par moi.
drop policy messages_select_member_unexpired on public.messages;
create policy messages_select_member_unexpired on public.messages
  for select using (
    private.is_conversation_member(conversation_id, (select auth.uid()))
    and expires_at > now()
    and created_at >= (
      select m.joined_at from public.conversation_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = (select auth.uid())
    )
    and not exists (
      select 1 from public.hidden_messages h
      where h.message_id = messages.id and h.user_id = (select auth.uid())
    )
  );

create function public.hide_drop_vibe(p_vibe_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.library_vibes v
    join public.conversation_members m
      on m.conversation_id = v.conversation_id and m.user_id = auth.uid()
    where v.id = p_vibe_id
  ) then
    raise exception 'Vibe introuvable';
  end if;
  insert into public.library_vibe_hidden (user_id, vibe_id)
  values (auth.uid(), p_vibe_id) on conflict do nothing;
end;
$$;

create function public.hide_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.messages g
    where g.id = p_message_id
      and private.is_conversation_member(g.conversation_id, auth.uid())
  ) then
    raise exception 'Message introuvable';
  end if;
  insert into public.hidden_messages (user_id, message_id)
  values (auth.uid(), p_message_id) on conflict do nothing;
end;
$$;

-- ─── 2. Modifier et supprimer — Drop ────────────────────────────────────────

-- L'organisateur d'un Drop : celui qui a créé l'événement de cette
-- conversation, ou le lieu qui l'accueille. Aucun pour un Drop de groupe.
create function private.is_drop_organizer(p_conversation_id uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.events e
    left join public.venues v on v.id = e.venue_id
    where e.conversation_id = p_conversation_id
      and (e.created_by = p_user or v.created_by = p_user)
  );
$$;

create function public.delete_drop_vibe(p_vibe_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.library_vibes;
begin
  select * into v from public.library_vibes where id = p_vibe_id;
  if not found then raise exception 'Vibe introuvable'; end if;
  if v.author_id <> auth.uid()
     and not private.is_drop_organizer(v.conversation_id, auth.uid()) then
    raise exception 'Seul son auteur ou l''organisateur peut supprimer cette Vibe';
  end if;
  delete from public.library_vibes where id = p_vibe_id;
end;
$$;

create function public.update_drop_vibe(
  p_vibe_id uuid,
  p_title text,
  p_saveable_by_others boolean,
  p_ephemeral boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
begin
  perform private.assert_not_suspended();
  if v_title is not null and char_length(v_title) > 60 then
    raise exception 'Titre trop long (60 caractères au plus)';
  end if;
  update public.library_vibes
     set title = v_title,
         saveable_by_others = coalesce(p_saveable_by_others, saveable_by_others),
         ephemeral = coalesce(p_ephemeral, ephemeral)
   where id = p_vibe_id and author_id = auth.uid();
  if not found then raise exception 'Seul son auteur peut modifier cette Vibe'; end if;
end;
$$;

-- ─── 3. Modifier et supprimer — Vibe envoyée ────────────────────────────────

create function public.delete_sent_vibe(p_card_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.cards where id = p_card_id and owner_id = auth.uid()
  ) then
    raise exception 'Seul son auteur peut supprimer cette Vibe';
  end if;
  -- Les containers d'abord : sans eux, la clé étrangère les laisserait
  -- vides (« Vibe expirée ») dans le chat de chacun.
  delete from public.messages where card_id = p_card_id;
  delete from public.cards where id = p_card_id;
end;
$$;

-- Les mêmes bornes qu'à l'envoi (contraintes de `cards`) ; un Oneshot n'a
-- jamais de durée (Jay, 2026-09-14) ; une 1/1 ne se sauvegarde pas.
create function public.update_sent_vibe(
  p_card_id uuid,
  p_max_views integer,
  p_view_duration_seconds integer,
  p_scrubbable boolean,
  p_saveable boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.cards;
begin
  perform private.assert_not_suspended();
  select * into c from public.cards where id = p_card_id and owner_id = auth.uid();
  if not found then raise exception 'Seul son auteur peut modifier cette Vibe'; end if;
  update public.cards
     set max_views = p_max_views,
         view_duration_seconds = case
           when c.card_type = 'oneshot' then null else p_view_duration_seconds end,
         scrubbable = coalesce(p_scrubbable, false),
         saveable = c.card_type <> 'one_of_one' and coalesce(p_saveable, false)
   where id = p_card_id;
end;
$$;

-- ─── 4. Signaler ─────────────────────────────────────────────────────────────

create table public.library_vibe_reports (
  id uuid primary key default gen_random_uuid(),
  vibe_id uuid references public.library_vibes(id) on delete set null,
  conversation_id uuid references public.conversations(id) on delete set null,
  author_id uuid not null references public.profiles(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (reason in ('inappropriate', 'harassment', 'impersonation', 'minor', 'other')),
  details text check (details is null or char_length(details) <= 500),
  status text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id),
  unique (vibe_id, reporter_id)
);
alter table public.library_vibe_reports enable row level security;
create policy library_vibe_reports_select_own on public.library_vibe_reports
  for select to authenticated using (reporter_id = (select auth.uid()));

create table public.card_reports (
  id uuid primary key default gen_random_uuid(),
  card_id uuid references public.cards(id) on delete set null,
  author_id uuid not null references public.profiles(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (reason in ('inappropriate', 'harassment', 'impersonation', 'minor', 'other')),
  details text check (details is null or char_length(details) <= 500),
  status text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id),
  unique (card_id, reporter_id)
);
alter table public.card_reports enable row level security;
create policy card_reports_select_own on public.card_reports
  for select to authenticated using (reporter_id = (select auth.uid()));

-- On ne signale que ce qu'on peut voir, et jamais soi-même. L'auteur est
-- relevé ICI, jamais reçu de l'app.
create function public.report_drop_vibe(p_vibe_id uuid, p_reason text, p_details text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.library_vibes;
begin
  select * into v from public.library_vibes where id = p_vibe_id;
  if not found or not exists (
    select 1 from public.conversation_members m
    where m.conversation_id = v.conversation_id and m.user_id = auth.uid()
  ) then
    raise exception 'Vibe introuvable';
  end if;
  if v.author_id = auth.uid() then raise exception 'On ne signale pas sa propre Vibe'; end if;
  insert into public.library_vibe_reports (vibe_id, conversation_id, author_id, reporter_id, reason, details)
  values (p_vibe_id, v.conversation_id, v.author_id, auth.uid(), p_reason, nullif(btrim(coalesce(p_details, '')), ''))
  on conflict (vibe_id, reporter_id) do nothing;
end;
$$;

create function public.report_sent_vibe(p_card_id uuid, p_reason text, p_details text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.cards;
begin
  select * into c from public.cards where id = p_card_id;
  if not found or not private.has_card_delivery_any(p_card_id, auth.uid()) then
    raise exception 'Vibe introuvable';
  end if;
  if c.owner_id = auth.uid() then raise exception 'On ne signale pas sa propre Vibe'; end if;
  insert into public.card_reports (card_id, author_id, reporter_id, reason, details)
  values (p_card_id, c.owner_id, auth.uid(), p_reason, nullif(btrim(coalesce(p_details, '')), ''))
  on conflict (card_id, reporter_id) do nothing;
end;
$$;

-- ─── 5. La console : deux sortes de plus ─────────────────────────────────────

create or replace function public.admin_reports(p_status text default 'open')
returns table (
  kind text, id uuid, reason text, details text, status text,
  created_at timestamptz, reporter_id uuid, reporter_name text,
  target_user uuid, target_name text, target_suspended boolean,
  content_id uuid, content_context text, content_owner uuid
)
language plpgsql
security definer
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
  order by 6 desc;
end;
$$;

create or replace function public.admin_resolve_report(
  p_kind text, p_report uuid, p_dismiss boolean default false, p_note text default null
)
returns void
language plpgsql
security definer
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
  elsif p_kind = 'drop_vibe' then
    update public.library_vibe_reports set status = st, resolved_at = now(), resolved_by = me
     where id = p_report returning author_id into u;
  elsif p_kind = 'sent_vibe' then
    update public.card_reports set status = st, resolved_at = now(), resolved_by = me
     where id = p_report returning author_id into u;
  else
    raise exception 'kind : content, profile, drop_vibe ou sent_vibe';
  end if;
  if not found then raise exception 'Signalement introuvable'; end if;
  perform private.log_action(me, case when p_dismiss then 'dismiss_report' else 'resolve_report' end,
                             u, c, null, p_kind, p_report, p_note);
end;
$$;

-- ─── 6. Droits : les portes publiques, aux comptes connectés seulement ──────

revoke all on function public.hide_drop_vibe(uuid) from public, anon;
revoke all on function public.hide_message(uuid) from public, anon;
revoke all on function public.delete_drop_vibe(uuid) from public, anon;
revoke all on function public.update_drop_vibe(uuid, text, boolean, boolean) from public, anon;
revoke all on function public.delete_sent_vibe(uuid) from public, anon;
revoke all on function public.update_sent_vibe(uuid, integer, integer, boolean, boolean) from public, anon;
revoke all on function public.report_drop_vibe(uuid, text, text) from public, anon;
revoke all on function public.report_sent_vibe(uuid, text, text) from public, anon;
grant execute on function public.hide_drop_vibe(uuid) to authenticated;
grant execute on function public.hide_message(uuid) to authenticated;
grant execute on function public.delete_drop_vibe(uuid) to authenticated;
grant execute on function public.update_drop_vibe(uuid, text, boolean, boolean) to authenticated;
grant execute on function public.delete_sent_vibe(uuid) to authenticated;
grant execute on function public.update_sent_vibe(uuid, integer, integer, boolean, boolean) to authenticated;
grant execute on function public.report_drop_vibe(uuid, text, text) to authenticated;
grant execute on function public.report_sent_vibe(uuid, text, text) to authenticated;
-- Citée par aucune politique : pas besoin d'`authenticated` (piège du
-- 2026-08-11, voir `CLAUDE.md`) — seules les fonctions ci-dessus l'appellent.
revoke all on function private.is_drop_organizer(uuid, uuid) from public, anon, authenticated;
