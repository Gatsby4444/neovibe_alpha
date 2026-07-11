-- Correctif : récursion infinie entre les policies RLS de cards et
-- card_deliveries (cards→deliveries pour le destinataire, deliveries→cards
-- pour le propriétaire). Bloquait TOUT upload (l'INSERT Storage évalue les
-- policies SELECT de storage.objects au RETURNING, dont celle du bucket
-- cards qui joint les deux tables).
-- Solution : helpers security definer (contournent la RLS → plus de cycle).

create or replace function private.owns_card(card uuid, uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from cards where id = card and owner_id = uid);
$$;

create or replace function private.has_card_delivery(card uuid, uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from card_deliveries
    where card_id = card and recipient_id = uid and destroyed_at is null
  );
$$;

-- Accès aux fichiers d'une Card (recto/verso) : propriétaire, destinataire
-- non détruit, ou visible via une bibliothèque.
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
      )
  );
$$;

grant execute on function private.owns_card(uuid, uuid) to authenticated, anon;
grant execute on function private.has_card_delivery(uuid, uuid) to authenticated, anon;
grant execute on function private.can_view_card_file(text, uuid) to authenticated, anon;

-- cards : le destinataire lit via le helper (plus de sous-requête RLS sur deliveries)
drop policy "cards_select_recipient" on public.cards;
create policy "cards_select_recipient" on public.cards for select
  using (private.has_card_delivery(id, (select auth.uid())));

-- card_deliveries : le propriétaire lit/insère via le helper (plus de sous-requête sur cards)
drop policy "deliveries_select_parties" on public.card_deliveries;
create policy "deliveries_select_parties" on public.card_deliveries for select
  using (
    recipient_id = (select auth.uid())
    or private.owns_card(card_id, (select auth.uid()))
  );

drop policy "deliveries_insert_card_owner" on public.card_deliveries;
create policy "deliveries_insert_card_owner" on public.card_deliveries for insert
  with check (private.owns_card(card_id, (select auth.uid())));

-- Storage bucket cards : plus de jointure directe sous RLS
drop policy "cards_read_via_delivery" on storage.objects;
create policy "cards_read_via_delivery" on storage.objects for select
  using (
    bucket_id = 'cards'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or private.can_view_card_file(name, (select auth.uid()))
    )
  );
