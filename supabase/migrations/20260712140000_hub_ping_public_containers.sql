-- Hub Cercle + module Ping + profils publics + containers (consignes Jay du 2026-07-12)
-- 1) purge dev de toutes les cards existantes (passage au format unique 9:16) ;
-- 2) bibliothèque : option « public » par publication (types publiables uniquement :
--    standard/oneshot/bereal + photos/vidéos — Hot et 1/1 déjà interdits en bibliothèque) ;
-- 3) encounters = historique des croisements ping : le profil minimal (PP, username,
--    tag, bio, stats) reste lisible APRÈS l'éloignement (consigne explicite) ;
-- 4) Hot : le container reste 24 h dans le chat, bloqué après la vue unique
--    (plus de suppression du message) ;
-- 5) le destinataire garde l'accès aux MÉTADONNÉES d'une card détruite/épuisée
--    (couleur/tag/état du container) — les fichiers restent inaccessibles ;
-- 6) « Enregistrer pour moi » ouvert aux Hot pour le créateur ; 1/1 exclu (le
--    créateur la rouvre depuis le chat tant que le message existe, comme tous
--    les types côté créateur) ;
-- 7) promotion automatique conversation proximité → directe quand la connexion
--    devient complète (la conversation migre dans Cercle avec son historique) ;
-- 8) catégories de conversations personnalisées (nom 25 caractères max,
--    multi-appartenance autorisée).

-- ============================================================
-- 1. Purge dev : toutes les cards (changement de format)
-- ============================================================
delete from public.messages where card_id is not null or kind = 'card';
delete from public.cards; -- cascade : deliveries, saved_cards, library_items kind=card
-- NB : la suppression directe dans storage.objects est interdite par Supabase
-- (trigger protect_delete). Les fichiers du bucket cards restent orphelins mais
-- inaccessibles (policies liées aux lignes cards) — dette de purge déjà connue.

-- ============================================================
-- 2. Bibliothèque : option publique par publication
-- ============================================================
alter table public.library_items
  add column is_public boolean not null default false;

-- Items publics lisibles par toute personne ayant un accès légitime au profil
create policy "library_select_public" on public.library_items for select
  using (is_public and private.can_view_profile((select auth.uid()), owner_id));

-- Cards visibles via une publication publique (helper security definer :
-- jamais de sous-requête croisée directe dans une policy cards — leçon RLS)
create or replace function private.is_public_library_card(card uuid, uid uuid)
returns boolean
language sql stable security definer set search_path = public, private
as $$
  select exists (
    select 1 from library_items li
    where li.card_id = card
      and li.is_public
      and can_view_profile(uid, li.owner_id)
  );
$$;
grant execute on function private.is_public_library_card(uuid, uuid) to authenticated, anon;

create policy "cards_select_public_library" on public.cards for select
  using (private.is_public_library_card(id, (select auth.uid())));

-- Fichiers de cards : branche publique en plus
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
      )
  );
$$;

-- Fichiers de bibliothèque (photos/vidéos) : branche publique en plus
drop policy "library_read_via_acl" on storage.objects;
create policy "library_read_via_acl" on storage.objects for select
  using (
    bucket_id = 'library'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (
        select 1 from public.library_items li
        where li.media_path = name
          and (
            private.can_view_library(li.owner_id, (select auth.uid()))
            or (li.is_public and private.can_view_profile((select auth.uid()), li.owner_id))
          )
      )
    )
  );

-- ============================================================
-- 3. Encounters : historique des croisements ping
-- ============================================================
create table public.encounters (
  user_low uuid not null references public.profiles(id) on delete cascade,
  user_high uuid not null references public.profiles(id) on delete cascade,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (user_low, user_high),
  constraint encounters_ordered check (user_low < user_high)
);
create index encounters_low_idx on public.encounters (user_low, last_seen_at desc);
create index encounters_high_idx on public.encounters (user_high, last_seen_at desc);

alter table public.encounters enable row level security;
create policy "encounters_select_own" on public.encounters for select
  using ((select auth.uid()) in (user_low, user_high));
-- Écriture uniquement via resolve_ble_tokens (preuve de coprésence = posséder
-- le token diffusé) — aucun INSERT client.

drop function public.resolve_ble_tokens(uuid[]);
create or replace function public.resolve_ble_tokens(tokens uuid[])
returns table (ble_token uuid, user_id uuid, display_name text, avatar_url text, is_connected boolean)
language plpgsql volatile security definer set search_path = public, private
as $$
begin
  insert into encounters as e (user_low, user_high, last_seen_at)
  select least(auth.uid(), p.id), greatest(auth.uid(), p.id), now()
  from profiles p
  where p.ble_token = any (tokens) and p.id <> auth.uid()
  on conflict (user_low, user_high) do update set last_seen_at = now();

  return query
  select p.ble_token, p.id, p.display_name, p.avatar_url,
         are_connected(auth.uid(), p.id)
  from profiles p
  where p.ble_token = any (tokens) and p.id <> auth.uid();
end;
$$;
revoke execute on function public.resolve_ble_tokens(uuid[]) from public, anon;

