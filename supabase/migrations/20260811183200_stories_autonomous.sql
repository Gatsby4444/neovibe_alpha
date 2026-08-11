-- La story devient un OBJET AUTONOME (refonte « 1 contenu = 1 format »,
-- 2026-08-11).
--
-- AVANT : `stories` n'était qu'une ligne (owner_id, card_id) pointant vers une
-- Card. Une même Card pouvait donc être envoyée en DM, publiée en bibliothèque
-- ET mise en story — trois régimes d'accès contradictoires sur un seul fichier.
-- C'est ce qui produisait les deux effets de bord relevés le 2026-08-10 : le
-- compteur de vues partagé entre le chat et la story, et une story annulant en
-- silence la limite de vues promise à un destinataire.
--
-- APRÈS : une story porte ses propres fichiers, son propre type, sa propre
-- durée de vie et sa SEULE règle d'accès. Il n'existe plus de Card derrière
-- elle. Le compteur de vues du chat ne la concerne plus — une story n'en a pas.
--
-- Conséquence directe et voulue : `is_story_card` DISPARAÎT, et avec elle une
-- des six branches de `can_view_card_file`. On ne colmate pas le conflit entre
-- les deux régimes, on supprime la possibilité même du conflit.
--
-- Aucune donnée détruite : `stories` contenait 0 ligne au moment de la
-- migration (TTL 24 h, vérifié en base).

-- ---------------------------------------------------------------------------
-- 1. Débrancher l'ancienne story du monde des Cards
-- ---------------------------------------------------------------------------

drop policy if exists cards_select_story on public.cards;

-- `has_unlimited_card_access` sans la branche story. Ce qui reste : la
-- bibliothèque de profil, la bibliothèque publique, la sauvegarde. Ces trois-là
-- tomberont à leur tour aux étapes 2 et 5 de la refonte.
create or replace function private.has_unlimited_card_access(card uuid, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from library_items li
    where li.card_id = card and can_view_library(li.owner_id, uid)
  )
  or exists (
    select 1 from library_items li
    where li.card_id = card and li.is_public and can_view_profile(uid, li.owner_id)
  )
  or exists (
    select 1 from saved_cards s where s.card_id = card and s.owner_id = uid
  );
$$;

-- `can_view_card_file` passe de SIX chemins à CINQ.
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
          select 1 from library_items li
          where li.card_id = c.id and can_view_library(li.owner_id, uid)
        )
        or exists (
          select 1 from library_items li
          where li.card_id = c.id and li.is_public and can_view_profile(uid, li.owner_id)
        )
        or exists (
          select 1 from saved_cards s
          where s.card_id = c.id and s.owner_id = uid
        )
      )
  );
$$;

drop function if exists private.is_story_card(uuid, uuid);
drop table if exists public.stories;

-- ---------------------------------------------------------------------------
-- 2. La story autonome
-- ---------------------------------------------------------------------------

create table public.stories (
  -- L'identifiant EST le Content ID : un contenu, un format, une identité.
  id uuid primary key references public.contents (id) on delete cascade,
  owner_id uuid not null references auth.users (id) on delete cascade,

  -- Le type est conservé tel quel : le chantier « stories en deck » (dérivé
  -- sans recto/verso) reste bloqué sur 3 questions posées à Jay le 2026-08-02.
  -- Reprendre le format actuel est le choix qui suppose le moins.
  card_type public.card_type not null,
  front_path text not null,
  back_path text,
  front_is_video boolean not null default false,
  back_is_video boolean not null default false,

  -- Propagation de cercle en cercle (« comme un réseau lightning », Jay
  -- 2026-08-11). FAUX par défaut, et c'est une décision de produit, pas une
  -- valeur de commodité : le partage hors cercle doit rester un acte
  -- délibéré, repris à chaque publication. Aucun réglage global de « compte
  -- public » — un état permanent ferait de la diffusion la norme, ce que la
  -- thèse du produit combat.
  shareable boolean not null default false,

  encrypted boolean not null default true,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',

  constraint stories_back_face_consistent
    check (back_path is not null or not back_is_video)
);

create index stories_owner_idx on public.stories (owner_id, created_at desc);
create index stories_expiry_idx on public.stories (expires_at);

alter table public.stories enable row level security;

-- Les clés de déchiffrement. AUCUNE POLITIQUE, comme `card_media_keys` :
-- la table est illisible par tout client, la clé ne sort que par
-- `open_story_media`.
create table public.story_media_keys (
  story_id uuid primary key references public.stories (id) on delete cascade,
  media_key text not null
);

alter table public.story_media_keys enable row level security;

-- ---------------------------------------------------------------------------
-- 3. L'audience — UNE question, UN endroit
-- ---------------------------------------------------------------------------

-- Trois sources d'appartenance, mais une seule question posée : « cette
-- personne est-elle dans l'audience de CETTE story ? »
--
-- À ne pas confondre avec le défaut de `can_view_card_file` : là-bas, six
-- branches provenaient de six FORMATS différents partageant un stockage, et
-- la plus permissive l'emportait en silence. Ici il n'y a qu'un format, qu'un
-- stockage et qu'un régime — seule la façon d'entrer dans l'audience varie.
create or replace function private.story_audience(p_story_id uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from stories s
    where s.id = p_story_id
      and s.expires_at > now()
      and not private.is_revoked(s.id)
      and (
        -- 1. l'auteur
        s.owner_id = p_uid
        -- 2. l'audience initiale : mes amis, plus les croisés de moins de 24 h
        --    si « stories publiques » est actif
        or can_view_stories(s.owner_id, p_uid)
        -- 3. les repartages : toute arête du graphe menant à cette personne
        or exists (
          select 1 from content_grants g
          where g.content_id = s.id and g.grantee_id = p_uid
        )
      )
  );
$$;

create or replace function private.can_view_story_file(file_path text, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from stories s
    where (s.front_path = file_path or s.back_path = file_path)
      and private.story_audience(s.id, uid)
  );
$$;

revoke all on function private.story_audience(uuid, uuid) from public, anon, authenticated;
revoke all on function private.can_view_story_file(text, uuid) from public, anon, authenticated;

create policy stories_select_audience on public.stories
  for select using (private.story_audience(id, (select auth.uid())));

create policy stories_insert_own on public.stories
  for insert with check (owner_id = (select auth.uid()));

create policy stories_delete_own on public.stories
  for delete using (owner_id = (select auth.uid()));

-- Pas de politique UPDATE : une story ne se modifie pas après publication.
-- Changer `shareable` après coup reviendrait à étendre une audience à laquelle
-- l'auteur n'a pas consenti au moment du partage.

-- ---------------------------------------------------------------------------
-- 4. Le bucket
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('stories', 'stories', false)
on conflict (id) do nothing;

create policy stories_write_own on storage.objects
  for insert with check (
    bucket_id = 'stories'
    and (storage.foldername(name))[1] = ((select auth.uid()))::text
  );

create policy stories_read_audience on storage.objects
  for select using (
    bucket_id = 'stories'
    and (
      (storage.foldername(name))[1] = ((select auth.uid()))::text
      or private.can_view_story_file(name, (select auth.uid()))
    )
  );

create policy stories_delete_own on storage.objects
  for delete using (
    bucket_id = 'stories'
    and (storage.foldername(name))[1] = ((select auth.uid()))::text
  );

-- Les RPC destinées au client sont dans la migration suivante,
-- `20260811183300_stories_rpc.sql`.
