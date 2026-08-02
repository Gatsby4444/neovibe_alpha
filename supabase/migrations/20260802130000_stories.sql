-- ============================================================
-- STORIES (chantier promis #2 — décisions Jay 2026-08-02)
-- ============================================================
-- Une story EST une Card publiée en story : aucun nouveau pipeline média,
-- on réutilise la capture, les faces et le bucket `cards` existants.
--
-- Durée de vie : 24 h, consultable SANS LIMITE pendant ce temps (c'est la
-- norme du format ; la vue unique reste la règle des Cards en chat, pas des
-- stories).
--
-- Qui voit quoi :
--   • mes amis (connexion `full`) voient toujours mes stories ;
--   • en PLUS, si j'ai activé « stories publiques », les personnes que j'ai
--     CROISÉES physiquement dans les dernières 24 h les voient aussi.
--
-- Le croisement est celui de `public.encounters`, alimenté uniquement par
-- `report_encounter` — donc par un certificat co-signé dont les DEUX
-- signatures Ed25519 sont vérifiées côté serveur. On ne peut pas prétendre
-- avoir croisé quelqu'un pour accéder à ses stories.
--
-- La fenêtre de 24 h des croisements coïncide avec la purge posée le même
-- jour (`20260802120000_encounters_ttl_24h.sql`) : la règle et la donnée
-- disent la même chose, il n'y a pas deux durées à tenir synchronisées.

-- ------------------------------------------------------------
-- 1. Réglage de profil : stories publiques
-- ------------------------------------------------------------
alter table public.profiles
  add column if not exists stories_public boolean not null default false;

comment on column public.profiles.stories_public is
  'Si vrai, les personnes croisées physiquement dans les dernières 24 h '
  'voient mes stories, en plus de mes amis. Faux par défaut : sans ce '
  'réglage, seuls mes amis les voient.';

-- ------------------------------------------------------------
-- 2. Table des stories
-- ------------------------------------------------------------
create table if not exists public.stories (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  card_id uuid not null references public.cards(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  unique (owner_id, card_id)
);

-- Lecture du fil : « les stories vivantes de telle personne », et purge.
create index if not exists stories_owner_idx
  on public.stories (owner_id, created_at desc);
create index if not exists stories_expiry_idx
  on public.stories (expires_at);

alter table public.stories enable row level security;

-- ------------------------------------------------------------
-- 3. Qui peut voir les stories de qui
-- ------------------------------------------------------------
-- `security definer` : la fonction lit `profiles` et `encounters` sans passer
-- par leur RLS. Indispensable ici — un viewer non ami n'a AUCUN droit de
-- lecture sur le profil de l'auteur, c'est justement le cas qu'on autorise.
create or replace function private.can_view_stories(owner uuid, viewer uuid)
returns boolean
language sql stable security definer set search_path = public, private
as $$
  select owner = viewer
    or are_connected(owner, viewer)
    or exists (
      select 1 from profiles p
      where p.id = owner
        and p.stories_public
        and exists (
          select 1 from encounters e
          where ((e.user_low = owner and e.user_high = viewer)
              or (e.user_low = viewer and e.user_high = owner))
            and e.last_seen_at > now() - interval '24 hours'
        )
    );
$$;

grant execute on function private.can_view_stories(uuid, uuid) to authenticated;

create policy "stories_select_visible" on public.stories for select
  using (expires_at > now() and private.can_view_stories(owner_id, (select auth.uid())));

-- On ne publie en story que SES PROPRES cards.
create policy "stories_insert_own" on public.stories for insert
  with check (
    owner_id = (select auth.uid())
    and private.owns_card(card_id, (select auth.uid()))
  );

create policy "stories_delete_own" on public.stories for delete
  using (owner_id = (select auth.uid()));

-- ------------------------------------------------------------
-- 4. Accès à la Card portée par une story
-- ------------------------------------------------------------
-- Helper `security definer` : leçon RLS du 2026-07-11 — jamais de
-- sous-requête croisée directe dans une policy de `cards` (récursion).
create or replace function private.is_story_card(card uuid, uid uuid)
returns boolean
language sql stable security definer set search_path = public, private
as $$
  select exists (
    select 1 from stories s
    where s.card_id = card
      and s.expires_at > now()
      and can_view_stories(s.owner_id, uid)
  );
$$;

grant execute on function private.is_story_card(uuid, uuid) to authenticated;

create policy "cards_select_story" on public.cards for select
  using (private.is_story_card(id, (select auth.uid())));

-- Fichiers du bucket `cards` : on ajoute la branche story à la fonction
-- existante. Recopiée depuis la définition RÉELLE relevée en base le
-- 2026-08-02 (`pg_get_functiondef`) — les migrations successives l'avaient
-- déjà redéfinie plusieurs fois, se fier au fichier le plus ancien aurait
-- supprimé des branches d'accès.
create or replace function private.can_view_card_file(file_path text, uid uuid)
returns boolean
language sql stable security definer set search_path = public, private
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
        or is_story_card(c.id, uid)
      )
  );
$$;

-- ------------------------------------------------------------
-- 5. Purge
-- ------------------------------------------------------------
-- Cron réécrit à l'identique (relevé en base le 2026-08-02) + la ligne
-- `stories` : `cron.schedule` REMPLACE le job de même nom, tout ce qui n'est
-- pas recopié disparaît sans bruit.
select cron.schedule(
  'neovibe_purge',
  '*/5 * * * *',
  $$
  delete from public.messages where expires_at < now();
  update public.connection_requests set status = 'expired'
    where status = 'pending' and expires_at < now();
  update public.recommendations set status = 'expired'
    where status in ('requested', 'forwarded') and expires_at < now();
  delete from public.connections
    where status = 'partial' and partial_expires_at < now();
  delete from public.encounters where last_seen_at < now() - interval '24 hours';
  delete from public.stories where expires_at < now();
  $$
);
