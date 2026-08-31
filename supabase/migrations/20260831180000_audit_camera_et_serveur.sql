-- ════════════════════════════════════════════════════════════════════════
-- Second lot de l'audit du 2026-08-31 — la moitié serveur
-- ════════════════════════════════════════════════════════════════════════
--
-- Le premier lot (`20260831120000`) traitait les défauts trouvés en auditant
-- l'accès aux données, le chiffrement et le plan d'émission. Celui-ci vient de
-- l'audit du **reste** : caméra, écrans, et les 51 fonctions serveur qui
-- n'avaient pas encore été lues.
--
--   1. la recommandation ignorait complètement les blocages
--   2. un nœud orphelin qui écrit `pair_key`
--   3. deux fonctions de ménage exécutables par `anon`
--   4. une position conservée trois fois plus longtemps qu'aucune règle ne l'utilise
--   5. une inscription de suppression peut nommer le fichier d'autrui
--   6. deux compteurs qui comptent autre chose que ce que leur nom annonce


-- ════════════════════════════════════════════════════════════════════════
-- 1. LA RECOMMANDATION NE CONSULTAIT PAS LES BLOCAGES
-- ════════════════════════════════════════════════════════════════════════
--
-- Il y a **deux façons** de devenir amis : la proximité et la recommandation.
-- Depuis le premier lot, la proximité refuse tant qu'un blocage tient — à
-- l'émission (`request_connection_from_proximity`) comme à l'acceptation
-- (`accept_connection_request`).
--
-- 🔴 **La recommandation, elle, ne regardait `blocks` à aucun moment.**
--
-- Deux chemins ouverts, dont un seul contrôlé : c'est le plus permissif qui
-- décide (règle 2 de `CLAUDE.md`), et il décidait ici de reformer une amitié
-- que le blocage venait de rompre.
--
-- Deux trous distincts, et il faut les deux :
--
--   • **transmettre** — je peux présenter quelqu'un à une personne qui l'a
--     bloqué. La demande arrive, avec un nom que le destinataire avait
--     justement choisi de ne plus voir ;
--   • **accepter** — une proposition transmise AVANT un blocage reste
--     acceptable après. `block_user` efface les `connection_requests`, il ne
--     touche pas aux `recommendations`.

