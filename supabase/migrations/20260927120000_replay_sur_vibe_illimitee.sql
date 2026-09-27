-- Une Vibe passée en « vues illimitées » après un replay accordé s'ouvre de
-- nouveau.
--
-- Trouvé le 2026-09-27 en traduisant les Vibes pour le serveur Rust, puis
-- REPRODUIT sous l'identité du destinataire (preuve `06_vibes`, situations
-- « ouvrir / marquer vue une Vibe passée en vues illimitées après un replay
-- accordé ») : quand une Vibe n'a pas de limite de vues (`max_views` nul)
-- ET qu'un replay a été accordé, le calcul « limite + 1 » dépassait le plus
-- grand entier (2147483647 + 1) : `open_card_media` et `mark_card_viewed`
-- échouaient (« integer out of range ») et le destinataire ne pouvait plus
-- ouvrir la Vibe.
-- Chemin réel dans l'app : une Vibe à 2 vues, un replay demandé puis
-- accordé, puis l'auteur la passe en vues illimitées (`update_sent_vibe`).
--
-- Réparation : le calcul se fait en grand entier (bigint). Rien d'autre ne
-- change.
create or replace function public.open_card_media(p_card_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_card cards%rowtype;
  v_delivery card_deliveries%rowtype;
  v_effective_max bigint;
  v_key text;
begin
  select * into v_card from cards where id = p_card_id;
  if not found then
    raise exception 'Vibe introuvable';
  end if;
  select media_key into v_key from card_media_keys where card_id = p_card_id;
  if v_key is null then
    raise exception 'Vibe indisponible : sa clé n''a jamais été déposée';
  end if;
  if v_card.owner_id = v_me then
    return v_key;
  end if;
  select * into v_delivery from card_deliveries
  where card_id = p_card_id and recipient_id = v_me
  for update;
  if not found then
    raise exception 'Vibe introuvable';
  end if;
  if v_delivery.destroyed_at is not null then
    raise exception 'Vibe détruite';
  end if;
  v_effective_max := coalesce(v_card.max_views, 2147483647)::bigint
    + case when v_delivery.replay_granted_at is not null then 1 else 0 end;
  if v_delivery.view_count >= v_effective_max then
    raise exception 'Plus de visionnages disponibles';
  end if;
  update card_deliveries
  set view_count = view_count + 1,
      first_viewed_at = coalesce(first_viewed_at, now())
  where id = v_delivery.id;
  return v_key;
end;
$$;

create or replace function public.mark_card_viewed(delivery_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  d record;
  c record;
  effective_max bigint;
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
    effective_max := coalesce(c.max_views, 2147483647)::bigint
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
