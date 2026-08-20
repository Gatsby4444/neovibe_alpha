-- La RÉCIPROCITÉ SERVEUR : un croisement n'existe que si les DEUX se sont vus.
-- Décision de Jay, 2026-08-20 (RAPPELS #55, option ②).
--
-- ## Le problème qu'elle résout
--
-- Un croisement exigeait jusqu'ici un **certificat co-signé** : les deux
-- téléphones devaient ouvrir une connexion GATT vivante et échanger deux
-- signatures. Or c'est cher et fragile — il faut que les deux apps soient
-- réveillées **au même instant**, que la pile Bluetooth soit disponible, et que
-- la connexion aboutisse. Dans une salle pleine, elle n'aboutit souvent pas.
--
-- Ici, chacun **constate** de son côté (« j'ai vu le jeton de X au créneau S »)
-- et le remonte quand il a du réseau. Le serveur ne retient un croisement que
-- si le constat inverse existe aussi. Aucune connexion n'est nécessaire.
--
-- ## ⚠️ La propriété anti-traque, et elle est STRUCTURELLE
--
-- **Un constat unilatéral ne produit RIEN.** Celui qui écoute sans jamais
-- s'annoncer n'obtient aucun croisement, aucune notification, aucun historique.
-- On ne peut pas observer sans être observé — ce n'est pas une règle qu'on
-- applique, c'est la seule façon dont une ligne de `encounters` peut naître par
-- ce chemin.
--
-- ## ⚠️ Ce que le serveur apprend, et c'est le prix assumé
--
-- Cette table EST le graphe des croisements. Jay l'a tranché en connaissance de
-- cause le 2026-08-20. Trois garde-fous, tous ici et non dans le client :
--
--   1. on ne peut déposer un constat que **sur soi-même comme observateur** ;
--   2. on ne peut constater que des **amis confirmés** (`status = 'full'`) ;
--   3. les constats **non appariés sont purgés** — ils ne servent qu'à attendre
--      leur miroir, et un constat qui n'a pas trouvé le sien en 48 h ne le
--      trouvera plus.
--
-- ## ⚠️ Anti-antidatage
--
-- Le créneau déclaré doit être proche de l'heure du SERVEUR. Sans cela, on
-- pourrait prétendre avoir croisé quelqu'un la semaine dernière — et comme deux
-- complices peuvent toujours s'accorder, la seule chose qu'on puisse vraiment
-- borner est l'ancienneté.

-- Durée d'un créneau, en secondes. Doit rester égale à
-- `ProximityIdentity.slotDuration` côté Dart (15 min).
create or replace function private.slot_seconds()
returns int language sql immutable as $$ select 900 $$;

create table if not exists public.sightings (
  observer_id uuid not null references public.profiles(id) on delete cascade,
  seen_id     uuid not null references public.profiles(id) on delete cascade,
  slot        bigint not null,
  -- Bande de proximité, jamais une distance en mètres : une distance au mètre
  -- près transformerait une app de rencontre en outil de traque (spec 4.2).
  band        text,
  created_at  timestamptz not null default now(),
  primary key (observer_id, seen_id, slot),
  constraint sightings_not_self check (observer_id <> seen_id)
);

create index if not exists sightings_created_idx on public.sightings (created_at);
-- L'index du miroir : c'est la question posée à chaque insertion.
create index if not exists sightings_mirror_idx
  on public.sightings (seen_id, observer_id, slot);

alter table public.sightings enable row level security;

-- ⚠️ **Aucune politique d'INSERT, et c'est délibéré.** Le seul chemin d'écriture
-- est la fonction `report_sightings`, qui valide l'amitié et l'ancienneté. Une
-- politique d'insert directe rouvrirait un second chemin aux règles plus
-- permissives — c'est exactement ce que la règle d'architecture interdit.
drop policy if exists sightings_own on public.sightings;
create policy sightings_own on public.sightings
  for select using (observer_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Comment un croisement naît : par quel chemin, et avec quelle preuve
-- ---------------------------------------------------------------------------

-- ⚠️ **Deux chemins mènent désormais à `encounters`, et ils n'ont pas la même
-- force.** Les confondre ferait gagner la règle la plus permissive, en silence.
-- La colonne le dit donc explicitement :
--
--   'certificate'     — deux signatures Ed25519 échangées en direct. Le plus
--                       fort : infalsifiable sans les deux clés privées.
--   'mutual_sighting' — deux constats concordants. Plus faible : deux complices
--                       peuvent le fabriquer sans s'être rencontrés.
--
-- Conséquence encodée plus bas : un constat mutuel **ne rétrograde jamais** un
-- croisement déjà prouvé par certificat.
alter table public.encounters
  add column if not exists proof text not null default 'certificate';

comment on column public.encounters.proof is
  'certificate (deux signatures en direct) ou mutual_sighting (deux constats concordants). Ne jamais rétrograder.';

-- ---------------------------------------------------------------------------
-- Le dépôt des constats
-- ---------------------------------------------------------------------------

create or replace function public.report_sightings(items jsonb)
returns int
language plpgsql
security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  item jsonb;
  peer uuid;
  s bigint;
  now_slot bigint := floor(extract(epoch from now()) / private.slot_seconds());
  retenus int := 0;
  lo uuid;
  hi uuid;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  for item in select * from jsonb_array_elements(items) loop
    peer := (item->>'peer')::uuid;
    s := (item->>'slot')::bigint;

    if peer is null or s is null or peer = me then
      continue;
    end if;

    -- ⚠️ **Anti-antidatage.** Un créneau dans le futur, ou vieux de plus de
    -- 48 h, est refusé. C'est la seule borne réelle : deux complices peuvent
    -- toujours s'accorder sur le présent, jamais réécrire le passé.
    if s > now_slot + 1 or s < now_slot - (48 * 3600 / private.slot_seconds()) then
      continue;
    end if;

    -- ⚠️ **On ne constate que des amis confirmés.** Sans cette borne, la table
    -- deviendrait un canal d'observation vers n'importe qui.
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

    retenus := retenus + 1;

    -- ⚠️ **LE MIROIR : c'est ici, et seulement ici, qu'un croisement naît.**
    --
    -- On accepte un créneau d'écart de part et d'autre : deux téléphones n'ont
    -- jamais exactement la même heure, et une même rencontre peut tomber de
    -- part et d'autre d'un changement de créneau. Sans cette tolérance, une
    -- rencontre sur deux serait perdue — silencieusement.
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
            -- Ne JAMAIS rétrograder une preuve par certificat.
            proof = case
                      when encounters.proof = 'certificate' then 'certificate'
                      else excluded.proof
                    end;
    end if;
  end loop;

  return retenus;
end;
$$;

-- ⚠️ Doit être exécutable par `authenticated` : une fonction du schéma `public`
-- appelée par `/rest/v1/rpc/` n'a aucun autre moyen d'être atteinte. (Panne du
-- 2026-08-11 : révoquer l'exécution casse tout et ne protège de rien.)
revoke all on function public.report_sightings(jsonb) from public;
grant execute on function public.report_sightings(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- La purge
-- ---------------------------------------------------------------------------

-- ⚠️ **Un constat ne sert qu'à attendre son miroir.** Passé 48 h, celui qui
-- n'en a pas trouvé n'en trouvera plus : le garder ne fait qu'accumuler un
-- graphe de qui a vu qui, sans aucune contrepartie. Ce que le serveur apprend
-- est le prix assumé de la réciprocité ; le garder plus longtemps que
-- nécessaire ne l'est pas.
create or replace function public.purge_sightings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  supprimes int;
begin
  delete from public.sightings where created_at < now() - interval '48 hours';
  get diagnostics supprimes = row_count;
  return supprimes;
end;
$$;

revoke all on function public.purge_sightings() from public;

-- ⚠️ **UN JOB SÉPARÉ, jamais greffé sur `neovibe_purge`.** Un job = une
-- transaction : une nouveauté qui échoue emporterait avec elle toutes les
-- purges déjà en place, et personne ne le verrait — une tâche planifiée qui
-- échoue est silencieuse. (Règle du projet, payée le 2026-08-13.)
--
-- ⚠️ **48 h alors que `encounters` est purgé à 24 h.** Ce n'est pas une
-- incohérence : un constat doit survivre assez longtemps pour que le miroir
-- arrive, y compris si le téléphone d'en face est resté hors ligne une journée
-- entière. C'est le seul motif de cette durée — si Jay veut la raccourcir, le
-- prix est de perdre les croisements dont un côté tarde à se reconnecter.
select cron.schedule('neovibe_purge_sightings', '17 * * * *',
  $cron$ select public.purge_sightings(); $cron$);
