-- Étape 4 — signalement et blocage (le socle de modération).
--
-- Point signalé comme **bloquant** le 2026-08-11, avant l'ouverture de la
-- propagation hors cercle : tant qu'un contenu reste entre amis, le cercle
-- social fait la modération. Dès qu'il peut atteindre un inconnu à plusieurs
-- sauts, ça ne se défend plus. La propagation est en production depuis la
-- v0.9.47 ; ceci comble le trou.
--
-- Jay : « on fera le chantier de modération de manière centralisée et plus
-- tard, mais si tu veux le préparer tu peux. » C'est donc le SOCLE — les
-- tables, les règles et les points d'entrée utilisateur — pas l'outil
-- d'administration.

-- ───────────────────────── 1. Le blocage ─────────────────────────
--
-- Un blocage est DIRIGÉ (je bloque quelqu'un) mais ses effets sont
-- RÉCIPROQUES : aucun des deux ne voit plus le contenu de l'autre. Un blocage
-- à sens unique laisserait le bloqueur continuer de consulter celui qu'il
-- fuit, ce qui n'a aucun sens.
create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocks_not_self check (blocker_id <> blocked_id)
);

create index blocks_blocked_idx on public.blocks (blocked_id);

alter table public.blocks enable row level security;

-- Je vois et gère MES blocages. Personne ne sait qu'il est bloqué : c'est le
-- propre d'un blocage utile.
create policy blocks_select_own on public.blocks
  for select using (blocker_id = (select auth.uid()));

create policy blocks_insert_own on public.blocks
  for insert with check (blocker_id = (select auth.uid()));

create policy blocks_delete_own on public.blocks
  for delete using (blocker_id = (select auth.uid()));

create or replace function private.is_blocked(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

-- Citée par des politiques : DOIT être exécutable par `authenticated`
-- (leçon du 2026-08-11, inscrite dans CLAUDE.md).
grant execute on function private.is_blocked(uuid, uuid) to authenticated;

-- ───────────────────────── 2. Le signalement ─────────────────────────
--
-- DEUX tables, pas une avec un discriminant : un contenu et une personne ne se
-- signalent pas pour les mêmes motifs et n'appellent pas la même suite. Une
-- table unique avec des colonnes nullables serait exactement le mélange que
-- l'architecture du projet refuse.
--
-- ⚠️ Portée : les contenus du SOCLE (stories, publications). Une Vibe envoyée
-- en chat n'a pas de Content ID — elle se signale par le profil de son
-- expéditeur, et rejoindra le socle le jour où `cards` y migrera.
create table public.content_reports (
  id uuid primary key default gen_random_uuid(),
  content_id uuid not null references public.contents (id) on delete cascade,
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reason text not null,
  details text,
  created_at timestamptz not null default now(),
  unique (content_id, reporter_id)
);

create index content_reports_pending_idx
  on public.content_reports (created_at desc);

alter table public.content_reports enable row level security;

-- On signale ce qu'on peut voir, et on ne lit que ses propres signalements :
-- personne ne doit pouvoir mesurer combien de fois un contenu a été signalé.
create policy content_reports_insert on public.content_reports
  for insert with check (
    reporter_id = (select auth.uid())
    and private.content_audience(content_id, (select auth.uid()))
  );

create policy content_reports_select_own on public.content_reports
  for select using (reporter_id = (select auth.uid()));

create table public.profile_reports (
  id uuid primary key default gen_random_uuid(),
  target_id uuid not null references public.profiles (id) on delete cascade,
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reason text not null,
  details text,
  created_at timestamptz not null default now(),
  unique (target_id, reporter_id),
  constraint profile_reports_not_self check (target_id <> reporter_id)
);

alter table public.profile_reports enable row level security;

create policy profile_reports_insert on public.profile_reports
  for insert with check (reporter_id = (select auth.uid()));

create policy profile_reports_select_own on public.profile_reports
  for select using (reporter_id = (select auth.uid()));

-- ───────────────────────── 3. Le blocage MORD ─────────────────────────
--
-- Un blocage qui ne coupe rien n'est qu'un réglage décoratif. On l'insère donc
-- dans l'unique porte d'accès au contenu du socle : `content_audience`.
-- Une seule ligne, et le blocage vaut pour les stories, les publications, les
-- fichiers, les clés, le repartage et les statistiques — tout ce qui passe par
-- cette fonction.
create or replace function private.content_audience(p_content_id uuid, p_uid uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = 'public', 'private'
as $$
declare
  v_context public.content_context;
  v_owner uuid;
begin
  select context, owner_id into v_context, v_owner
  from contents where id = p_content_id;
  if not found then
    return false;
  end if;

  -- Le blocage prime sur TOUT le reste, y compris un repartage déjà reçu.
  if private.is_blocked(v_owner, p_uid) then
    return false;
  end if;

  return case v_context
    when 'story' then private.story_audience(p_content_id, p_uid)
    when 'publication' then private.publication_audience(p_content_id, p_uid)
    else false
  end;
end;
$$;

grant execute on function private.content_audience(uuid, uuid) to authenticated;
