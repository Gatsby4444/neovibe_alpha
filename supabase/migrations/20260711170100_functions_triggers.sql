-- NeoVibe V1 — fonctions et triggers (logique métier côté serveur)

-- ============================================================
-- Helpers (security definer pour éviter la récursion RLS)
-- ============================================================

create or replace function public.are_connected(a uuid, b uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from connections
    where user_low = least(a, b) and user_high = greatest(a, b) and status = 'full'
  );
$$;

create or replace function public.has_any_connection(a uuid, b uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from connections
    where user_low = least(a, b) and user_high = greatest(a, b)
  );
$$;

create or replace function public.is_conversation_member(conv uuid, uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from conversation_members where conversation_id = conv and user_id = uid
  );
$$;

-- Visibilité d'un profil : soi-même, connexion (tout statut), conversation partagée,
-- demande BLE en cours, ou implication mutuelle dans une recommandation.
-- Jamais d'annuaire global : aucun autre chemin de lecture de profil.
create or replace function public.can_view_profile(viewer uuid, target uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select viewer = target
    or has_any_connection(viewer, target)
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

-- Accès à la bibliothèque d'un utilisateur : propriétaire, ou selon sa visibilité
-- ('connections' = toutes ses connexions complètes ; 'restricted' = liste d'accès)
create or replace function public.can_view_library(owner uuid, viewer uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select owner = viewer
    or exists (
      select 1 from profiles p
      where p.id = owner
        and (
          (p.library_visibility = 'connections' and are_connected(owner, viewer))
          or (p.library_visibility = 'restricted' and exists (
            select 1 from library_access la
            where la.owner_id = owner and la.grantee_id = viewer
          ))
        )
    );
$$;

-- updated_at automatique sur profiles
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ============================================================
-- Ping BLE : résolution de tokens + acceptation de demande
-- ============================================================

-- Résout les ble_token captés en scan vers des profils restreints.
-- Seul chemin d'accès au profil d'un inconnu — nécessite la preuve de coprésence
-- (posséder le token diffusé). Ne renvoie jamais l'id de compte sans cette preuve.
create or replace function public.resolve_ble_tokens(tokens uuid[])
returns table (user_id uuid, display_name text, avatar_url text, is_connected boolean)
language sql stable security definer set search_path = public
as $$
  select p.id, p.display_name, p.avatar_url, are_connected(auth.uid(), p.id)
  from profiles p
  where p.ble_token = any (tokens)
    and p.id <> auth.uid();
$$;

-- Acceptation d'une demande de connexion BLE : valable uniquement si la demande
-- n'a pas expiré (l'émetteur rafraîchit expires_at tant que la proximité dure).
create or replace function public.accept_connection_request(req_id uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  conn_id uuid;
begin
  select * into r from connection_requests where id = req_id for update;
  if not found then
    raise exception 'Demande introuvable';
  end if;
  if r.receiver_id <> auth.uid() then
    raise exception 'Seul le destinataire peut accepter';
  end if;
  if r.status <> 'pending' or r.expires_at < now() then
    raise exception 'Demande expirée (hors de portée)';
  end if;

  update connection_requests set status = 'accepted' where id = req_id;

  insert into connections (user_low, user_high, status, origin, established_at)
  values (least(r.sender_id, r.receiver_id), greatest(r.sender_id, r.receiver_id), 'full', 'ble', now())
  on conflict (user_low, user_high) do update
    set status = 'full', established_at = coalesce(connections.established_at, now())
  returning id into conn_id;

  return conn_id;
end;
$$;

create or replace function public.decline_connection_request(req_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update connection_requests
  set status = 'declined'
  where id = req_id and receiver_id = auth.uid() and status = 'pending';
end;
$$;

-- ============================================================
-- Recommandations A→B→C
-- ============================================================

-- A transmet une demande de B vers C (choisi par A parmi ses connexions).
-- Plafond strict : 10 transmissions réussies par mois calendaire et par intermédiaire.
create or replace function public.forward_recommendation(reco_id uuid, chosen_target uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  monthly_count integer;
begin
  select * into r from recommendations where id = reco_id for update;
  if not found then
    raise exception 'Recommandation introuvable';
  end if;
  if r.intermediary_id <> auth.uid() then
    raise exception 'Seul l''intermédiaire peut transmettre';
  end if;
  if r.status <> 'requested' or r.expires_at < now() then
    raise exception 'Demande expirée ou déjà traitée';
  end if;
  if chosen_target = r.requester_id or chosen_target = r.intermediary_id then
    raise exception 'Destinataire invalide';
  end if;
  if not are_connected(auth.uid(), chosen_target) then
    raise exception 'Vous devez être connecté à la personne choisie';
  end if;
  if are_connected(r.requester_id, chosen_target) then
    raise exception 'Ces personnes sont déjà connectées';
  end if;

  select count(*) into monthly_count
  from recommendations
  where intermediary_id = auth.uid()
    and forwarded_at >= date_trunc('month', now());
  if monthly_count >= 10 then
    raise exception 'Plafond mensuel de 10 mises en relation atteint';
  end if;

  update recommendations
  set target_id = chosen_target,
      status = 'forwarded',
      forwarded_at = now(),
      expires_at = now() + interval '14 days'
  where id = reco_id;
end;
$$;

-- C accepte la proposition → connexion complète B↔C (origine recommendation)
create or replace function public.accept_recommendation(reco_id uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  conn_id uuid;
begin
  select * into r from recommendations where id = reco_id for update;
  if not found then
    raise exception 'Recommandation introuvable';
  end if;
  if r.target_id <> auth.uid() then
    raise exception 'Seul le destinataire peut accepter';
  end if;
  if r.status <> 'forwarded' or r.expires_at < now() then
    raise exception 'Proposition expirée';
  end if;

  update recommendations set status = 'accepted', resolved_at = now() where id = reco_id;

  insert into connections (user_low, user_high, status, origin, established_at)
  values (least(r.requester_id, r.target_id), greatest(r.requester_id, r.target_id), 'full', 'recommendation', now())
  on conflict (user_low, user_high) do update
    set status = 'full', established_at = coalesce(connections.established_at, now())
  returning id into conn_id;

  return conn_id;
end;
$$;

-- Refus (par A ou C) : enregistré comme 'declined' mais jamais exposé comme tel à B
-- (le client de B traite tout statut non-accepté comme silencieux, cf. spec 4.5.5)
create or replace function public.decline_recommendation(reco_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update recommendations
  set status = 'declined', resolved_at = now()
  where id = reco_id
    and (intermediary_id = auth.uid() or target_id = auth.uid())
    and status in ('requested', 'forwarded');
end;
$$;

-- ============================================================
-- Conversations
-- ============================================================

-- Conversation directe : uniquement entre connexions complètes
create or replace function public.get_or_create_direct_conversation(peer uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  key text;
  conv_id uuid;
begin
  if not are_connected(me, peer) then
    raise exception 'Messagerie directe réservée aux connexions établies';
  end if;
  key := 'direct:' || least(me, peer) || ':' || greatest(me, peer);

  insert into conversations (conversation_type, pair_key, created_by)
  values ('direct', key, me)
  on conflict (pair_key) do nothing;

  select id into conv_id from conversations where pair_key = key;

  insert into conversation_members (conversation_id, user_id)
  values (conv_id, me), (conv_id, peer)
  on conflict do nothing;

  return conv_id;
end;
$$;

-- Conversation de proximité : entre inconnus (pas encore connectés en 'full').
-- Le client ne l'affiche que pendant la proximité BLE (ou si lien partiel établi).
create or replace function public.get_or_create_proximity_conversation(peer uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  key text;
  conv_id uuid;
begin
  if are_connected(me, peer) then
    raise exception 'Déjà connectés : utilisez la messagerie directe';
  end if;
  key := 'prox:' || least(me, peer) || ':' || greatest(me, peer);

  insert into conversations (conversation_type, pair_key, created_by)
  values ('proximity', key, me)
  on conflict (pair_key) do nothing;

  select id into conv_id from conversations where pair_key = key;

  insert into conversation_members (conversation_id, user_id)
  values (conv_id, me), (conv_id, peer)
  on conflict do nothing;

  return conv_id;
end;
$$;

-- ============================================================
-- Règles des messages (trigger before insert)
-- ============================================================

-- Canal proximité : texte uniquement, 3 messages max tant qu'aucune réponse.
-- (Les messages expirant à 24h, le compteur se réinitialise naturellement —
--  cohérent avec la règle "nouvelle rencontre réinitialise la possibilité".)
create or replace function public.enforce_message_rules()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  ctype public.conversation_type;
  other_replied boolean;
  my_count integer;
begin
  select conversation_type into ctype from conversations where id = new.conversation_id;

  if ctype = 'proximity' then
    if new.kind <> 'text' then
      raise exception 'Le canal de proximité est limité au texte';
    end if;
    select exists (
      select 1 from messages
      where conversation_id = new.conversation_id and sender_id <> new.sender_id
    ) into other_replied;
    if not other_replied then
      select count(*) into my_count
      from messages
      where conversation_id = new.conversation_id and sender_id = new.sender_id;
      if my_count >= 3 then
        raise exception 'Limite de 3 messages sans réponse atteinte';
      end if;
    end if;
  end if;

  -- Une Card jointe doit appartenir à l'expéditeur
  if new.card_id is not null then
    if not exists (select 1 from cards where id = new.card_id and owner_id = new.sender_id) then
      raise exception 'Card invalide';
    end if;
  end if;

  return new;
end;
$$;

create trigger messages_rules
  before insert on public.messages
  for each row execute function public.enforce_message_rules();

-- Après le premier échange bilatéral sur un canal proximité → connexion partielle
-- (3 jours pour la confirmer mutuellement, sinon elle expire)
create or replace function public.maybe_create_partial_connection()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  ctype public.conversation_type;
  peer uuid;
begin
  select conversation_type into ctype from conversations where id = new.conversation_id;
  if ctype <> 'proximity' then
    return new;
  end if;

  select user_id into peer
  from conversation_members
  where conversation_id = new.conversation_id and user_id <> new.sender_id
  limit 1;

  -- Un échange = au moins un message de chaque côté
  if peer is not null
     and exists (select 1 from messages where conversation_id = new.conversation_id and sender_id = peer) then
    insert into connections (user_low, user_high, status, origin, partial_expires_at)
    values (least(new.sender_id, peer), greatest(new.sender_id, peer), 'partial', 'ble', now() + interval '3 days')
    on conflict (user_low, user_high) do nothing;
  end if;

  return new;
end;
$$;

create trigger messages_partial_connection
  after insert on public.messages
  for each row execute function public.maybe_create_partial_connection();

-- Confirmation d'une connexion partielle ; complète quand les deux ont confirmé
create or replace function public.confirm_partial_connection(conn_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  c record;
begin
  select * into c from connections where id = conn_id for update;
  if not found or c.status <> 'partial' then
    raise exception 'Connexion partielle introuvable';
  end if;
  if c.partial_expires_at < now() then
    raise exception 'Le lien partiel a expiré';
  end if;

  if auth.uid() = c.user_low then
    update connections set confirmed_low = true where id = conn_id;
  elsif auth.uid() = c.user_high then
    update connections set confirmed_high = true where id = conn_id;
  else
    raise exception 'Vous ne faites pas partie de cette connexion';
  end if;

  update connections
  set status = 'full', established_at = now(), partial_expires_at = null
  where id = conn_id and confirmed_low and confirmed_high and status = 'partial';
end;
$$;

-- ============================================================
-- Règles des Cards
-- ============================================================

-- One of One : une seule livraison, jamais ; pas de publication en bibliothèque.
-- Oneshot : pas de publication en bibliothèque (contradiction avec la vue unique).
create or replace function public.enforce_card_delivery_rules()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  c record;
begin
  select * into c from cards where id = new.card_id;
  if c.owner_id <> new.recipient_id and not are_connected(c.owner_id, new.recipient_id) then
    raise exception 'Les Cards ne peuvent être envoyées qu''à des connexions';
  end if;
  if c.card_type = 'one_of_one' then
    if exists (select 1 from card_deliveries where card_id = new.card_id) then
      raise exception 'Une Card One of One ne peut avoir qu''un seul destinataire';
    end if;
  end if;
  return new;
end;
$$;

create trigger card_deliveries_rules
  before insert on public.card_deliveries
  for each row execute function public.enforce_card_delivery_rules();

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
    if ctype in ('one_of_one', 'oneshot') then
      raise exception 'Les Cards % ne peuvent pas être publiées en bibliothèque', ctype;
    end if;
  end if;
  return new;
end;
$$;

create trigger library_items_card_rules
  before insert on public.library_items
  for each row execute function public.enforce_library_card_rules();

-- Marque un visionnage. Hot : mise en avant privée si ouverte < 2 min après réception.
create or replace function public.mark_card_viewed(delivery_id uuid)
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
  if d.destroyed_at is not null then
    raise exception 'Card détruite';
  end if;

  select card_type into ctype from cards where id = d.card_id;

  if d.first_viewed_at is null then
    update card_deliveries
    set first_viewed_at = now(),
        hot_boosted = (ctype = 'hot' and now() - d.delivered_at < interval '2 minutes')
    where id = delivery_id;
  elsif ctype = 'oneshot' then
    raise exception 'Une Card Oneshot ne peut être vue qu''une fois';
  end if;
end;
$$;

-- Destruction d'un Oneshot après visionnage (appelé par le client à la fin du timer)
create or replace function public.destroy_oneshot(delivery_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update card_deliveries d
  set destroyed_at = now()
  from cards c
  where d.id = delivery_id
    and c.id = d.card_id
    and d.recipient_id = auth.uid()
    and c.card_type = 'oneshot'
    and d.destroyed_at is null;
end;
$$;
