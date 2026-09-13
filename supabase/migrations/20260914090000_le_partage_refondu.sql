-- ===========================================================================
-- LE PARTAGE REFONDU — ce que le serveur doit savoir (Jay, 2026-09-13/14)
-- docs/plan-refonte-partage.md
-- ===========================================================================
--
-- Deux besoins, deux objets, aucune règle d'accès existante touchée.
--
-- 1. **L'ORDRE de la liste « Groupes et amis »** — « les groupes dont
--    l'activité est la plus récente et dans lesquels l'utilisateur a le plus
--    récemment participé ; puis tous les amis et tous les groupes classés selon
--    l'interaction la plus récente ».
--
--    ⚠️ Les messages sont PURGÉS à 24 h (`neovibe_purge`). Trier sur
--    `messages` reviendrait à ne connaître qu'une journée d'activité : un
--    groupe où j'ai écrit avant-hier serait indiscernable d'un groupe où je
--    n'ai jamais écrit. **Ce qui décide de l'ordre doit survivre à la purge**
--    — d'où deux dates entretenues par un trigger, et jamais recalculées :
--
--      · `conversations.last_activity_at`   — le dernier message de qui que
--                                             ce soit (« l'interaction »)
--      · `conversation_participation`       — MON dernier message dans cette
--                                             conversation (« la participation »)
--
--    Un message = un texte, une Vibe, un vocal, une annonce de bibliothèque,
--    un repartage : tout passe par `messages`, donc tout compte. Les réactions,
--    quand elles existeront, écriront la même table.
--
-- 2. **LES DÉFAUTS PAR AMI** — « pour Léa, toujours sauvegardable ». Un
--    réglage par ami qui suit mon compte : serveur, propriétaire seul. Il ne
--    porte QUE `saveable` (décision de Jay : les limites de vues et de durée
--    sont communes à l'envoi, jamais par ami).
--
-- ---------------------------------------------------------------------------
-- Les étages (CLAUDE.md) : ces tables sont de l'ACQUISITION. Elles publient
-- des dates et un booléen ; l'ordre de la liste et le réglage retenu se
-- décident dans l'app (`recipientsProvider`, `shareDefaultsProvider`).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. L'activité des conversations
-- ---------------------------------------------------------------------------

alter table public.conversations
  add column if not exists last_activity_at timestamptz;

create table if not exists public.conversation_participation (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  last_at         timestamptz not null,
  primary key (conversation_id, user_id)
);

alter table public.conversation_participation enable row level security;

-- Je ne lis que MES lignes : « quand ai-je parlé pour la dernière fois ici ».
-- Personne n'écrit directement : le trigger s'en charge.
drop policy if exists participation_select_own on public.conversation_participation;
create policy participation_select_own
  on public.conversation_participation for select
  using (user_id = (select auth.uid()));

revoke insert, update, delete on public.conversation_participation
  from anon, authenticated;

-- ⚠️ `security definer` : le trigger tourne sous l'identité de qui envoie le
-- message, et la politique `conversations_update_group_member` ne laisse
-- modifier QUE les groupes. Sans ça, écrire dans un DM échouerait à la mise à
-- jour de `last_activity_at` — et emporterait le message avec lui.
create or replace function private.note_conversation_activity()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  update public.conversations
     set last_activity_at = greatest(coalesce(last_activity_at, new.created_at), new.created_at)
   where id = new.conversation_id;

  insert into public.conversation_participation (conversation_id, user_id, last_at)
  values (new.conversation_id, new.sender_id, new.created_at)
  on conflict (conversation_id, user_id)
    do update set last_at = greatest(conversation_participation.last_at, excluded.last_at);

  return new;
end;
$$;

drop trigger if exists messages_activity on public.messages;
create trigger messages_activity
  after insert on public.messages
  for each row execute function private.note_conversation_activity();

-- Reprise de l'existant : ce que les messages encore présents savent dire.
-- (Les 24 dernières heures au plus — au-delà, la purge est passée.)
update public.conversations c
   set last_activity_at = m.last_at
  from (select conversation_id, max(created_at) as last_at
          from public.messages group by conversation_id) m
 where m.conversation_id = c.id
   and (c.last_activity_at is null or c.last_activity_at < m.last_at);

insert into public.conversation_participation (conversation_id, user_id, last_at)
select conversation_id, sender_id, max(created_at)
  from public.messages
 group by conversation_id, sender_id
on conflict (conversation_id, user_id)
  do update set last_at = greatest(conversation_participation.last_at, excluded.last_at);

-- ---------------------------------------------------------------------------
-- 2. Les défauts par ami
-- ---------------------------------------------------------------------------

create table if not exists public.friend_share_defaults (
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  friend_id  uuid not null references public.profiles(id) on delete cascade,
  saveable   boolean not null,
  updated_at timestamptz not null default now(),
  primary key (owner_id, friend_id)
);

alter table public.friend_share_defaults enable row level security;

-- Propriétaire seul, dans les deux sens : personne d'autre ne lit ce que je
-- règle pour mes amis, et je ne peux pas régler pour le compte d'un autre.
drop policy if exists friend_share_defaults_owner on public.friend_share_defaults;
create policy friend_share_defaults_owner
  on public.friend_share_defaults for all
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));
