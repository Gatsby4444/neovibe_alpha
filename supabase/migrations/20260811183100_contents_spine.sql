-- Content ID — la colonne vertébrale de la traçabilité (volet 4 de Jay,
-- 2026-08-11).
--
-- Trois tables, et une règle qui commande tout le reste :
--
--   `contents`        identité PERMANENTE d'un contenu, créée avec lui
--   `content_grants`  qui a donné accès à qui, et par quel partage → le GRAPHE
--   `content_views`   qui a vu, quand, combien de fois → les STATISTIQUES
--
-- ⚠️ CES TROIS TABLES SURVIVENT AU CONTENU. C'est délibéré et c'est la seule
-- chose de l'app qui contredise l'éphémère — arbitrage explicite de Jay :
-- « oui cela contredit l'éphémère mais garantit une sécurité pour les
-- utilisateurs donc on garde ». Une story meurt à 24 h : ses fichiers et sa
-- ligne de format disparaissent, son identité et son graphe restent. Sans quoi
-- il n'y aurait plus rien à révoquer ni à retracer une fois le mal fait.
--
-- Les tables de FORMAT (`stories`, et plus tard publications et partages
-- directs) portent les fichiers et le cycle de vie ; elles référencent
-- `contents` sans jamais l'emporter dans leur chute.

-- ---------------------------------------------------------------------------
-- 1. L'identité
-- ---------------------------------------------------------------------------

create table public.contents (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  context public.content_context not null,
  created_at timestamptz not null default now(),

  -- Révocation (modération, chantier ultérieur). Non nul = le contenu est
  -- mort : plus aucune clé n'est délivrée, et les applications qui détiennent
  -- une copie locale doivent la supprimer.
  revoked_at timestamptz,
  revoked_reason text
);

create index contents_owner_idx on public.contents (owner_id, created_at desc);
create index contents_revoked_idx on public.contents (revoked_at)
  where revoked_at is not null;

alter table public.contents enable row level security;

-- Je vois mes propres contenus. Personne ne voit ceux des autres : les
-- consommateurs passent par la table de format, qui a ses propres règles.
create policy contents_select_own on public.contents
  for select using (owner_id = (select auth.uid()));

create policy contents_insert_own on public.contents
  for insert with check (owner_id = (select auth.uid()));

create policy contents_delete_own on public.contents
  for delete using (owner_id = (select auth.uid()));

-- Pas de politique UPDATE, volontairement : `revoked_at` ne doit JAMAIS être
-- écrit par un client. La révocation est un acte de modération, côté serveur.

-- ---------------------------------------------------------------------------
-- 2. Le graphe de propagation
-- ---------------------------------------------------------------------------

-- Une ligne = une ARÊTE du graphe : `granted_by` a donné accès à `grantee_id`.
-- Pas de contrainte d'unicité : deux amis peuvent me partager la même story,
-- et ces deux arêtes sont précisément ce que Jay veut pouvoir retracer.
create table public.content_grants (
  id uuid primary key default gen_random_uuid(),
  content_id uuid not null references public.contents (id) on delete cascade,
  grantee_id uuid not null references auth.users (id) on delete cascade,
  granted_by uuid not null references auth.users (id) on delete cascade,
  -- Conversation par laquelle le partage a transité. Null = audience initiale
  -- de publication (l'auteur vers son cercle).
  conversation_id uuid references public.conversations (id) on delete set null,
  created_at timestamptz not null default now()
);

create index content_grants_lookup_idx
  on public.content_grants (content_id, grantee_id);
create index content_grants_chain_idx
  on public.content_grants (content_id, granted_by);

alter table public.content_grants enable row level security;

-- AUCUNE POLITIQUE — table volontairement illisible et non écrivable par tout
-- client, comme `card_media_keys` et `library_vibe_keys`. Consigne de Jay :
-- « tu peux voir tous ceux qui ont vu la story, mais pas en détail qui a
-- partagé à qui, ça c'est que pour moi, l'admin. » La chaîne ne sort donc
-- jamais par l'API : elle n'est écrite que par des fonctions SECURITY DEFINER.

-- ---------------------------------------------------------------------------
-- 3. Les vues
-- ---------------------------------------------------------------------------

create table public.content_views (
  content_id uuid not null references public.contents (id) on delete cascade,
  viewer_id uuid not null references auth.users (id) on delete cascade,
  first_viewed_at timestamptz not null default now(),
  last_viewed_at timestamptz not null default now(),
  view_count integer not null default 1,
  primary key (content_id, viewer_id)
);

alter table public.content_views enable row level security;

-- Aucune politique non plus. Le nominatif est TOUJOURS enregistré ici, même
-- quand l'interface n'affiche qu'un agrégat : Jay prévoit une option premium
-- qui montrera le détail. L'agrégation est donc une décision d'AFFICHAGE, pas
-- une perte de donnée — il ne faudra pas remonter la base pour l'activer.

-- ---------------------------------------------------------------------------
-- 4. Les deux helpers universels, valables pour tous les formats
-- ---------------------------------------------------------------------------

-- Un contenu révoqué est mort partout, immédiatement et sans exception. Toute
-- fonction qui délivre une clé DOIT commencer par cet appel.
create or replace function private.is_revoked(p_content_id uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from contents c
    where c.id = p_content_id and c.revoked_at is not null
  );
$$;

-- Enregistre une vue. Appelée par les fonctions d'ouverture de chaque format,
-- jamais par le client.
create or replace function private.record_view(p_content_id uuid, p_viewer uuid)
returns void
language sql
security definer
set search_path = 'public', 'private'
as $$
  insert into content_views (content_id, viewer_id)
  values (p_content_id, p_viewer)
  on conflict (content_id, viewer_id) do update
    set view_count = content_views.view_count + 1,
        last_viewed_at = now();
$$;

-- Ces deux fonctions ne sont pas destinées aux clients : révocation des droits
-- par défaut DANS la migration qui les crée (leçon du 2026-08-10 — une
-- fonction SECURITY DEFINER laissée jointe sur /rest/v1/rpc/ est une faille).
revoke all on function private.is_revoked(uuid) from public, anon, authenticated;
revoke all on function private.record_view(uuid, uuid) from public, anon, authenticated;
