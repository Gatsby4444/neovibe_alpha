-- « BLE OK » l'emporte sur « GPS faux » — décision de Jay, 2026-08-28.
--
-- ## Ce qui s'est passé, mesuré et non déduit
--
-- Deux appareils **côte à côte** pendant le test de la v0.9.142. Ce qu'ils ont
-- publié dans `ping_beacons` :
--
-- | | position | incertitude annoncée | carreau |
-- |---|---|---|---|
-- | Charles (Xiaomi) | 50.1305157, 3.8741848 | **600 m** | (5013, 387) |
-- | mimi (tablette)  | 50.1427553, 3.8631820 | 23,8 m | (5014, 386) |
--
-- Écart calculé : **≈ 1 570 m**. `private.ping_reach(600 ; 23,8)` valait
-- **624 m**. Les deux se sont donc mutuellement exclus — de la liste d'écoute
-- **et** de la confirmation. D'où le symptôme signalé : *« côté mimi personne
-- n'a le ping activé dans ton quartier, côté Charles 1 personne »*, la barrière
-- basculant au gré de la dérive du point.
--
-- ⚠️ **Le pré-filtre par carreau n'y était pour rien** : les deux carreaux sont
-- adjacents, donc dans le voisinage ±1. C'est le filtre **en mètres** qui
-- coupait.
--
-- ## Le point de doctrine
--
-- `RAPPELS.md` #65 pose que **le GPS oriente et le BLE prouve**. Or
-- `confirm_ping` appliquait son veto de distance **après** que le client avait
-- entendu le jeton par la radio — c'est-à-dire après une preuve de proximité
-- réelle à une vingtaine de mètres. Le moins fiable des deux annulait le plus
-- fiable.
--
-- ⚠️ **Et la cause première était en amont, côté app** : `CoarseLocation`
-- demandait `LocationAccuracy.low`, c'est-à-dire `PRIORITY_LOW_POWER` — le seul
-- palier d'Android qui n'utilise **ni le GPS ni le Wi-Fi** (antennes réseau
-- seules, classe 10 km). Corrigé le même jour : `high`, avec repli `medium`.
-- Cette migration ne remplace pas ce correctif, elle le complète : même avec un
-- bon palier, une position d'intérieur reste mauvaise, et il ne faut pas qu'un
-- mauvais point puisse annuler ce que la radio a prouvé.
--
-- ## Ce qui remplace le veto, et ce qu'on perd
--
-- Une **seule** définition de « assez proche pour être plausible » :
-- `private.ping_plausible`, le voisinage de carreaux ±1 (≈ 1 à 3 km).
--
-- ⚠️ **Une seule, et c'est le point.** `ping_shortlist` et `confirm_ping`
-- portaient chacune sa copie de la règle. Le client ne confirme QUE des jetons
-- venus de la liste (`ping_beacon_service.dart` : `if (!_shortlist.contains…)`)
-- — donc deux définitions qui divergent rendraient la seconde inatteignable, ou
-- pire, laisseraient passer ce que la première refuse. Un chemin, une donnée.
--
-- ⚠️ **Ce qu'on perd, énoncé sans détour** : la barrière anti-relais passe
-- d'environ 600 m à environ 1 à 3 km. Rejouer un jeton capté à l'autre bout du
-- pays reste impossible ; le faire depuis l'immeuble d'en face devient
-- possible. Arbitrage assumé par Jay : à cette distance il faut déjà une
-- complicité physique sur place, ce qui n'est plus vraiment un relais — et le
-- BLE, lui, a réellement prouvé les 20 m.
--
-- Ce qui NE change pas, et qui porte l'essentiel de la sécurité :
--
--   * il faut sa **propre balise fraîche** pour écouter (« on n'écoute que si
--     on s'annonce ») ;
--   * la fenêtre de créneaux (`now_slot + 1` / `now_slot - 4`) borne
--     l'antidatage ;
--   * **une paire ne naît que si les DEUX se sont confirmés** — la propriété
--     anti-traque, structurelle et inchangée.
--
-- ## Sens entrant / sens sortant, relevés avant de couper (règle 8)
--
-- Interrogé en base sur `pg_proc`, `pg_policies`, `pg_views` et `cron.job`,
-- pas déduit d'un fichier :
--
--   * **qui appelle `private.ping_reach`** : `ping_shortlist` et `confirm_ping`,
--     et rien d'autre. Le troisième résultat, `publish_ping_beacon`, ne la cite
--     que dans un **commentaire** — corrigé ici, sans quoi il justifierait une
--     ligne de code par une fonction disparue.
--   * **qui appelle `private.ping_radius_min`** : `ping_reach`, et elle seule.
--   * **ce qu'elles appelaient** : rien d'autre. Les deux partent.
--   * **`private.meters_between` RESTE** : elle sert encore au tri par distance
--     de `ping_shortlist`, qui décide **qui est sacrifié en cas de troncature**.
--     Une position approximative reste un bon ordre de grandeur pour ça — ce
--     qu'elle n'était pas pour un veto binaire.
--   * **La colonne `ping_beacons.acc` RESTE, et c'est justifié.** Plus aucune
--     fonction ne la lit, mais ce n'est pas du code mort : c'est une **mesure**.
--     C'est elle qui a permis de diagnostiquer cette panne (± 600 m contre
--     ± 23,8 m), elle part dans les rapports de diagnostic, et le feed local à
--     venir en aura besoin. Un mécanisme mort se supprime ; une donnée relevée
--     se garde.

begin;

-- ---------------------------------------------------------------------------
-- La règle, énoncée une seule fois
-- ---------------------------------------------------------------------------

