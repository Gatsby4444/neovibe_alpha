-- PING v2 — le GPS oriente, le BLE prouve.
-- Architecture décidée par Jay le 2026-08-25. Détail : docs/proximite-v2-gps-et-ble.md
--
-- ## Le renversement
--
-- Le BLE cessait d'être la techno de base pour devenir un **outil de
-- vérification**. Mesuré au premier test à deux appareils : il est mauvais à
-- transporter (0 trame livrée), incapable de passer l'échelle en découverte
-- (une connexion GATT par inconnu, plafond ~7 sur Android), mais **excellent à
-- prouver une co-présence** — un croisement d'amis a été enregistré du premier
-- coup.
--
-- Sa force unique : **une portée de 10 mètres ne se falsifie pas.** Pas de VPN,
-- pas de position déclarée. Tout le reste, Internet le fait mieux.
--
-- ## Pourquoi le GPS ne fait PAS les 20 m, et pourquoi ce n'est pas grave
--
-- Précision réelle : 4-10 m plein ciel, 10-30 m en ville, **20-100 m en
-- intérieur** (repli WiFi) — or c'est en intérieur qu'on se rencontre. À 20 m
-- de seuil le signal est sous le bruit, dans les deux sens : des gens côte à
-- côte invisibles, des gens d'un autre bâtiment affichés.
--
-- D'où le partage : le GPS ne sert qu'à une **cellule d'environ 1 km**, que même
-- le pire repli WiFi donne juste. La précision vient du BLE, qui ne dépend
-- d'aucun satellite. **Cette architecture est indifférente à la qualité du
-- GPS** — aucune variante « GPS précis » ne peut l'être.
--
-- ## ⚠️ Ce que le serveur NE sait PAS, et c'est délibéré
--
-- Il connaît une **cellule d'un kilomètre**, jamais une position. Et la liste
-- qu'il rend ne contient **que des jetons opaques** : ni profils, ni
-- identifiants, ni nombre de personnes distinctes. Elle est inexploitable sans
-- être physiquement là.
--
-- Si le serveur rendait les profils de la cellule, il suffirait d'être dans le
-- quartier pour voir tout le monde — et la thèse du produit (la présence
-- physique est la barrière) tomberait au premier client modifié.
--
-- ## ⚠️ La réciprocité — même règle que pour les amis (#55)
--
-- **Un profil n'est révélé que si les DEUX se sont entendus.** Écouter sans
-- s'annoncer ne donne rien : pas de profil, pas de conversation. On ne peut pas
-- observer sans être observable, et ce n'est pas une règle appliquée quelque
-- part — c'est la seule façon dont une ligne de `ping_pairs` peut naître.

-- ---------------------------------------------------------------------------
-- La maille géographique
-- ---------------------------------------------------------------------------

-- Côté du carreau, en degrés. 0,01° ≈ 1,11 km en latitude et ≈ 0,79 km en
-- longitude à 45°.
--
-- ⚠️ **Des ENTIERS, pas un geohash.** Calculer les 8 voisins d'un geohash en
-- SQL demande une extension ou une table de correspondance ; avec deux entiers,
-- le voisinage est `between x-1 and x+1`, sans dépendance et sans cas
-- particulier aux bords de maille.
create or replace function private.ping_cell_size()
returns double precision language sql immutable as $$ select 0.01::double precision $$;

-- Fraîcheur d'une balise. Au-delà, la personne est considérée partie : sa
-- balise n'apparaît plus dans aucune liste.
create or replace function private.ping_beacon_ttl()
returns interval language sql immutable as $$ select interval '5 minutes' $$;

-- ---------------------------------------------------------------------------
-- Les balises : qui s'annonce, dans quel carreau, avec quel jeton
-- ---------------------------------------------------------------------------

