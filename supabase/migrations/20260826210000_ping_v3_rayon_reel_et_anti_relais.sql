-- Ping v3 — la position exacte est CONSERVÉE, et elle sert à deux choses :
-- un rayon réel plutôt qu'une grille, et une barrière contre l'attaque par relais.
--
-- ## Décision de Jay, 2026-08-26
--
-- Jusqu'ici le serveur recevait la position brute, l'arrondissait à un carreau
-- d'environ 1 km et **jetait le reste**. Jay a tranché : on garde la position.
-- Ce que ça débloque : un filtre par distance réelle (donc une liste d'écoute
-- beaucoup plus courte et plus locale), le clustering à venir (`RAPPELS.md` #36),
-- la direction, et surtout la capacité de **diagnostiquer** — aujourd'hui, quand
-- deux téléphones ne se trouvent pas, rien ne dit s'ils étaient à 5 m ou à 2 km.
--
-- ⚠️ **Ce que ça ne change pas** : la preuve des 20 m reste le BLE, et lui seul.
-- Même exacte, une position hybride donne 20 à 100 m d'incertitude en intérieur.
-- Elle sert à ORIENTER, jamais à prouver.
--
-- ⚠️ **Contrepartie assumée, écrite ici pour ne pas être redécouverte** : la
-- table contient désormais la position exacte des utilisateurs actifs. Elle est
-- purgée à 15 minutes (`purge_ping`) et **aucune politique RLS ne l'expose** —
-- seules ces fonctions `security definer` y touchent. Le jour où la rétention
-- augmente, la nature de la donnée change : ce n'est plus un instantané, c'est
-- un historique de déplacements.
--
-- ## ⚠️ Le principe qui rend cette migration sûre : elle ne peut que RESTREINDRE
--
-- Le pré-filtre par carreau est **conservé** — c'est lui qui utilise l'index, et
-- c'est lui qui borne le pire cas. Le filtre par distance ne fait que retirer des
-- lignes à l'intérieur. Et son seuil s'élargit tout seul avec l'incertitude
-- annoncée par les appareils : quand on sait mal où l'on est, on cherche large.
-- Il n'existe donc aucun cas où cette migration fait trouver MOINS de monde
-- qu'avant sans raison mesurée.

-- ---------------------------------------------------------------------------
-- 1. La position, et l'incertitude qui va avec
-- ---------------------------------------------------------------------------

-- ⚠️ Les balises sont éphémères par nature (TTL 5 min, purge 15 min) : les vider
-- ne perd rien et permet de poser `not null` tout de suite, plutôt que de
-- tolérer un `null` que le filtre anti-relais devrait ensuite contourner — donc
-- de laisser une porte ouverte pour un client qui l'omettrait exprès.
delete from public.ping_beacons;

alter table public.ping_beacons
  add column if not exists lat double precision,
  add column if not exists lon double precision,
  -- L'incertitude ANNONCÉE par l'appareil, en mètres (`Position.accuracy`,
  -- rayon de confiance à 68 %). ⚠️ C'est une donnée mesurée, pas devinée : elle
  -- est ce qui permet d'élargir le rayon quand la position est mauvaise, au lieu
  -- de rendre une liste vide indiscernable de « personne autour ».
  add column if not exists acc double precision not null default 0;

alter table public.ping_beacons
  alter column lat set not null,
  alter column lon set not null;

-- ---------------------------------------------------------------------------
-- 2. Deux constantes, et une distance
-- ---------------------------------------------------------------------------

-- Le rayon en deçà duquel on ne cherche jamais à être plus fin.
--
-- ⚠️ **Pourquoi 300 m et pas 20 m.** Le BLE porte 20 m, mais la position, elle,
-- se trompe de 20 à 100 m en intérieur — des deux côtés. Un rayon serré ferait
-- disparaître de la liste des gens réellement à portée : le filtre couperait
-- avant que la radio ait pu prouver quoi que ce soit. 300 m laisse la marge.
create or replace function private.ping_radius_min()
returns double precision language sql immutable as $$
  select 300::double precision
$$;

-- Distance entre deux points, en mètres (haversine).
--
-- ⚠️ **En SQL pur, délibérément.** `earthdistance` et `postgis` sont disponibles
-- mais non installés : ajouter une extension pour une formule de quatre lignes,
-- c'est ajouter une dépendance à installer sur chaque environnement, et une
-- panne de plus le jour où elle manque. Le `least(1, …)` n'est pas décoratif :
-- sans lui, une erreur d'arrondi flottant sur deux points identiques peut sortir
-- du domaine de `asin` et lever.
create or replace function private.meters_between(
  lat_a double precision, lon_a double precision,
  lat_b double precision, lon_b double precision
) returns double precision language sql immutable as $$
  select 6371000 * 2 * asin(least(1, sqrt(
    power(sin(radians(lat_b - lat_a) / 2), 2) +
    cos(radians(lat_a)) * cos(radians(lat_b)) *
    power(sin(radians(lon_b - lon_a) / 2), 2)
  )))
$$;

-- Le seuil applicable à DEUX appareils : jamais moins que le plancher, et
-- élargi par ce que les deux avouent d'incertitude.
create or replace function private.ping_reach(
  acc_a double precision, acc_b double precision
) returns double precision language sql immutable as $$
  select greatest(
    private.ping_radius_min(),
    coalesce(acc_a, 0) + coalesce(acc_b, 0)
  )
$$;

-- ---------------------------------------------------------------------------
-- 3. Publier sa balise — la position est gardée, le carreau reste calculé ICI
-- ---------------------------------------------------------------------------

-- ⚠️ **Le carreau continue d'être calculé par le serveur.** Non pas pour
-- empêcher un client de mentir — il peut de toute façon inventer sa position —
-- mais pour qu'il n'existe **qu'une seule** définition de la taille de la
-- grille. Deux constantes qui divergeraient ne lèveraient aucune erreur : les
-- listes seraient simplement fausses, et personne ne le verrait.
drop function if exists public.publish_ping_beacon(double precision, double precision, text, bigint);

create function public.publish_ping_beacon(
  p_lat double precision,
  p_lon double precision,
  p_token text,
  p_slot bigint,
  p_acc double precision default 0
) returns void
language plpgsql security definer set search_path to 'public', 'private'
as $function$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;
  if p_token is null or length(p_token) = 0 then
    raise exception 'Jeton manquant';
  end if;
  -- ⚠️ **Les bornes du monde se vérifient.** Le serveur dérivait auparavant le
  -- carreau d'une position forcément plausible ; maintenant qu'il conserve la
  -- valeur, une coordonnée absurde s'écrirait telle quelle et fausserait toute
  -- distance calculée ensuite.
  if p_lat is null or p_lon is null
     or p_lat < -90 or p_lat > 90 or p_lon < -180 or p_lon > 180 then
    raise exception 'Position hors bornes';
  end if;

  insert into public.ping_beacons (
    user_id, cell_lat, cell_lon, lat, lon, acc, token, slot
  )
  values (
    me,
    floor(p_lat / private.ping_cell_size())::int,
    floor(p_lon / private.ping_cell_size())::int,
    p_lat,
    p_lon,
    -- Une incertitude négative ou absurde vaut « inconnue », donc 0 : le
    -- plancher de `ping_reach` fera le travail.
    greatest(0, coalesce(p_acc, 0)),
    p_token,
    p_slot
  )
  on conflict (user_id) do update
    set cell_lat = excluded.cell_lat,
        cell_lon = excluded.cell_lon,
        lat = excluded.lat,
        lon = excluded.lon,
        acc = excluded.acc,
        token = excluded.token,
        slot = excluded.slot,
        updated_at = now();
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. La liste d'écoute — le carreau indexe, la distance décide
-- ---------------------------------------------------------------------------

create or replace function public.ping_shortlist(p_limit integer default 500)
returns table(token text, slot bigint)
language plpgsql security definer set search_path to 'public', 'private'
as $function$
declare
  me uuid := auth.uid();
  moi record;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  select b.cell_lat, b.cell_lon, b.lat, b.lon, b.acc into moi
  from public.ping_beacons b
  where b.user_id = me
    and b.updated_at > now() - private.ping_beacon_ttl();

  -- Pas de balise à moi = pas de liste. **On n'écoute que si on s'annonce.**
  if moi.cell_lat is null then
    return;
  end if;

  return query
  select b.token, b.slot
  from public.ping_beacons b
  where b.user_id <> me
    and b.updated_at > now() - private.ping_beacon_ttl()
    -- ① **Le pré-filtre par carreau, conservé.** C'est lui qui se sert de la
    -- clé primaire et qui borne le pire cas ; le filtre fin ne fait qu'affiner à
    -- l'intérieur. Le retirer ferait calculer une distance pour chaque balise du
    -- monde.
    and b.cell_lat between moi.cell_lat - 1 and moi.cell_lat + 1
    and b.cell_lon between moi.cell_lon - 1 and moi.cell_lon + 1
    -- ② **Le filtre fin.** Son seuil s'élargit avec l'incertitude des deux
    -- appareils : en position approximative il dépasse le voisinage de carreaux,
    -- et l'on retrouve alors exactement le comportement d'avant. Ce filtre ne
    -- peut donc jamais faire manquer quelqu'un que l'ancien aurait trouvé, sauf
    -- si les deux appareils savent tous les deux où ils sont.
    and private.meters_between(moi.lat, moi.lon, b.lat, b.lon)
        <= private.ping_reach(moi.acc, b.acc)
    -- ⚠️ Un blocage coupe AVANT toute écoute : ne pas rendre le jeton, c'est
    -- rendre la personne inaudible, pas seulement invisible.
    and not exists (
      select 1 from public.blocks bl
      where (bl.blocker_id = me and bl.blocked_id = b.user_id)
         or (bl.blocker_id = b.user_id and bl.blocked_id = me)
    )
  -- ⚠️ **Trié par distance, et c'est un changement de sens.** Le tri était
  -- chronologique : en cas de troncature à `p_limit`, on gardait les balises les
  -- plus RÉCENTES, ce qui n'a aucun rapport avec la chance de croiser quelqu'un.
  -- Trier par distance fait que la troncature sacrifie toujours les plus
  -- lointains — les seuls qu'on n'a de toute façon aucune chance d'entendre.
  order by private.meters_between(moi.lat, moi.lon, b.lat, b.lon) asc
  limit greatest(1, least(p_limit, 2000));
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Le dépôt — et la barrière contre l'attaque par RELAIS
-- ---------------------------------------------------------------------------

-- ## ⚠️ Ce que cette barrière arrête, et ce qu'elle n'arrête pas
--
-- **Elle arrête le relais.** Un tiers qui capte l'annonce d'Alice à Paris et la
-- rejoue à Tokyo fabriquait jusqu'ici une rencontre entre deux personnes qui ne
-- se sont jamais vues — toutes deux honnêtes, toutes deux trompées. Leurs
-- positions déclarées, elles, sont vraies et distantes de 9 700 km : le constat
-- est refusé.
--
-- **Elle n'arrête pas le mensonge.** Un client modifié peut inventer sa
-- position. Mais il lui faut alors un complice qui mente de façon cohérente — et
-- deux complices ont toujours pu se déclarer proches, c'est irréductible. La
-- réciprocité reste la vraie barrière ; celle-ci ferme le cas où les victimes
-- n'y sont pour rien.
create or replace function public.confirm_ping(p_tokens text[], p_slot bigint)
returns integer
language plpgsql security definer set search_path to 'public', 'private'
as $function$
declare
  me uuid := auth.uid();
  now_slot bigint := floor(extract(epoch from now()) / private.slot_seconds());
  t text;
  moi record;
  sujet record;
  retenus int := 0;
  lo uuid;
  hi uuid;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  -- ⚠️ **Anti-antidatage**, comme pour les constats d'amis (#55). Un créneau
  -- dans le futur ou vieux de plus d'une heure est refusé : la seule chose
  -- qu'on puisse borner est l'ancienneté, deux complices pouvant toujours
  -- s'accorder sur le présent.
  if p_slot > now_slot + 1 or p_slot < now_slot - 4 then
    return 0;
  end if;

  -- ⚠️ **Ma propre balise est exigée, et c'était un trou.** On ne déposait
  -- jusqu'ici aucune condition sur soi : on pouvait donc constater sans jamais
  -- s'annoncer. La règle « on n'écoute que si on s'annonce », qui vivait dans
  -- `ping_shortlist`, ne tenait que par la bonne volonté du client.
  select b.lat, b.lon, b.acc into moi
  from public.ping_beacons b
  where b.user_id = me
    and b.updated_at > now() - private.ping_beacon_ttl();
  if moi.lat is null then
    return 0;
  end if;

  foreach t in array coalesce(p_tokens, array[]::text[]) loop
    -- ⚠️ **C'est le SERVEUR qui résout jeton -> personne, jamais le client.**
    -- Le client n'a entendu qu'une suite d'octets ; il ne saura de qui il
    -- s'agit que si la réciprocité est établie.
    select b.user_id, b.lat, b.lon, b.acc into sujet
    from public.ping_beacons b
    where b.token = t
      and b.slot between p_slot - 1 and p_slot + 1
    limit 1;

    if sujet.user_id is null or sujet.user_id = me then
      continue;
    end if;

    -- **La barrière anti-relais.** Voir la note ci-dessus.
    if private.meters_between(moi.lat, moi.lon, sujet.lat, sujet.lon)
       > private.ping_reach(moi.acc, sujet.acc) then
      continue;
    end if;

    insert into public.ping_confirmations (observer_id, subject_id, slot)
    values (me, sujet.user_id, p_slot)
    on conflict (observer_id, subject_id, slot) do nothing;

    retenus := retenus + 1;

    -- ⚠️ **LE MIROIR : c'est ici, et seulement ici, qu'une paire naît.**
    -- Un créneau d'écart toléré de part et d'autre : deux téléphones n'ont
    -- jamais exactement la même heure.
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
$function$;

-- ---------------------------------------------------------------------------
-- 6. Droits — une fonction citée côté client doit être exécutable par lui
-- ---------------------------------------------------------------------------
-- (`publish_ping_beacon` a été recréée : ses droits sont donc à reposer.)
grant execute on function public.publish_ping_beacon(
  double precision, double precision, text, bigint, double precision
) to authenticated;