-- Le profil minimal reste lisible après un croisement (branche encounters)
create or replace function private.can_view_profile(viewer uuid, target uuid)
returns boolean
language sql stable security definer set search_path = public, private
as $$
  select viewer = target
    or has_any_connection(viewer, target)
    or exists (
      select 1 from encounters e
      where e.user_low = least(viewer, target)
        and e.user_high = greatest(viewer, target)
    )
    or exists (
      select 1 from conversation_members m1
      join conversation_members m2 using (conversation_id)
      where m1.user_id = viewer and m2.user_id = target
    )
    or exists (
      select 1 from connection_requests
      where (sender_id = viewer and receiver_id = target)
         or (sender_id = target and receiver_id = viewer)
    )
    or exists (
      select 1 from recommendations
      where (intermediary_id = viewer and (requester_id = target or target_id = target))
         or (requester_id = viewer and intermediary_id = target)
         or (target_id = viewer and intermediary_id = target)
         or (requester_id = viewer and target_id = target and status = 'accepted')
         or (target_id = viewer and requester_id = target and status in ('forwarded', 'accepted'))
    );
$$;

-- Stats de profil : partie du profil minimal → ouvertes à tout accès légitime
create or replace function public.profile_stats(target uuid)
returns table (friends integer, posts integer, cards_week integer)
language sql stable security definer set search_path = public, private
as $$
  select
    (select count(*)::integer from connections
      where (user_low = target or user_high = target) and status = 'full'),
    (select count(*)::integer from library_items where owner_id = target),
    (select count(distinct c.id)::integer from cards c
      where c.owner_id = target
        and c.created_at > now() - interval '7 days'
        and (
          exists (select 1 from card_deliveries d where d.card_id = c.id)
          or exists (select 1 from library_items li where li.card_id = c.id)
        ))
  where auth.uid() = target or can_view_profile(auth.uid(), target);
$$;
revoke execute on function public.profile_stats(uuid) from public, anon;

-- ============================================================
-- 4. Hot : le container reste dans le chat (bloqué), pas de suppression
-- ============================================================
create or replace function public.finish_hot_view(delivery_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  d record;
  ctype public.card_type;
begin
  select * into d from card_deliveries where id = delivery_id for update;
  if not found or d.recipient_id <> auth.uid() then
    raise exception 'Livraison introuvable';
  end if;
  select card_type into ctype from cards where id = d.card_id;
  if ctype <> 'hot' then
    raise exception 'Réservé aux Cards Hot';
  end if;
  -- Destruction de la livraison uniquement : le message (container) reste 24 h,
  -- bloqué et non renouvelable (consigne Jay du 2026-07-12).
  update card_deliveries set destroyed_at = now() where id = delivery_id;
end;
$$;

-- Purge cron : plus de suppression des cards Hot (le container vit 24 h ;
-- les fichiers deviennent inaccessibles via les policies)
select cron.unschedule('neovibe_purge');
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
  $$
);

-- ============================================================
-- 5. Métadonnées de card lisibles même détruite (état du container)
-- ============================================================
create or replace function private.has_card_delivery_any(card uuid, uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from card_deliveries where card_id = card and recipient_id = uid
  );
$$;
grant execute on function private.has_card_delivery_any(uuid, uuid) to authenticated, anon;

drop policy "cards_select_recipient" on public.cards;
create policy "cards_select_recipient" on public.cards for select
  using (private.has_card_delivery_any(id, (select auth.uid())));

-- ============================================================
-- 6. Enregistrer pour moi : Hot autorisé au créateur, 1/1 exclu
-- ============================================================
create or replace function private.can_save_card(card uuid, uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from cards c
    where c.id = card
      and (
        (c.owner_id = uid and c.card_type <> 'one_of_one')
        or (
          c.saveable
          and c.card_type in ('standard', 'oneshot', 'bereal')
          and exists (
            select 1 from card_deliveries d
            where d.card_id = c.id and d.recipient_id = uid
          )
        )
      )
  );
$$;

-- ============================================================
-- 7. Promotion conversation proximité → directe à la connexion
-- ============================================================
create or replace function public.promote_proximity_conversation()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  prox_key text := 'prox:' || new.user_low || ':' || new.user_high;
  direct_key text := 'direct:' || new.user_low || ':' || new.user_high;
begin
  if new.status = 'full'
     and not exists (select 1 from conversations where pair_key = direct_key) then
    update conversations
    set conversation_type = 'direct', pair_key = direct_key
    where pair_key = prox_key;
  end if;
  return new;
end;
$$;
revoke execute on function public.promote_proximity_conversation() from public, anon, authenticated;

create trigger connections_promote_prox
  after insert or update of status on public.connections
  for each row execute function public.promote_proximity_conversation();

-- ============================================================
-- 8. Catégories de conversations
-- ============================================================
create table public.conversation_categories (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 25),
  created_at timestamptz not null default now(),
  constraint categories_unique_name unique (owner_id, name)
);

create table public.conversation_category_members (
  category_id uuid not null references public.conversation_categories(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (category_id, conversation_id)
);

alter table public.conversation_categories enable row level security;
alter table public.conversation_category_members enable row level security;

create policy "categories_all_own" on public.conversation_categories for all
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create policy "category_members_select_own" on public.conversation_category_members for select
  using (
    exists (
      select 1 from public.conversation_categories cc
      where cc.id = category_id and cc.owner_id = (select auth.uid())
    )
  );

create policy "category_members_insert_own" on public.conversation_category_members for insert
  with check (
    exists (
      select 1 from public.conversation_categories cc
      where cc.id = category_id and cc.owner_id = (select auth.uid())
    )
    and private.is_conversation_member(conversation_id, (select auth.uid()))
  );

create policy "category_members_delete_own" on public.conversation_category_members for delete
  using (
    exists (
      select 1 from public.conversation_categories cc
      where cc.id = category_id and cc.owner_id = (select auth.uid())
    )
  );