-- ⚠️ **Le carreau est calculé par le SERVEUR** (`publish_ping_beacon`), donc
-- deux appareils ne peuvent pas être d'accord sur la position et en désaccord
-- sur la grille. C'est ce qui rend cette règle utilisable comme unique juge.
create or replace function private.ping_plausible(
  a_cell_lat integer,
  a_cell_lon integer,
  b_cell_lat integer,
  b_cell_lon integer
) returns boolean
language sql
immutable
as $$
  select abs(a_cell_lat - b_cell_lat) <= 1
     and abs(a_cell_lon - b_cell_lon) <= 1
$$;

comment on function private.ping_plausible(integer, integer, integer, integer) is
  'Assez proche pour être plausible : voisinage de carreaux ±1 (~1 à 3 km). '
  'Seul juge géographique du ping depuis le 2026-08-28 — le BLE fait le reste. '
  'Ne JAMAIS en écrire une seconde définition : le client ne confirme que ce '
  'que la liste lui a donné, donc deux règles qui divergent se contredisent en '
  'silence.';

-- ---------------------------------------------------------------------------
-- La liste d'écoute
-- ---------------------------------------------------------------------------

create or replace function public.ping_shortlist(p_limit integer default 500)
returns table(token text, slot bigint)
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  moi record;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  select b.cell_lat, b.cell_lon, b.lat, b.lon into moi
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
    -- ⚠️ **Le voisinage de carreaux est désormais la RÈGLE, plus un
    -- pré-filtre.** Le filtre fin en mètres qui l'affinait a été retiré le
    -- 2026-08-28 : il croyait l'incertitude annoncée par l'appareil, et une
    -- incertitude annoncée à 400 m qui se trompe de 1 400 m fait disparaître de
    -- la liste des gens réellement côte à côte. Voir l'en-tête de la migration.
    and private.ping_plausible(moi.cell_lat, moi.cell_lon, b.cell_lat, b.cell_lon)
    -- ⚠️ Un blocage coupe AVANT toute écoute : ne pas rendre le jeton, c'est
    -- rendre la personne inaudible, pas seulement invisible.
    and not exists (
      select 1 from public.blocks bl
      where (bl.blocker_id = me and bl.blocked_id = b.user_id)
         or (bl.blocker_id = b.user_id and bl.blocked_id = me)
    )
  -- ⚠️ **Trié par distance, et ce tri survit au retrait du veto.** Il ne décide
  -- plus de qui est visible — seulement de **qui est sacrifié si l'on tronque à
  -- `p_limit`**. Pour un ordre de grandeur, une position approximative suffit ;
  -- pour un oui/non, elle ne suffisait pas. C'est toute la différence.
  order by private.meters_between(moi.lat, moi.lon, b.lat, b.lon) asc
  limit greatest(1, least(p_limit, 2000));
end;
$$;

-- ---------------------------------------------------------------------------
-- La confirmation : ici, le BLE a DÉJÀ prouvé
-- ---------------------------------------------------------------------------

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
  select b.cell_lat, b.cell_lon into moi
  from public.ping_beacons b
  where b.user_id = me
    and b.updated_at > now() - private.ping_beacon_ttl();
  if moi.cell_lat is null then
    return 0;
  end if;

  foreach t in array coalesce(p_tokens, array[]::text[]) loop
    -- ⚠️ **C'est le SERVEUR qui résout jeton -> personne, jamais le client.**
    -- Le client n'a entendu qu'une suite d'octets ; il ne saura de qui il
    -- s'agit que si la réciprocité est établie.
    select b.user_id, b.cell_lat, b.cell_lon into sujet
    from public.ping_beacons b
    where b.token = t
      and b.slot between p_slot - 1 and p_slot + 1
    limit 1;

    if sujet.user_id is null or sujet.user_id = me then
      continue;
    end if;

    -- ⚠️ **Arriver ici veut dire que le BLE a ENTENDU ce jeton.** C'est une
    -- preuve de proximité à une vingtaine de mètres, obtenue sans satellite. La
    -- géographie ne sert plus qu'à écarter l'absurde — un jeton rejoué à
    -- l'autre bout du pays. Elle ne tranche plus une distance qu'elle mesure
    -- moins bien que la radio.
    if not private.ping_plausible(
         moi.cell_lat, moi.cell_lon, sujet.cell_lat, sujet.cell_lon
       ) then
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
$$;

-- ---------------------------------------------------------------------------
-- Le commentaire qui citait une fonction sur le point de disparaître
-- ---------------------------------------------------------------------------

create or replace function public.publish_ping_beacon(
  p_lat double precision,
  p_lon double precision,
  p_token text,
  p_slot bigint,
  p_acc double precision default 0
) returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
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
    -- ⚠️ **`acc` n'est plus lue par aucune règle depuis le 2026-08-28**, et
    -- c'est délibéré : elle décidait qui était visible, en croyant une précision
    -- que l'appareil n'atteignait pas. Elle reste **enregistrée** parce que
    -- c'est une mesure — celle qui a permis de diagnostiquer la panne, celle qui
    -- part dans les rapports, celle dont le feed local aura besoin. Une valeur
    -- négative vaut « inconnue », donc 0.
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
$$;

-- ---------------------------------------------------------------------------
-- Ce qui n'a plus d'appelant part avec la règle qu'il servait
-- ---------------------------------------------------------------------------

-- ⚠️ **Les laisser aurait été pire que les supprimer.** Une fonction qui porte
-- un nom de barrière de sécurité et que plus personne n'appelle se lit, un jour,
-- comme une protection encore en place. C'est exactement le piège du
-- `cascade` : PostgreSQL ne voit aucune dépendance dans le corps d'une fonction
-- (stocké comme du texte), donc rien ici ne se serait signalé tout seul.
drop function if exists private.ping_reach(double precision, double precision);
drop function if exists private.ping_radius_min();

commit;
