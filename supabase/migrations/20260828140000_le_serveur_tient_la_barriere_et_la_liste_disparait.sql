-- 🔴 Le BLOCAGE était tenu par le CLIENT — et la liste d'écoute disparaît.
--
-- ## ⚠️ Ce que la vérification a trouvé, et qui n'était pas le sujet
--
-- Jay demandait de vérifier si `ping_shortlist` servait encore à quelque chose.
-- Réponse : **oui, à une seule chose, et personne ne le savait** — c'était le
-- seul endroit du chemin ping où un blocage était appliqué.
--
-- Rejoué en base le 2026-08-28, blocage actif, sous les deux identités :
--
-- | Étape | Résultat |
-- |---|---|
-- | `ping_shortlist` refuse de rendre le jeton | ✅ 0 ligne |
-- | un client qui **ignore la liste** et appelle `confirm_ping` | 🔴 **accepté** |
-- | une **paire** naît entre deux personnes qui se sont bloquées | 🔴 **oui** |
-- | `request_connection_from_proximity` | 🔴 **acceptée** |
--
-- ⚠️ **La barrière du blocage était donc appliquée par le téléphone.** Un
-- client modifié — ou simplement un futur client iOS qui n'aurait pas reproduit
-- ce filtre — la contournait entièrement. C'est la règle 4 de `CLAUDE.md` prise
-- à l'envers : une sécurité qui s'énonce par une négation (« tant que le client
-- n'envoie pas ce qu'on ne lui a pas donné ») a une date de péremption.
--
-- ⚠️ **Ce trou existait dans la v0.9.143**, indépendamment de ce chantier. Il
-- serait resté invisible : rien ne lève, rien ne s'affiche, et le parcours
-- normal se comporte correctement parce que le client, lui, respecte la liste.
--
-- ## Ce que la liste faisait vraiment, vérifié et non supposé
--
-- Elle avait été créée pour ménager les limites BLE des OS. **Cette raison
-- était vraie, et elle a expiré le 2026-08-25** — le jour où le serveur a pris
-- la résolution d'identité et où le ping public a cessé d'ouvrir la moindre
-- connexion GATT (`RAPPELS.md` #65). Le plafond d'environ 7 connexions
-- simultanées était le mur d'échelle ; il n'existe plus dans ce chemin.
--
-- Relevé dans le code natif le 2026-08-28 :
--
--   * `BleEngine.startScanning` installe `ScanFilter.Builder().build()` — un
--     filtre **vide, qui accepte tout**. Le tri par jeton se fait **en
--     logiciel, après** que la puce a reçu et décodé l'annonce.
--   * `grep connectGatt|BluetoothGatt|openGattServer` sur tout `ble/` : **zéro
--     résultat**.
--   * `_shortlist` a **un seul lecteur** en Dart (le filtre logiciel) et
--     **aucun** en Kotlin.
--
-- **La liste ne protégeait donc aucune limite radio. Elle ne servait qu'à
-- limiter ce qu'on rapporte au serveur — et ce contrôle est fait deux fois
-- depuis la migration `20260828120000`.**
--
-- ## Ce que sa disparition supprime, d'un coup
--
--   * le **trou du changement de créneau** : tous les jetons tournaient en même
--     temps, la liste avait jusqu'à 60 s de retard, et **tout le monde devenait
--     aveugle quatre fois par heure**. Il n'y a plus de liste à être périmée.
--   * le **plafond de 500** : au-delà, on n'écoutait que les 500 plus proches.
--   * ~**90 % du trafic du ping** : on téléchargeait des centaines de jetons
--     (dimensionnés par le carreau, 1 à 3 km) pour en reconnaître trois
--     (dimensionnés par la portée BLE, ~30 m). 30 Ko/min contre ~600 o.
--
-- ## Le coût, énoncé sans détour
--
--   * le serveur voit désormais aussi les jetons entendus qui **échouent** au
--     contrôle de carreau (GPS faux, relais). Ils sont refusés, mais ils sont
--     vus. C'est la seule donnée en plus.
--   * le compteur « N personnes ont le ping actif » venait de la taille de la
--     liste : il devient `ping_neighbour_count`, qui ne rend **qu'un entier**.
--
-- ## Sens entrant / sens sortant (règle 8), relevés en base
--
--   * **qui appelle `ping_shortlist`** : `ping_repository.dart:75`, et rien
--     d'autre. Aucune fonction, aucune politique, aucune vue, aucun job. La
--     seule occurrence côté serveur est un **commentaire** dans `confirm_ping`,
--     réécrit ici.
--   * **ce qu'elle appelait** : `ping_beacon_ttl`, `ping_plausible`,
--     `meters_between`, `blocks`. Les trois premières gardent d'autres
--     appelants (voir ci-dessous) ; la table `blocks` n'est évidemment pas
--     concernée.
--   * ⚠️ **`private.meters_between` perd ici son DERNIER appelant** — elle ne
--     servait plus qu'au tri par distance de la liste. Elle est **conservée**,
--     et c'est justifié : c'est une fonction de calcul pure, sans nom de
--     barrière, dont le feed local et le clustering (`RAPPELS.md` #36) auront
--     besoin. Une fonction morte qui ressemble à une protection se supprime ;
--     une formule ne trompe personne.

begin;

-- ---------------------------------------------------------------------------
-- 1. LA CORRECTION DE SÉCURITÉ — elle vaut indépendamment du reste
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

  -- ⚠️ **Anti-antidatage** (#55). Un créneau dans le futur ou vieux de plus
  -- d'une heure est refusé : la seule chose qu'on puisse borner est
  -- l'ancienneté, deux complices pouvant toujours s'accorder sur le présent.
  if p_slot > now_slot + 1 or p_slot < now_slot - 4 then
    return 0;
  end if;

  -- ⚠️ **Ma propre balise est exigée : on n'écoute que si on s'annonce.**
  --
  -- ⚠️ **Cette règle est désormais ICI et nulle part ailleurs.** Elle vivait
  -- aussi dans `ping_shortlist`, qui disparaît plus bas. Tant qu'elle était
  -- dans les deux, on pouvait croire qu'en retirer une n'avait pas
  -- d'importance — c'est exactement ce qui a failli arriver au blocage.
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

    -- 🔴 **LE BLOCAGE, ENFIN TENU PAR LE SERVEUR.**
    --
    -- Il n'était appliqué que par `ping_shortlist` : ne pas rendre le jeton
    -- rendait la personne inaudible — **à condition que le client s'en tienne
    -- à la liste**. Rejoué en base le 2026-08-28 : un appel direct à cette
    -- fonction créait une paire, puis une demande d'ami, entre deux personnes
    -- qui s'étaient bloquées.
    --
    -- ⚠️ **Coupe AVANT la confirmation, pas seulement à l'affichage.** Une
    -- confirmation crée une paire ; une paire ouvre la demande d'ami
    -- (`request_connection_from_proximity`) et le chat de proximité
    -- (`get_or_create_proximity_conversation`), et **aucune des deux ne
    -- regarde les blocages**. C'est la paire qu'il faut empêcher, pas son
    -- affichage.
    if private.is_blocked(me, sujet.user_id) then
      continue;
    end if;

    -- ⚠️ **Arriver ici veut dire que le BLE a ENTENDU ce jeton** — une preuve
    -- de proximité à une vingtaine de mètres, obtenue sans satellite. La
    -- géographie n'écarte plus que l'absurde (2026-08-28, décision de Jay).
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
-- 2. LE COMPTEUR — ce qui reste de la liste, réduit à ce qu'on en affichait
-- ---------------------------------------------------------------------------

-- ⚠️ **Il ne rend qu'un ENTIER, et c'est tout l'intérêt.** L'écran n'a jamais
-- affiché que ce nombre ; on téléchargeait jusqu'à 30 Ko de jetons pour
-- l'obtenir. Il vaut ~10 octets.
--
-- ⚠️ **Il n'est PAS tronqué**, contrairement à la liste : `count(*)` sur
-- l'index de carreau rend le vrai nombre. Le champ « c'est un plancher, pas un
-- total » disparaît donc côté client — non parce qu'on renonce à la règle, mais
-- parce qu'elle n'a plus de sujet.
create or replace function public.ping_neighbour_count()
returns integer
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  moi record;
  n integer;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  select b.cell_lat, b.cell_lon into moi
  from public.ping_beacons b
  where b.user_id = me
    and b.updated_at > now() - private.ping_beacon_ttl();

  -- Pas de balise à moi = pas de compte. **On n'écoute que si on s'annonce**,
  -- et compter est déjà une forme d'écoute.
  if moi.cell_lat is null then
    return 0;
  end if;

  select count(*) into n
  from public.ping_beacons b
  where b.user_id <> me
    and b.updated_at > now() - private.ping_beacon_ttl()
    and private.ping_plausible(moi.cell_lat, moi.cell_lon, b.cell_lat, b.cell_lon)
    -- ⚠️ Même règle qu'ailleurs, une seule définition : `private.is_blocked`.
    -- La liste réécrivait ce test à la main, ce qui faisait deux endroits où
    -- l'oublier.
    and not private.is_blocked(me, b.user_id);

  return coalesce(n, 0);
end;
$$;

comment on function public.ping_neighbour_count() is
  'Combien de balises fraîches dans le voisinage de carreaux. Un entier, rien '
  'd''autre : ni jeton, ni identifiant, ni position. Remplace ping_shortlist, '
  'dont c''était le seul usage visible à l''écran (2026-08-28).';

-- ---------------------------------------------------------------------------
-- 3. LA LISTE DISPARAÎT
-- ---------------------------------------------------------------------------

-- ⚠️ **La garder « au cas où » aurait été le pire choix.** Une fonction qui
-- distribue des jetons et applique un filtre de blocage se lit comme une
-- barrière ; tant qu'elle existe, on peut croire que la barrière est là. Elle
-- est maintenant dans `confirm_ping`, à l'endroit où elle décide vraiment de
-- quelque chose.
drop function if exists public.ping_shortlist(integer);

commit;