create table if not exists public.ping_beacons (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  cell_lat   int  not null,
  cell_lon   int  not null,
  -- Le jeton public du créneau courant, en hexadécimal.
  --
  -- ⚠️ **Du texte et non du `bytea`** : un `bytea` traverse PostgREST en base64
  -- avec des règles d'échappement qui varient, et devient illisible au
  -- diagnostic. Le jeton n'est pas un secret — c'est un identifiant public déjà
  -- calculé, inutilisable pour en fabriquer d'autres.
  token      text not null,
  slot       bigint not null,
  updated_at timestamptz not null default now()
);

create index if not exists ping_beacons_cell_idx
  on public.ping_beacons (cell_lat, cell_lon, updated_at);
-- L'index de la résolution : la question posée à chaque confirmation.
create index if not exists ping_beacons_token_idx
  on public.ping_beacons (token, slot);

alter table public.ping_beacons enable row level security;

-- ⚠️ **Aucune politique, dans aucun sens.** Le seul chemin est par fonction.
-- Une politique de SELECT rendrait la table lisible directement — c'est-à-dire
-- exactement la liste des gens d'un quartier, ce que toute cette conception
-- existe pour empêcher. Règle 3 de CLAUDE.md : compter les chemins.

-- ---------------------------------------------------------------------------
-- Publier sa balise
-- ---------------------------------------------------------------------------

create or replace function public.publish_ping_beacon(
  p_lat double precision,
  p_lon double precision,
  p_token text,
  p_slot bigint
)
returns void
language plpgsql
security definer
set search_path = public, private
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

  -- ⚠️ **La position est réduite au carreau ICI, côté serveur.** Si le client
  -- envoyait déjà le carreau, la table dépendrait de ce qu'il veut bien
  -- arrondir ; si le serveur gardait la position exacte « au cas où », elle
  -- finirait par être lue. On la reçoit, on l'arrondit, on ne la garde pas.
  insert into public.ping_beacons (user_id, cell_lat, cell_lon, token, slot)
  values (
    me,
    floor(p_lat / private.ping_cell_size())::int,
    floor(p_lon / private.ping_cell_size())::int,
    p_token,
    p_slot
  )
  on conflict (user_id) do update
    set cell_lat = excluded.cell_lat,
        cell_lon = excluded.cell_lon,
        token = excluded.token,
        slot = excluded.slot,
        updated_at = now();
end;
$$;

-- Cesser de s'annoncer. ⚠️ **Une ligne supprimée, pas un drapeau posé** : un
-- drapeau laisserait la position en base après que l'utilisateur a coupé le
-- ping, ce qui est précisément ce qu'il vient de refuser.
create or replace function public.retire_ping_beacon()
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  delete from public.ping_beacons where user_id = auth.uid();
end;
$$;

-- ---------------------------------------------------------------------------
-- La liste à écouter — DES JETONS, RIEN D'AUTRE
-- ---------------------------------------------------------------------------

-- ⚠️ **Ne rend ni profil, ni identifiant, ni compte.** C'est une liste de choses
-- à écouter, pas une liste de gens. Sans être physiquement à portée BLE de l'un
-- d'eux, elle n'apprend rigoureusement rien.
--
-- ⚠️ **Le carreau vient de MA propre balise**, jamais d'un paramètre : sinon
-- n'importe qui interrogerait n'importe quel quartier sans y être.
create or replace function public.ping_shortlist(p_limit int default 500)
returns table (token text, slot bigint)
language plpgsql
security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  my_lat int;
  my_lon int;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  select b.cell_lat, b.cell_lon into my_lat, my_lon
  from public.ping_beacons b
  where b.user_id = me
    and b.updated_at > now() - private.ping_beacon_ttl();

  -- Pas de balise à moi = pas de liste. **On n'écoute que si on s'annonce.**
  if my_lat is null then
    return;
  end if;

  return query
  select b.token, b.slot
  from public.ping_beacons b
  where b.user_id <> me
    and b.updated_at > now() - private.ping_beacon_ttl()
    and b.cell_lat between my_lat - 1 and my_lat + 1
    and b.cell_lon between my_lon - 1 and my_lon + 1
    -- ⚠️ Un blocage coupe AVANT toute écoute : ne pas rendre le jeton, c'est
    -- rendre la personne inaudible, pas seulement invisible.
    and not exists (
      select 1 from public.blocks bl
      where (bl.blocker_id = me and bl.blocked_id = b.user_id)
         or (bl.blocker_id = b.user_id and bl.blocked_id = me)
    )
  order by b.updated_at desc
  limit greatest(1, least(p_limit, 2000));