create or replace function public.forward_recommendation(reco_id uuid, chosen_target uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
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

  -- 🔴 **LES BLOCAGES, ajoutés le 2026-08-31.**
  --
  -- Les DEUX paires comptent, et pour deux raisons différentes :
  --
  --   • demandeur ↔ cible : c'est l'amitié qu'on s'apprête à préparer. La
  --     présenter serait annuler un blocage par personne interposée ;
  --   • moi ↔ cible : je ne transmets rien à quelqu'un avec qui j'ai coupé.
  --     `are_connected` ne suffit pas — `block_user` supprime le lien, donc ce
  --     test échouerait déjà ; il reste pour le cas où un lien survivrait à un
  --     blocage posé autrement.
  if private.is_blocked(r.requester_id, chosen_target) then
    raise exception 'Mise en relation impossible';
  end if;
  if private.is_blocked(auth.uid(), chosen_target) then
    raise exception 'Mise en relation impossible';
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

create or replace function public.accept_recommendation(reco_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'private'
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

  -- 🔴 **Le blocage, ajouté le 2026-08-31.** Une proposition transmise AVANT
  -- un blocage restait acceptable après : `block_user` efface les demandes
  -- d'ami, il ne touche pas aux recommandations. Le symétrique exact de ce qui
  -- a été corrigé sur `accept_connection_request` dans le lot du matin.
  if private.is_blocked(r.requester_id, r.target_id) then
    raise exception 'Mise en relation impossible';
  end if;

  update recommendations set status = 'accepted', resolved_at = now() where id = reco_id;

  insert into connections (user_low, user_high, status, origin, established_at)
  values (least(r.requester_id, r.target_id), greatest(r.requester_id, r.target_id),
          'full', 'recommendation', now())
  on conflict (user_low, user_high) do update
    set status = 'full', established_at = coalesce(connections.established_at, now())
  returning id into conn_id;

  return conn_id;
end;
$$;


-- ════════════════════════════════════════════════════════════════════════
-- 2. UN NŒUD ORPHELIN QUI ÉCRIT `pair_key`
-- ════════════════════════════════════════════════════════════════════════
--
-- `promote_proximity_conversation` promouvait un canal de proximité en
-- conversation directe quand deux personnes devenaient amies. Son déclencheur
-- a été **volontairement** retiré le 2026-07-13 : *« les conversations prox ne
-- migrent plus (séparation TOTALE ping/amis, décision A5) »*.
--
-- ⚠️ **La fonction, elle, est restée.** La migration d'alors a supprimé le
-- déclencheur, `resolve_ble_tokens` et la colonne `ble_token` — et a oublié
-- celle-ci. Vérifié en base le 2026-08-31 : zéro déclencheur l'utilise.
--
-- 🔴 **Et ce n'est pas un reste anodin.** C'est le seul code encore capable
-- d'écrire `pair_key`, la colonne dont le lot du matin vient de retirer le
-- droit d'écriture au client parce qu'elle permettait de détourner la
-- conversation privée de deux inconnus. Elle est `security definer`, donc elle
-- **contourne** ce retrait par construction.
--
-- Elle n'est exécutable par personne (l'exécution avait été révoquée le même
-- jour), donc il n'y a pas de faille aujourd'hui. Mais un reste mort dont la
-- signature ouvre exactement la porte qu'on vient de fermer est précisément ce
-- que la règle 8 de `CLAUDE.md` appelle la panne de demain.
drop function if exists public.promote_proximity_conversation();


-- ════════════════════════════════════════════════════════════════════════
-- 3. DEUX FONCTIONS DE MÉNAGE EXÉCUTABLES PAR `anon`
-- ════════════════════════════════════════════════════════════════════════
--
-- `purge_sightings` et `purge_empty_proximity_conversations` sont des tâches
-- de fond, appelées par `pg_cron`. Elles étaient exécutables par **`anon`** —
-- donc par quiconque possède la clé publiable, sans être connecté — et elles
-- ne vérifient rien : ni `auth.uid()`, ni la provenance.
--
-- ⚠️ **Ce qu'elles peuvent faire est borné**, et c'est ce qui a fait qu'on ne
-- l'a pas vu : elles ne suppriment que ce que le cron supprimerait de toute
-- façon cinq minutes plus tard. La défense s'énonce donc par une négation —
-- *« ça ne fait rien de plus que la tâche planifiée »* — et `CLAUDE.md`
-- règle 4 dit qu'une sécurité formulée ainsi a une date de péremption : elle
-- tombe le jour où quelqu'un élargit la purge sans penser à qui peut l'appeler.
--
-- Effet concret aujourd'hui, tout de même : appelée en boucle,
-- `purge_empty_proximity_conversations` réduit à zéro les cinq minutes de
-- grâce laissées à deux personnes pour écrire leur premier message.
--
-- ⚠️ **Le cron n'est pas touché** : il tourne en tant que propriétaire de la
-- base, pas en tant que `anon`.
revoke execute on function public.purge_sightings() from anon, authenticated;
revoke execute on function public.purge_empty_proximity_conversations() from anon, authenticated;

-- Même famille, relevée dans le même passage : ces trois-là se gardent seules
-- (`auth.uid()` nul → sortie immédiate), mais rien ne justifie de les proposer
-- à un visiteur non connecté. Ce qui n'a pas d'usage anonyme ne s'expose pas.
revoke execute on function public.report_sightings(jsonb) from anon;
revoke execute on function public.confirm_ping(text[], bigint) from anon;
revoke execute on function public.publish_ping_beacon(double precision, double precision, text, bigint, double precision) from anon;
revoke execute on function public.retire_ping_beacon() from anon;
revoke execute on function public.ping_nearby() from anon;
revoke execute on function public.ping_neighbour_count() from anon;
revoke execute on function public.my_friendships() from anon;
revoke execute on function public.library_reveal_at(text, timestamptz) from anon;
revoke execute on function public.request_connection_from_proximity(uuid) from anon;

-- ⚠️ **Après ce bloc, `anon` n'exécute plus AUCUNE fonction de `public`.**
-- C'est la formulation positive : plutôt que « celles qui restent se gardent
-- elles-mêmes », il n'en reste aucune. Un visiteur non connecté n'a rien à
-- faire sur cette API — et le jour où une fonction nouvelle oubliera son
-- `revoke`, l'écart se verra d'un coup d'œil.


-- ════════════════════════════════════════════════════════════════════════
-- 4. UNE POSITION GARDÉE TROIS FOIS PLUS LONGTEMPS QUE SON USAGE
-- ════════════════════════════════════════════════════════════════════════
--
-- `purge_ping` supprimait les balises de plus de **15 minutes**, avec ce
-- commentaire :
--
--     « Une balise périmée n'est pas seulement inutile : c'est une position
--       conservée après coup, et rien ne la justifie. »
--
-- 🔴 **Or `private.ping_beacon_ttl()` vaut 5 minutes.** Passé ce délai, plus
-- aucune règle ne lit la balise : ni `ping_nearby`, ni `ping_neighbour_count`,
-- ni `confirm_ping`. Une balise porte `lat` et `lon` — la position **exacte**,
-- conservée depuis le 2026-08-26 — et elle restait donc dix minutes de plus que
-- le dernier instant où quoi que ce soit pouvait s'en servir.
--
-- Le commentaire énonçait la bonne règle ; le nombre ne la suivait pas.
--
-- ⚠️ **On garde une marge, et on dit laquelle** : le double du TTL, pour qu'une
-- tâche qui saute un tour ne fasse pas disparaître une balise encore utile.
-- C'est une marge d'exécution, pas une durée de conservation.
create or replace function public.purge_ping()
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
begin
  -- Une balise périmée n'est pas seulement inutile : c'est une position
  -- conservée après coup, et rien ne la justifie. La borne suit donc le TTL
  -- (5 min), avec un tour de marge pour la tâche elle-même.
  delete from public.ping_beacons
   where updated_at < now() - (private.ping_beacon_ttl() * 2);
  -- Une confirmation qui n'a pas trouvé son miroir en une heure ne le trouvera
  -- plus : les deux créneaux tolérés sont largement dépassés.
  delete from public.ping_confirmations where created_at < now() - interval '1 hour';
  -- Une paire au-delà de la journée n'ouvre plus rien.
  delete from public.ping_pairs where last_seen_at < now() - interval '24 hours';
end;
$$;


-- ════════════════════════════════════════════════════════════════════════
-- 5. UNE INSCRIPTION DE SUPPRESSION POUVAIT NOMMER LE FICHIER D'AUTRUI
-- ════════════════════════════════════════════════════════════════════════
--
-- Le déclencheur posé ce matin inscrit `old.front_path` et `old.back_path`
-- pour suppression différée. Or **ni `publish_story` ni `add_vibe_to_library`
-- ne vérifient que ces chemins appartiennent à l'auteur** : un client peut
-- publier un contenu qui désigne le fichier de quelqu'un d'autre.
--
-- ⚠️ **Ce n'est pas une fuite** — les octets restent chiffrés, et la politique
-- du coffre refuse la suppression d'un fichier dont le dossier ne porte pas
-- votre identifiant. Mais l'inscription, elle, était créée : le balayage
-- client tentait indéfiniment une suppression qu'il n'obtiendrait jamais, et
-- **retenait tout le coffre avec elle**.
--
-- Le client a été rendu robuste dans le même lot (`StorageSweep` isole le
-- chemin fautif). Ici, on supprime la CAUSE : on n'inscrit que ce que le
-- propriétaire de la ligne peut effectivement effacer. La convention de chemin
-- `<uid>/<nom>` est imposée à l'écriture par les politiques `*_write_own`,
-- c'est donc une source sûre.
create or replace function private.inscrit_les_octets_a_supprimer()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
begin
  insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after)
  select tg_argv[0], chemin, old.owner_id, now() + interval '7 days'
  from unnest(array[old.front_path, old.back_path]) as chemin
  where chemin is not null
    -- ⚠️ N'inscrire QUE ce que le propriétaire pourra supprimer.
    and (storage.foldername(chemin))[1] = old.owner_id::text
  on conflict (bucket_id, object_name) do nothing;
  return old;
