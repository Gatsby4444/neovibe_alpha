-- Profil V2 + Enregistrements (consignes Jay du 2026-07-12) :
-- - display_name devient le USERNAME UNIQUE ; tag_name optionnel (affiché en
--   conversation, sinon username) ; bio ;
-- - cards « sauvegardables » (standard/oneshot/bereal uniquement) : les
--   destinataires peuvent les enregistrer dans leur bibliothèque privée ;
-- - saved_cards = bibliothèque privée (« Enregistrements ») : ses propres
--   créations + cards sauvegardables reçues, lecture illimitée ;
-- - stats de profil (amis, posts, cards 7 jours) visibles par soi et ses amis.

-- ---------- profils ----------
alter table public.profiles
  add column tag_name text
    check (tag_name is null or char_length(tag_name) between 1 and 30),
  add column bio text check (bio is null or char_length(bio) <= 300);

-- username unique (insensible à la casse) — déduplication préalable par sécurité
update public.profiles p
set display_name = p.display_name || '_' || substr(p.id::text, 1, 4)
where exists (
  select 1 from public.profiles q
  where q.id < p.id and lower(q.display_name) = lower(p.display_name)
);
create unique index profiles_username_unique
  on public.profiles (lower(display_name));

-- ---------- cards sauvegardables ----------
alter table public.cards add column saveable boolean not null default false;

-- ---------- Enregistrements (bibliothèque privée) ----------
create table public.saved_cards (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  card_id uuid not null references public.cards(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, card_id)
);

-- Qui peut enregistrer quoi : ses propres cards (sauf Hot, sans trace par
-- principe), ou une card REÇUE marquée sauvegardable (types autorisés).
create or replace function private.can_save_card(card uuid, uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from cards c
    where c.id = card
      and (
        (c.owner_id = uid and c.card_type <> 'hot')
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

create or replace function private.has_saved(card uuid, uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from saved_cards where card_id = card and owner_id = uid
  );
$$;

grant execute on function private.can_save_card(uuid, uuid) to authenticated, anon;
grant execute on function private.has_saved(uuid, uuid) to authenticated, anon;

alter table public.saved_cards enable row level security;

create policy "saved_select_own" on public.saved_cards for select
  using (owner_id = (select auth.uid()));
create policy "saved_insert_own" on public.saved_cards for insert
  with check (
    owner_id = (select auth.uid())
    and private.can_save_card(card_id, (select auth.uid()))
  );
create policy "saved_delete_own" on public.saved_cards for delete
  using (owner_id = (select auth.uid()));

-- Une card enregistrée reste lisible par celui qui l'a enregistrée
create policy "cards_select_saved" on public.cards for select
  using (private.has_saved(id, (select auth.uid())));

-- Storage : idem pour les fichiers recto/verso
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
          select 1 from saved_cards s
          where s.card_id = c.id and s.owner_id = uid
        )
      )
  );
$$;

-- ---------- stats de profil ----------
-- amis (connexions complètes), posts (bibliothèque publique), cards partagées
-- sur 7 jours glissants (envoyées en chat ou publiées, tous types confondus).
-- Zéro ligne si le demandeur n'est ni la personne ni une de ses connexions.
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
  where auth.uid() = target or are_connected(auth.uid(), target);
$$;

revoke execute on function public.profile_stats(uuid) from public, anon;
