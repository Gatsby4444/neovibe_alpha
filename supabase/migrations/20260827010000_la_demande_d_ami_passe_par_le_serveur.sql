-- La demande d'ami de proximité passe par le SERVEUR, sur preuve BLE.
--
-- ## Décision de Jay, 2026-08-27
--
-- > « On n'utilise plus la poignée de main GATT. La messagerie et les demandes
-- > d'amis passent par le serveur ; **le BLE ne sert qu'à valider et
-- > authentifier la proximité réelle** des utilisateurs, le reste passe par le
-- > serveur. »
--
-- C'est l'aboutissement du renversement du 2026-08-25 (`RAPPELS.md` #65) : *le
-- BLE cesse d'être la techno de base pour devenir un outil de vérification.* La
-- suppression y était annoncée, conditionnée à une validation sur appareil —
-- elle a eu lieu le 2026-08-26 au soir (première paire réelle en base).
--
-- ## ⚠️ CE QUI CHANGE DE NATURE, ET QU'IL FAUT VOIR EN FACE
--
-- Jusqu'ici, « on ne peut demander en ami que quelqu'un qu'on a physiquement
-- rencontré » était garanti par **la radio** : la demande voyageait dans un
-- canal BLE chiffré, donc il fallait être à portée pour l'émettre. La garantie
-- était **physique**, et le serveur n'avait rien à vérifier.
--
-- Désormais la demande est un appel réseau ordinaire. **La garantie doit donc
-- devenir une règle serveur** — sinon la barrière fondatrice du produit
-- disparaîtrait en silence, sans qu'aucun écran ne change.
--
-- C'est ce que fait cette fonction : elle **exige la preuve de proximité que le
-- BLE vient de produire**. Sans paire mutuelle fraîche, pas de demande. Le BLE
-- reste donc la barrière — il ne transporte simplement plus le message.
--
-- ⚠️ **La table reste ouverte à l'insertion directe** (politique
-- `requests_insert_sender`), qui autoriserait à demander n'importe qui. Ce n'est
-- pas une régression — elle existait déjà et aucun code ne s'en servait
-- (`connections_repository.dart` : *« sendRequest a été supprimée le
-- 2026-08-16 : plus aucun appelant »*). Mais c'est **une porte ouverte à
-- refermer**, une fois l'inventaire des chemins légitimes fait — les
-- recommandations A→B→C en ont un. Consigné dans `RAPPELS.md`.

create or replace function public.request_connection_from_proximity(peer uuid)
returns uuid
language plpgsql security definer set search_path to 'public', 'private'
as $function$
declare
  me uuid := auth.uid();
  req_id uuid;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;
  if peer is null or peer = me then
    raise exception 'Destinataire invalide';
  end if;

  -- ⚠️ **Déjà connectés : rien à demander.** Même garde que la messagerie de
  -- proximité, et pour la même raison — sans elle, une demande redondante
  -- fabrique un encadré « X veut se connecter » entre deux personnes qui le
  -- sont déjà (constaté par Jay le 2026-08-17).
  if are_connected(me, peer) then
    raise exception 'Vous êtes déjà connectés';
  end if;

  -- ⚠️ **LA BARRIÈRE FONDATRICE, désormais explicite.**
  --
  -- Elle était tenue par la portée de la radio ; elle est maintenant une
  -- condition écrite, vérifiable et testable. La paire ne peut naître que d'une
  -- proximité constatée **des deux côtés** (`confirm_ping`), donc personne ne
  -- peut se rendre demandable sans avoir été réellement là.
  if not exists (
    select 1 from public.ping_pairs pp
    where ((pp.user_low = me and pp.user_high = peer)
        or (pp.user_low = peer and pp.user_high = me))
      and pp.last_seen_at > now() - interval '10 minutes'
  ) then
    raise exception 'Proximité non constatée';
  end if;

  -- Une demande déjà en attente ne se double pas : on rend la même.
  select id into req_id
  from public.connection_requests
  where sender_id = me and receiver_id = peer and status = 'pending'
    and expires_at > now()
  limit 1;
  if req_id is not null then
    return req_id;
  end if;

  insert into public.connection_requests (sender_id, receiver_id, status, expires_at)
  values (me, peer, 'pending', now() + interval '7 days')
  returning id into req_id;

  return req_id;
end;
$function$;

grant execute on function public.request_connection_from_proximity(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- `ping_nearby` ne rend plus les amis
-- ---------------------------------------------------------------------------
--
-- ⚠️ **Cette chaîne sert à découvrir des INCONNUS.** Un ami est déjà reconnu par
-- le BLE, à l'annonce, sans serveur et avec une information meilleure (la
-- distance). Le rendre ici produisait deux choses, toutes deux constatées par
-- Jay le 2026-08-26 :
--
-- 1. **le même profil affiché deux fois** sur l'écran Ping ;
-- 2. **un bouton de chat qui ne pouvait qu'échouer** —
--    `get_or_create_proximity_conversation` refuse entre gens déjà connectés,
--    et le refus n'arrivait qu'au clic, sous forme d'un message Postgres brut.
--
-- La règle vivait côté serveur et l'écran l'ignorait. On la fait donc appliquer
-- **en amont** : ne pas proposer plutôt qu'afficher puis refuser.
--
-- ⚠️ Le FAIT, lui, reste intact : la paire continue d'être créée dans
-- `ping_pairs` par `confirm_ping`. C'est l'affichage qui filtre, pas la mesure.
create or replace function public.ping_nearby()
returns table(user_id uuid, display_name text, tag_name text, avatar_url text, last_seen_at timestamp with time zone)
language plpgsql security definer set search_path to 'public', 'private'
as $function$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  return query
  select p.id, p.display_name, p.tag_name, p.avatar_url, pp.last_seen_at
  from public.ping_pairs pp
  join public.profiles p
    on p.id = case when pp.user_low = me then pp.user_high else pp.user_low end
  where (pp.user_low = me or pp.user_high = me)
    -- Bornée large : la vue affine. Au-delà, la ligne n'a plus de sens.
    and pp.last_seen_at > now() - interval '10 minutes'
    and not are_connected(me, p.id)
  order by pp.last_seen_at desc;
end;
$function$;
