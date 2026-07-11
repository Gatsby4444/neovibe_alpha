-- Cards V2 (consignes Jay du 2026-07-11 soir) :
-- - classique/1of1/oneshot : nombre de vues paramétrable (1-5, défaut 2) et durée
--   de lecture paramétrable (1-20 s ou illimitée, défaut 10 s) ;
-- - trace 24 h dans le chat + replay sur consentement explicite de l'émetteur ;
-- - Hot : UNE seule vue, temps limité, destruction immédiate et AUCUNE trace
--   (le message disparaît du chat) — reprend l'ancien comportement Oneshot ;
-- - Oneshot (nouveau sens) : capture simultanée avant+arrière, sinon classique →
--   redevient publiable en bibliothèque ; Hot ne l'est plus.
-- La bibliothèque reste en visionnage illimité (géré côté client : les limites
-- ne s'appliquent qu'aux livraisons de chat).

-- ---------- cards : paramètres de visionnage ----------
do $$
declare c text;
begin
  select conname into c from pg_constraint
  where conrelid = 'public.cards'::regclass
    and pg_get_constraintdef(oid) ilike '%view_duration_seconds%';
  if c is not null then
    execute format('alter table public.cards drop constraint %I', c);
  end if;
end $$;

alter table public.cards
  alter column view_duration_seconds set default 10;
alter table public.cards
  add constraint cards_view_duration_check
  check (view_duration_seconds is null or view_duration_seconds between 1 and 20);
alter table public.cards
  add column max_views integer default 2
  constraint cards_max_views_check
  check (max_views is null or max_views between 1 and 5);

-- ---------- card_deliveries : compteur de vues + replay ----------
alter table public.card_deliveries
  add column view_count integer not null default 0,
  add column replay_requested_at timestamptz,
  add column replay_granted_at timestamptz;

-- ---------- visionnage ----------
-- Consomme une vue. Hot : une seule, quel que soit le paramétrage.
-- Autres types : max_views (+1 si replay accordé), null = illimité.
create or replace function public.mark_card_viewed(delivery_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  d record;
  c record;
  effective_max integer;
begin
  select * into d from card_deliveries where id = delivery_id for update;
  if not found or d.recipient_id <> auth.uid() then
    raise exception 'Livraison introuvable';
  end if;
  if d.destroyed_at is not null then
    raise exception 'Card détruite';
  end if;

  select * into c from cards where id = d.card_id;

  if c.card_type = 'hot' then
    if d.view_count >= 1 then
      raise exception 'Une Card Hot ne peut être vue qu''une fois';
    end if;
  else
    effective_max := coalesce(c.max_views, 2147483647)
      + case when d.replay_granted_at is not null then 1 else 0 end;
    if d.view_count >= effective_max then
      raise exception 'Plus de visionnages disponibles';
    end if;
  end if;

  update card_deliveries
  set view_count = view_count + 1,
      first_viewed_at = coalesce(first_viewed_at, now()),
      hot_boosted = hot_boosted
        or (c.card_type = 'hot' and now() - delivered_at < interval '2 minutes')
  where id = delivery_id;
end;
$$;

-- Fin de visionnage d'une Hot : destruction immédiate, et quand plus aucun
-- destinataire ne peut la voir, le message disparaît du chat (aucune trace).
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

  update card_deliveries set destroyed_at = now() where id = delivery_id;

  if not exists (
    select 1 from card_deliveries
    where card_id = d.card_id and destroyed_at is null
  ) then
    delete from messages where card_id = d.card_id;
  end if;
end;
$$;

drop function if exists public.destroy_oneshot(uuid);

-- ---------- replay (consentement explicite de l'émetteur — décision verrouillée) ----------
create or replace function public.request_replay(delivery_id uuid)
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
  if ctype = 'hot' then
    raise exception 'Une Card Hot ne peut pas être revisionnée';
  end if;
  if d.replay_requested_at is not null then
    raise exception 'Replay déjà demandé';
  end if;
  update card_deliveries set replay_requested_at = now() where id = delivery_id;
end;
$$;

create or replace function public.grant_replay(delivery_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  d record;
begin
  select cd.* into d
  from card_deliveries cd
  join cards c on c.id = cd.card_id
  where cd.id = delivery_id and c.owner_id = auth.uid()
  for update of cd;
  if not found then
    raise exception 'Livraison introuvable';
  end if;
  if d.replay_requested_at is null or d.replay_granted_at is not null then
    raise exception 'Aucune demande de replay en attente';
  end if;
  update card_deliveries set replay_granted_at = now() where id = delivery_id;
end;
$$;

revoke execute on function public.mark_card_viewed(uuid) from public, anon;
revoke execute on function public.finish_hot_view(uuid) from public, anon;
revoke execute on function public.request_replay(uuid) from public, anon;
revoke execute on function public.grant_replay(uuid) from public, anon;

-- ---------- bibliothèque : Hot et 1/1 interdits ; Oneshot redevient publiable ----------
create or replace function public.enforce_library_card_rules()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  ctype public.card_type;
begin
  if new.card_id is not null then
    select card_type into ctype from cards where id = new.card_id and owner_id = new.owner_id;
    if ctype is null then
      raise exception 'Card invalide';
    end if;
    if ctype in ('one_of_one', 'hot') then
      raise exception 'Les Cards % ne peuvent pas être publiées en bibliothèque', ctype;
    end if;
  end if;
  return new;
end;
$$;

-- ---------- purge cron : nettoyage des Hot détruites (au lieu des Oneshot) ----------
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
  delete from public.cards c
    where c.card_type = 'hot'
      and exists (select 1 from public.card_deliveries d where d.card_id = c.id and d.destroyed_at is not null)
      and not exists (select 1 from public.card_deliveries d where d.card_id = c.id and d.destroyed_at is null);
  $$
);
