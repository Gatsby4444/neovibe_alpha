-- Étape 2 de la refonte « 1 contenu = 1 format » : la PUBLICATION devient un
-- objet autonome (2026-08-11).
--
-- AVANT : `library_items` mélangeait deux natures. Les publications issues de
-- la caméra n'étaient qu'une ligne pointant vers une Card (`card_id`), avec
-- leurs fichiers dans le bucket `cards` — donc soumis à `can_view_card_file`
-- et à ses règles de livraison ; les photos importées, elles, vivaient en
-- clair dans le bucket `library`. Deux régimes dans une seule table.
--
-- APRÈS : une publication porte ses propres faces dans le bucket `library`,
-- avec **une seule** règle d'accès et un cycle de vie propre. Il n'existe plus
-- aucune Card derrière une publication.
--
-- Conséquence directe et voulue : `can_view_card_file` perd DEUX branches de
-- plus (bibliothèque et bibliothèque publique). De six chemins au 2026-08-10,
-- il en reste **trois**.
--
-- Durée de vie : **permanente**. Décision de Jay du 2026-08-11 (« c'est ce qui
-- a toujours été décidé ») — d'où l'absence de colonne d'expiration.
--
-- La table garde son nom : `library_items` décrit bien la bibliothèque de
-- profil, et la renommer aurait touché une douzaine d'écrans sans rien changer
-- à l'architecture. Son contexte de diffusion est `publication`.
--
-- Aucune donnée détruite ici : la purge décidée par Jay a été exécutée juste
-- avant (64 Vibes, 20 livraisons, 44 publications, 16 sauvegardes).

-- ---------------------------------------------------------------------------
-- 1. Débrancher la publication du monde des Cards
-- ---------------------------------------------------------------------------

drop policy if exists cards_select_library on public.cards;
drop policy if exists cards_select_public_library on public.cards;
drop function if exists private.is_public_library_card(uuid, uuid);

-- Il ne reste qu'une source d'accès illimité : la sauvegarde. Elle-même
-- disparaîtra à l'étape 5, quand la sauvegarde deviendra une copie locale.
create or replace function private.has_unlimited_card_access(card uuid, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from saved_cards s where s.card_id = card and s.owner_id = uid
  );
$$;

-- `can_view_card_file` : SIX chemins le 2026-08-10, **TROIS** aujourd'hui.
create or replace function private.can_view_card_file(file_path text, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from cards c
    where (c.front_path = file_path or c.back_path = file_path)
      and (
        c.owner_id = uid
        or exists (
          select 1 from card_deliveries d
          where d.card_id = c.id and d.recipient_id = uid and d.destroyed_at is null
        )
        or exists (
          select 1 from saved_cards s
          where s.card_id = c.id and s.owner_id = uid
        )
      )
  );
$$;

-- ---------------------------------------------------------------------------
-- 2. La publication autonome
-- ---------------------------------------------------------------------------

-- ⚠️ Les politiques de stockage se suppriment AVANT la table : `library_read_via_acl`
-- interroge `library_items.media_path`, PostgreSQL refuserait donc le
-- `drop table` tant qu'elle existe.
drop policy if exists library_read_via_acl on storage.objects;
drop policy if exists library_insert_own on storage.objects;
drop policy if exists library_delete_own on storage.objects;
drop policy if exists library_write_own on storage.objects;

drop table if exists public.library_items;

create table public.library_items (
  -- L'identifiant EST le Content ID.
  id uuid primary key references public.contents (id) on delete cascade,
  owner_id uuid not null references auth.users (id) on delete cascade,

  card_type public.card_type not null default 'standard',
  front_path text not null,
  back_path text,
  front_is_video boolean not null default false,
  back_is_video boolean not null default false,
  caption text,

  -- Visible par toute personne accédant au profil par un moyen légitime, au
  -- lieu des seules règles de bibliothèque.
  is_public boolean not null default false,

  -- Propagation de cercle en cercle, comme les stories. Faux par défaut : le
  -- partage hors cercle reste un acte délibéré.
  shareable boolean not null default false,

  encrypted boolean not null default true,
  created_at timestamptz not null default now(),

  constraint library_items_back_face_consistent
    check (back_path is not null or not back_is_video)
);

create index library_items_owner_idx
  on public.library_items (owner_id, created_at desc);

alter table public.library_items enable row level security;

create table public.library_media_keys (
  item_id uuid primary key references public.library_items (id) on delete cascade,
  media_key text not null
);

alter table public.library_media_keys enable row level security;
-- Aucune politique : la clé ne sort que par une RPC qui vérifie l'accès.

-- ---------------------------------------------------------------------------
-- 3. L'audience — une question, un endroit
-- ---------------------------------------------------------------------------

create or replace function private.publication_audience(p_item_id uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from library_items li
    where li.id = p_item_id
      and not private.is_revoked(li.id)
      and (
        -- 1. l'auteur
        li.owner_id = p_uid
        -- 2. ceux qui peuvent voir sa bibliothèque
        or can_view_library(li.owner_id, p_uid)
        -- 3. publication publique : toute personne pouvant voir le profil
        or (li.is_public and can_view_profile(p_uid, li.owner_id))
        -- 4. les repartages : une arête du graphe menant à cette personne
        or exists (
          select 1 from content_grants g
          where g.content_id = li.id and g.grantee_id = p_uid
        )
      )
  );
$$;

create or replace function private.can_view_publication_file(file_path text, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from library_items li
    where (li.front_path = file_path or li.back_path = file_path)
      and private.publication_audience(li.id, uid)
  );
$$;

revoke all on function private.publication_audience(uuid, uuid) from public, anon, authenticated;
revoke all on function private.can_view_publication_file(text, uuid) from public, anon, authenticated;

create policy library_select_audience on public.library_items
  for select using (private.publication_audience(id, (select auth.uid())));

create policy library_insert_own on public.library_items
  for insert with check (owner_id = (select auth.uid()));

create policy library_update_own on public.library_items
  for update using (owner_id = (select auth.uid()));

create policy library_delete_own on public.library_items
  for delete using (owner_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 4. Le bucket `library` — politiques refaites sur la nouvelle règle
--    (les anciennes ont été supprimées en section 2, avant la table)
-- ---------------------------------------------------------------------------

create policy library_write_own on storage.objects
  for insert with check (
    bucket_id = 'library'
    and (storage.foldername(name))[1] = ((select auth.uid()))::text
  );

create policy library_read_audience on storage.objects
  for select using (
    bucket_id = 'library'
    and (
      (storage.foldername(name))[1] = ((select auth.uid()))::text
      or private.can_view_publication_file(name, (select auth.uid()))
    )
  );

create policy library_delete_own on storage.objects
  for delete using (
    bucket_id = 'library'
    and (storage.foldername(name))[1] = ((select auth.uid()))::text
  );