end;
$$;

create or replace function private.inscrit_les_octets_de_vibe()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
begin
  insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after)
  select 'library_vault', chemin, old.author_id, now() + interval '7 days'
  from unnest(array[
    old.placeholder_path, old.placeholder_back_path,
    old.sealed_path, old.sealed_back_path
  ]) as chemin
  where chemin is not null
    and (storage.foldername(chemin))[1] = old.author_id::text
  on conflict (bucket_id, object_name) do nothing;
  return old;
end;
$$;

-- Et on retire les inscriptions déjà posées qui ne pointent pas vers un
-- fichier de leur propriétaire : elles ne seraient jamais honorées.
delete from public.storage_tombstones t
where (storage.foldername(t.object_name))[1] <> t.owner_id::text;


-- ════════════════════════════════════════════════════════════════════════
-- 6. DEUX COMPTEURS QUI NE COMPTENT PAS CE QUE LEUR NOM ANNONCE
-- ════════════════════════════════════════════════════════════════════════
--
-- `confirm_ping` et `report_sightings` rendent tous deux une variable nommée
-- `retenus`, incrémentée **après** un `insert … on conflict do nothing` — donc
-- sans regarder si la ligne a été retenue. Elles comptaient les éléments
-- **traités**, pas les constats **enregistrés**.
--
-- ⚠️ La différence n'est pas académique : le client redépose les mêmes jetons
-- à chaque tour de radio. Le nombre rendu était donc, en régime normal, le
-- nombre de jetons entendus — et il ne baissait jamais, quoi qu'il arrive en
-- base. « Un instrument qui ne peut pas descendre à zéro ne mesure rien. »
--
-- ⚠️ **Vérifié avant de changer** : aucun appelant Dart n'utilise ces valeurs
-- pour décider quoi que ce soit (`report_sightings` est appelée sans lire son
-- retour ; `confirm_ping` le remonte sans qu'aucun écran ne s'en serve). Le
-- seul lecteur est humain.