end;
$$;

-- ---------------------------------------------------------------------------
-- Les confirmations : « j'ai ENTENDU ce jeton »
-- ---------------------------------------------------------------------------

-- Même forme que `sightings`, et c'est voulu : c'est le même fait — un constat
-- unilatéral qui attend son miroir.
create table if not exists public.ping_confirmations (
  observer_id uuid not null references public.profiles(id) on delete cascade,
  subject_id  uuid not null references public.profiles(id) on delete cascade,
  slot        bigint not null,
  created_at  timestamptz not null default now(),
  primary key (observer_id, subject_id, slot),
  constraint ping_confirmations_not_self check (observer_id <> subject_id)
);

create index if not exists ping_confirmations_created_idx
  on public.ping_confirmations (created_at);
create index if not exists ping_confirmations_mirror_idx
  on public.ping_confirmations (subject_id, observer_id, slot);

alter table public.ping_confirmations enable row level security;

drop policy if exists ping_confirmations_own on public.ping_confirmations;
create policy ping_confirmations_own on public.ping_confirmations
  for select using (observer_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Les paires : la proximité MUTUELLE, et elle seule ouvre quelque chose
-- ---------------------------------------------------------------------------

create table if not exists public.ping_pairs (
  user_low      uuid not null references public.profiles(id) on delete cascade,
  user_high     uuid not null references public.profiles(id) on delete cascade,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  primary key (user_low, user_high),
  constraint ping_pairs_ordered check (user_low < user_high)
);

create index if not exists ping_pairs_last_seen_idx
  on public.ping_pairs (last_seen_at);

alter table public.ping_pairs enable row level security;

drop policy if exists ping_pairs_own on public.ping_pairs;
create policy ping_pairs_own on public.ping_pairs
  for select using (user_low = auth.uid() or user_high = auth.uid());

-- ---------------------------------------------------------------------------
-- Déposer ses confirmations, et faire naître les paires
-- ---------------------------------------------------------------------------

create or replace function public.confirm_ping(p_tokens text[], p_slot bigint)
returns int
language plpgsql
security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  now_slot bigint := floor(extract(epoch from now()) / private.slot_seconds());
  t text;
  subject uuid;
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

  foreach t in array coalesce(p_tokens, array[]::text[]) loop
    -- ⚠️ **C'est le SERVEUR qui résout jeton -> personne, jamais le client.**
    -- Le client n'a entendu qu'une suite d'octets ; il ne saura de qui il
    -- s'agit que si la réciprocité est établie.
    select b.user_id into subject
    from public.ping_beacons b
    where b.token = t
      and b.slot between p_slot - 1 and p_slot + 1
    limit 1;

    if subject is null or subject = me then
      continue;
    end if;

    insert into public.ping_confirmations (observer_id, subject_id, slot)
    values (me, subject, p_slot)
    on conflict (observer_id, subject_id, slot) do nothing;

    retenus := retenus + 1;

    -- ⚠️ **LE MIROIR : c'est ici, et seulement ici, qu'une paire naît.**
    -- Un créneau d'écart toléré de part et d'autre : deux téléphones n'ont
    -- jamais exactement la même heure.
    if exists (
      select 1 from public.ping_confirmations m
      where m.observer_id = subject
        and m.subject_id = me
        and m.slot between p_slot - 1 and p_slot + 1
    ) then
      lo := least(me, subject);
      hi := greatest(me, subject);
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
-- Qui est là — les profils, enfin
-- ---------------------------------------------------------------------------

-- ⚠️ **La FRAÎCHEUR n'est PAS décidée ici.** Le serveur rend le fait
-- (`last_seen_at`) ; c'est la vue qui décide ce qu'elle affiche, avec sa propre
-- horloge — y compris les 30 s d'indulgence voulues par Jay. Règle de
-- dissociation : qui acquiert publie fidèlement, qui consomme décide.
create or replace function public.ping_nearby()
returns table (
  user_id uuid,
  display_name text,
  tag_name text,
  avatar_url text,
  last_seen_at timestamptz
)
language plpgsql
security definer
set search_path = public, private
as $$
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
  order by pp.last_seen_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- La messagerie de proximité : elle exige d'avoir été VRAIMENT à portée
-- ---------------------------------------------------------------------------

-- ⚠️ **Barrière ajoutée le 2026-08-25.** Cette fonction existait déjà et
-- refusait les amis — la séparation des deux messageries était donc en place.
-- Mais **rien ne vérifiait la proximité** : en v1 c'était couvert par le fait
-- qu'on n'apprenait l'identifiant du pair qu'en étant physiquement là, par la
-- poignée de main BLE. En v2 le serveur résout les identités, donc la barrière
-- doit être écrite. Sans elle, un identifiant deviné ouvrirait une
-- conversation — exactement la « découverte par annuaire » que le produit
-- interdit.
create or replace function public.get_or_create_proximity_conversation(peer uuid)
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  key text;
  conv_id uuid;
begin
  if are_connected(me, peer) then
    raise exception 'Déjà connectés : utilisez la messagerie directe';
  end if;

  if not exists (
    select 1 from public.ping_pairs pp
    where ((pp.user_low = me and pp.user_high = peer)
        or (pp.user_low = peer and pp.user_high = me))
      and pp.last_seen_at > now() - interval '10 minutes'
  ) then
    raise exception 'Proximité non constatée';
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

-- ---------------------------------------------------------------------------
-- Ménage
-- ---------------------------------------------------------------------------

create or replace function public.purge_ping()
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  -- Une balise périmée n'est pas seulement inutile : c'est une position
  -- conservée après coup, et rien ne la justifie.
  delete from public.ping_beacons where updated_at < now() - interval '15 minutes';
  -- Une confirmation qui n'a pas trouvé son miroir en une heure ne le trouvera
  -- plus : les deux créneaux tolérés sont largement dépassés.
  delete from public.ping_confirmations where created_at < now() - interval '1 hour';
  -- Une paire au-delà de la journée n'ouvre plus rien.
  delete from public.ping_pairs where last_seen_at < now() - interval '24 hours';
end;
$$;

revoke all on function public.purge_ping() from public, anon, authenticated;

-- ⚠️ **Un job à part, jamais greffé sur un existant.** Un job est une
-- transaction : y ajouter une nouveauté, c'est faire échouer l'ancien ménage le
-- jour où la nouveauté échoue (RAPPELS #14).
select cron.unschedule('neovibe_purge_ping')
where exists (select 1 from cron.job where jobname = 'neovibe_purge_ping');

select cron.schedule('neovibe_purge_ping', '*/5 * * * *', $$ select public.purge_ping() $$);

-- ---------------------------------------------------------------------------
-- Droits — une fonction citée par une politique doit être exécutable (#RLS)
-- ---------------------------------------------------------------------------

grant execute on function public.publish_ping_beacon(double precision, double precision, text, bigint) to authenticated;
grant execute on function public.retire_ping_beacon() to authenticated;
grant execute on function public.ping_shortlist(int) to authenticated;
grant execute on function public.confirm_ping(text[], bigint) to authenticated;
grant execute on function public.ping_nearby() to authenticated;