create or replace function public.confirm_ping(p_tokens text[], p_slot bigint)
returns integer
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  now_slot bigint := floor(extract(epoch from now()) / private.slot_seconds());
  t text;
  moi record;
  sujet record;
  retenus int := 0;
  ajoutees int;
  lo uuid;
  hi uuid;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  -- ⚠️ **Anti-antidatage.** Un créneau dans le futur ou vieux de plus d'une
  -- heure est refusé : la seule chose qu'on puisse borner est l'ancienneté,
  -- deux complices pouvant toujours s'accorder sur le présent.
  if p_slot > now_slot + 1 or p_slot < now_slot - 4 then
    return 0;
  end if;

  -- ⚠️ **Ma propre balise est exigée : on n'écoute que si on s'annonce.**
  select b.cell_lat, b.cell_lon into moi
  from public.ping_beacons b
  where b.user_id = me
    and b.updated_at > now() - private.ping_beacon_ttl();
  if moi.cell_lat is null then
    return 0;
  end if;

  foreach t in array coalesce(p_tokens, array[]::text[]) loop
    -- ⚠️ **C'est le SERVEUR qui résout jeton -> personne, jamais le client.**
    select b.user_id, b.cell_lat, b.cell_lon into sujet
    from public.ping_beacons b
    where b.token = t
      and b.slot between p_slot - 1 and p_slot + 1
    limit 1;

    if sujet.user_id is null or sujet.user_id = me then
      continue;
    end if;

    -- 🔴 **LE BLOCAGE, TENU PAR LE SERVEUR.** Coupe AVANT la confirmation :
    -- une confirmation crée une paire, et une paire ouvre la demande d'ami et
    -- le chat de proximité. C'est la paire qu'il faut empêcher.
    if private.is_blocked(me, sujet.user_id) then
      continue;
    end if;

    -- ⚠️ Arriver ici veut dire que le BLE a ENTENDU ce jeton — une preuve de
    -- proximité à une vingtaine de mètres. La géographie n'écarte que l'absurde.
    if not private.ping_plausible(
         moi.cell_lat, moi.cell_lon, sujet.cell_lat, sujet.cell_lon
       ) then
      continue;
    end if;

    insert into public.ping_confirmations (observer_id, subject_id, slot)
    values (me, sujet.user_id, p_slot)
    on conflict (observer_id, subject_id, slot) do nothing;

    -- ⚠️ **On compte ce qui est ENTRÉ, pas ce qu'on a tenté** (2026-08-31).
    -- Le client redépose les mêmes jetons à chaque tour : compter les
    -- tentatives revenait à compter ce qu'on entend, jamais ce qu'on retient.
    get diagnostics ajoutees = row_count;
    retenus := retenus + ajoutees;

    -- ⚠️ **LE MIROIR : c'est ici, et seulement ici, qu'une paire naît.**
    if exists (
      select 1 from public.ping_confirmations m
      where m.observer_id = sujet.user_id
        and m.subject_id = me
        and m.slot between p_slot - 1 and p_slot + 1
    ) then
      lo := least(me, sujet.user_id);
      hi := greatest(me, sujet.user_id);
      insert into public.ping_pairs (user_low, user_high)
      values (lo, hi)
      on conflict (user_low, user_high) do update
        set last_seen_at = now();
    end if;
  end loop;

  return retenus;
end;
$$;

create or replace function public.report_sightings(items jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  item jsonb;
  peer uuid;
  s bigint;
  now_slot bigint := floor(extract(epoch from now()) / private.slot_seconds());
  retenus int := 0;
  ajoutes int;
  lo uuid;
  hi uuid;
begin
  if me is null then
    raise exception 'Non authentifie';
  end if;

  for item in select * from jsonb_array_elements(items) loop
    peer := (item->>'peer')::uuid;
    s := (item->>'slot')::bigint;

    if peer is null or s is null or peer = me then
      continue;
    end if;

    if s > now_slot + 1 or s < now_slot - (48 * 3600 / private.slot_seconds()) then
      continue;
    end if;

    if not exists (
      select 1 from public.connections c
      where c.status = 'full'
        and ((c.user_low = me and c.user_high = peer)
          or (c.user_high = me and c.user_low = peer))
    ) then
      continue;
    end if;

    insert into public.sightings (observer_id, seen_id, slot, band)
    values (me, peer, s, item->>'band')
    on conflict (observer_id, seen_id, slot) do nothing;

    -- ⚠️ Même correction que dans `confirm_ping` : on compte ce qui est entré.
    get diagnostics ajoutes = row_count;
    retenus := retenus + ajoutes;

    if exists (
      select 1 from public.sightings m
      where m.observer_id = peer
        and m.seen_id = me
        and m.slot between s - 1 and s + 1
    ) then
      lo := least(me, peer);
      hi := greatest(me, peer);
      insert into public.encounters
        (user_low, user_high, first_seen_at, last_seen_at, proof)
      values (lo, hi, now(), now(), 'mutual_sighting')
      on conflict (user_low, user_high) do update
        set last_seen_at = greatest(excluded.last_seen_at, encounters.last_seen_at),
            proof = case
                      when encounters.proof = 'certificate' then 'certificate'
                      else excluded.proof
                    end;

      -- Le fait durable, écrit ici parce que c'est le SEUL endroit où un
      -- croisement mutuel entre amis est constaté.
      insert into public.meeting_days (user_low, user_high, day)
      values (lo, hi, (now() at time zone 'utc')::date)
      on conflict do nothing;

      -- ⚠️ `found` est faux quand le conflit a joué : le palier ne se recalcule
      -- donc qu'au PREMIER croisement de la journée.
      if found then
        perform private.refresh_tier(lo, hi);
      end if;
    end if;
  end loop;

  return retenus;
end;
$$;
