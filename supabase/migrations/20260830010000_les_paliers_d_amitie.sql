-- ===========================================================================
-- LES PALIERS D'AMITIÉ — décision de Jay, 2026-08-29
-- ===========================================================================
--
-- « Des paliers d'amitié comme sur Snap, mais qui ici débloqueront de vraies
-- choses. »  Ses quatre arbitrages, le 2026-08-29 :
--
--   1. la montée est **automatique** : l'app constate, l'utilisateur ne range
--      rien ;
--   2. **deux paliers au-dessus d'« ami », et ça REDESCEND** — « la relation
--      reste vivante au lieu d'être un trophée » ;
--   3. ils débloquent : les stories réservées, le droit d'envoyer un Rush, et
--      la présence en direct ;
--   4. les paliers passent AVANT tout ce qui les affiche.
--
-- ---------------------------------------------------------------------------
-- ⚠️ POURQUOI UNE COLONNE `tier` ET NON UNE VALEUR DE `connection_status`
-- ---------------------------------------------------------------------------
--
-- `RAPPELS.md` #86 prévoyait de loger les paliers dans le type
-- `connection_status`, par `alter type … add value`. **Cette décision est
-- rejouée ici, parce que sa prémisse a changé** : on ne savait pas encore, le
-- 2026-08-28, que les paliers seraient AUTOMATIQUES et RÉVERSIBLES.
--
-- Or ce sont deux objets qui n'obéissent pas aux mêmes règles :
--
--   | | `status` | `tier` |
--   |---|---|---|
--   | répond à | « le lien existe-t-il ? » | « à quel point sont-ils proches ? » |
--   | qui l'écrit | l'acceptation d'une demande | une dérivation, toute seule |
--   | change quand | jamais, sauf rupture | tout seul, dans les deux sens |
--
-- Les fondre dans un seul type, c'est la règle 2 de `CLAUDE.md` prise à
-- l'envers : `private.has_any_connection` ne teste que l'EXISTENCE d'une ligne.
-- Un contrôle d'accès écrit avec elle donnerait donc les droits du palier le
-- plus haut à tout le monde, **en silence**.
--
-- ---------------------------------------------------------------------------
-- L'ARCHITECTURE, EN TROIS ÉTAGES QUI NE SE MÉLANGENT PAS
-- ---------------------------------------------------------------------------
--
--   ACQUISITION   `meeting_days` — un jour où deux amis se sont croisés.
--                 Écrit à un SEUL endroit (`report_sightings`), idempotent,
--                 et ne décide de rien.
--
--   DÉRIVATION    `days_met` → `tier_for_days`. Le seuil est écrit une fois.
--                 Le résultat est RANGÉ sur `connections`, parce que des
--                 politiques RLS vont le lire à chaque ligne.
--
--   USAGE         les politiques, les écrans. Ils lisent une colonne, ils ne
--                 recomptent rien, et ils ne connaissent aucun seuil.
--
-- ⚠️ **Pourquoi ranger le résultat plutôt que le recalculer.** Le compte porte
-- sur des JOURS : il ne peut donc changer qu'à un changement de jour, ou à une
-- nouvelle rencontre. Une tâche quotidienne n'est donc pas un cache qui
-- approxime — c'est l'évaluation EXACTE à chaque pas de la fenêtre.
--
-- ---------------------------------------------------------------------------
-- ⚠️ `meeting_days` N'EST PAS `encounters`, ET NE DOIT JAMAIS LE REMPLACER
-- ---------------------------------------------------------------------------
--
--   * `encounters` dit « ces deux-là se sont croisés **récemment** » et vit
--     24 h. C'est lui qui ouvre le profil d'un inconnu croisé
--     (`private.can_view_profile`) et ses stories publiques.
--   * `meeting_days` dit « ces deux-là se sont croisés **le jour J** » et vit
--     indéfiniment. Il ne donne accès à RIEN.
--
-- 🔴 **Brancher un droit de lecture sur `meeting_days` transformerait une
-- fenêtre de 24 h en fenêtre éternelle**, sans qu'aucune erreur ne le dise.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Le palier, comme TYPE ordonné
-- ---------------------------------------------------------------------------
--
-- ⚠️ **L'ordre de déclaration EST l'ordre de comparaison** en PostgreSQL :
-- c'est ce qui rend `tier >= 'close'` possible, et c'est la seule raison pour
-- laquelle ces trois valeurs sont dans cet ordre-là. Insérer une valeur au
-- milieu plus tard demandera `alter type … add value … before …`, jamais un
-- simple `add value`.
create type public.friendship_tier as enum ('friend', 'close', 'inner');

comment on type public.friendship_tier is
  'Palier d''amitié, DÉRIVÉ des jours de croisement — jamais choisi à la main. '
  'Ordonné : friend < close < inner.';

-- ---------------------------------------------------------------------------
-- 2. L'ACQUISITION : un jour où deux amis se sont croisés
-- ---------------------------------------------------------------------------
create table public.meeting_days (
  user_low  uuid not null references public.profiles(id) on delete cascade,
  user_high uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  primary key (user_low, user_high, day),
  constraint meeting_days_ordre check (user_low < user_high)
);

comment on table public.meeting_days is
  'UNE ligne par paire et par jour où un croisement mutuel a été constaté. '
  'La table de faits dont dérivent le palier ET la série. Elle n''accorde '
  'aucun droit : voir l''en-tête de la migration du 2026-08-30.';

comment on column public.meeting_days.day is
  '⚠️ Date UTC, pas locale. Effet de bord VOULU : la journée bascule vers 2 h '
  'du matin en France, donc un croisement à 1 h compte encore pour la soirée '
  'de la veille — ce qui est le bon comportement pour une app de sorties.';

alter table public.meeting_days enable row level security;

-- On lit ses propres jours (la série les affiche). Personne n'écrit : seules
-- les fonctions `security definer` alimentent cette table.
create policy "meeting_days_select_own" on public.meeting_days for select
  using ((select auth.uid()) in (user_low, user_high));

-- ---------------------------------------------------------------------------
-- 3. LES SEUILS — écrits une fois, et une seule
-- ---------------------------------------------------------------------------
--
-- ⚠️ **Ces trois valeurs sont RAISONNÉES, PAS MESURÉES** (2026-08-30). Elles
-- n'ont été confrontées à aucun usage réel : NeoVibe n'a jamais eu deux
-- utilisateurs qui se croisent au quotidien pendant un mois. À reprendre dès
-- qu'on aura des chiffres — et à ne pas citer comme une constante du produit.
create or replace function private.meeting_window_days() returns int
  language sql immutable as $$ select 30 $$;

create or replace function private.tier_close_days() returns int
  language sql immutable as $$ select 5 $$;

create or replace function private.tier_inner_days() returns int
  language sql immutable as $$ select 15 $$;

-- La tolérance de la SÉRIE : combien de jours d'affilée on peut manquer sans
-- que la série casse. 2 = un week-end ne tue pas la série d'un camarade de
-- classe. Raisonné, pas mesuré, lui aussi.
create or replace function private.streak_tolerance_days() returns int
  language sql immutable as $$ select 2 $$;

-- ---------------------------------------------------------------------------
-- 4. LA DÉRIVATION
-- ---------------------------------------------------------------------------

-- Combien de jours ces deux-là se sont-ils croisés dans la fenêtre ?
--
-- ⚠️ C'est ce nombre qui fait REDESCENDRE le palier tout seul, sans aucun
-- mécanisme dédié : la fenêtre glisse, les vieux jours en sortent, le compte
-- baisse. Une décroissance qu'il aurait fallu programmer serait une seconde
-- règle à tenir d'accord avec la première.
create or replace function private.days_met(a uuid, b uuid) returns int
  language sql stable security definer set search_path to public, private as $$
  select count(*)::int from public.meeting_days m
  where m.user_low = least(a, b)
    and m.user_high = greatest(a, b)
    and m.day > current_date - private.meeting_window_days();
$$;

create or replace function private.tier_for_days(d int)
  returns public.friendship_tier
  language sql immutable set search_path to public, private as $$
  select case
    when d >= private.tier_inner_days() then 'inner'
    when d >= private.tier_close_days() then 'close'
    else 'friend'
  end::public.friendship_tier;
$$;

-- Le nombre de jours qu'il reste à faire pour le palier suivant.
-- `null` = il n'y a plus de palier au-dessus.
--
-- ⚠️ **Il est calculé ICI et pas dans l'app.** Un écran qui afficherait
-- « encore 3 jours » en soustrayant lui-même devrait connaître les seuils —
-- donc la règle vivrait à deux endroits, et le jour où l'un bougerait l'autre
-- mentirait sans lever d'erreur.
create or replace function private.days_to_next_tier(d int) returns int
  language sql immutable set search_path to public, private as $$
  select case
    when d >= private.tier_inner_days() then null
    when d >= private.tier_close_days() then private.tier_inner_days() - d
    else private.tier_close_days() - d
  end;
$$;

-- ---------------------------------------------------------------------------
-- 5. LE RANGEMENT du résultat, sur la connexion elle-même
-- ---------------------------------------------------------------------------
alter table public.connections
  add column tier public.friendship_tier not null default 'friend',
  add column tier_days int not null default 0,
  add column tier_refreshed_at timestamptz;

comment on column public.connections.tier is
  'DÉRIVÉ de meeting_days, jamais écrit à la main. Voir la migration du '
  '2026-08-30 pour la raison d''être d''une colonne distincte de `status`.';

comment on column public.connections.tier_refreshed_at is
  '⚠️ Sert à répondre à « la tâche quotidienne tourne-t-elle ? ». Une tâche '
  'planifiée qui échoue ne dit rien à personne (RAPPELS.md #57) : cette '
  'colonne est la seule trace qu''elle est passée.';

create or replace function private.refresh_tier(a uuid, b uuid) returns void
  language plpgsql security definer set search_path to public, private as $$
declare
  d int;
begin
  d := private.days_met(a, b);
  update public.connections
     set tier = private.tier_for_days(d),
         tier_days = d,
         tier_refreshed_at = now()
   where user_low = least(a, b)
     and user_high = greatest(a, b);
end;
$$;

-- Le passage quotidien : la fenêtre a glissé d'un jour, donc des paliers ont
-- pu redescendre sans qu'aucune rencontre n'ait eu lieu.
--
-- ⚠️ **Il réécrit TOUTES les lignes, même celles qui ne changent pas**, et
-- c'est délibéré : `tier_refreshed_at` est ce qui permet de constater que la
-- tâche tourne. Une mise à jour conditionnelle rendrait un job mort
-- indiscernable d'un job qui n'avait rien à faire.
create or replace function private.refresh_all_tiers() returns int
  language plpgsql security definer set search_path to public, private as $$
declare
  n int;
begin
  with calc as (
    select c.user_low,
           c.user_high,
           private.days_met(c.user_low, c.user_high) as d
      from public.connections c
  )
  update public.connections c
     set tier = private.tier_for_days(calc.d),
         tier_days = calc.d,
         tier_refreshed_at = now()
    from calc
   where c.user_low = calc.user_low
     and c.user_high = calc.user_high;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ⚠️ **Son PROPRE job.** On ne greffe pas une nouveauté sur `neovibe_purge` :
-- un job est une transaction, et une erreur ici emporterait la purge entière.
select cron.schedule(
  'neovibe_tiers',
  '11 3 * * *',
  $job$ select private.refresh_all_tiers(); $job$
);

-- ---------------------------------------------------------------------------
-- 6. LA SÉRIE — le second usage de la MÊME acquisition
-- ---------------------------------------------------------------------------
--
-- ⚠️ **Deux nombres, deux questions.** `tier_days` compte les jours dans une
-- fenêtre de 30 jours : borné, réversible, c'est ce que Jay a demandé pour le
-- palier. La série, elle, doit pouvoir atteindre 100 : c'est la longueur de la
-- suite en cours. Les confondre aurait plafonné la série à 30.
--
-- La règle : on remonte les jours de croisement du plus récent au plus ancien,
-- et la suite s'arrête au premier trou de plus de `streak_tolerance_days`
-- jours. Entièrement recalculable depuis les faits — donc **elle ne peut pas
-- dériver** si une tâche planifiée saute un tour, contrairement à un compteur
-- qu'on incrémenterait.
create or replace function private.friendship_streak(a uuid, b uuid) returns int
  language sql stable security definer set search_path to public, private as $$
  with jours as (
    select m.day,
           -- Le jour de croisement suivant (plus récent). Pour le tout
           -- premier, c'est aujourd'hui : une série qui s'est éteinte il y a
           -- une semaine doit valoir 0, pas sa longueur d'alors.
           coalesce(
             lag(m.day) over (order by m.day desc),
             current_date
           ) as plus_recent
      from public.meeting_days m
     where m.user_low = least(a, b)
       and m.user_high = greatest(a, b)
       and m.day <= current_date
  ),
  ecarts as (
    select (plus_recent - day) as ecart,
           row_number() over (order by day desc) as rang
      from jours
  ),
  coupure as (
    select min(rang) as rang from ecarts
     where ecart > private.streak_tolerance_days() + 1
  )
  select coalesce(
    (select rang - 1 from coupure),
    (select count(*)::int from ecarts),
    0
  );
$$;

-- ---------------------------------------------------------------------------
-- 7. CE QUE L'APP LIT — un seul aller-retour
-- ---------------------------------------------------------------------------
--
-- ⚠️ **Une RPC plutôt qu'une lecture de table.** La série se calcule par paire :
-- la laisser au client voudrait dire un appel par ami, et surtout la règle des
-- seuils recopiée côté Dart. Ici l'app reçoit des NOMBRES et n'a aucune règle à
-- connaître — c'est la dissociation acquisition / usage appliquée au réseau.
create or replace function public.my_friendships()
returns table (
  peer_id uuid,
  tier public.friendship_tier,
  tier_days int,
  days_to_next int,
  streak int
)
language sql stable security definer set search_path to public, private as $$
  select
    case when c.user_low = auth.uid() then c.user_high else c.user_low end,
    c.tier,
    c.tier_days,
    private.days_to_next_tier(c.tier_days),
    private.friendship_streak(c.user_low, c.user_high)
  from public.connections c
  where auth.uid() in (c.user_low, c.user_high)
    and c.status = 'full';
$$;

revoke all on function public.my_friendships() from public;
grant execute on function public.my_friendships() to authenticated;

-- Le palier d'une paire, tel que rangé. `null` si les deux ne sont pas amis —
-- **et surtout pas `'friend'`**, qui ferait passer un inconnu pour un ami dans
-- toute comparaison écrite naïvement.
create or replace function private.friendship_tier(a uuid, b uuid)
  returns public.friendship_tier
  language sql stable security definer set search_path to public, private as $$
  select c.tier from public.connections c
   where c.user_low = least(a, b)
     and c.user_high = greatest(a, b)
     and c.status = 'full';
$$;

-- ---------------------------------------------------------------------------
-- 8. PREMIER DÉBLOCAGE : les stories réservées à un palier
-- ---------------------------------------------------------------------------
alter table public.stories
  add column min_tier public.friendship_tier not null default 'friend';

comment on column public.stories.min_tier is
  'Palier minimum pour voir cette story. « friend » = tous mes amis, le '
  'comportement d''avant le 2026-08-30.';

-- ⚠️ **Réécrite EN ENTIER, et le palier s''applique à TOUS les chemins.**
-- L''ancienne version offrait trois portes : le propriétaire, l''audience
-- ordinaire, et un relais (`content_grants`). Poser le palier sur la seule
-- deuxième aurait laissé la troisième ouverte — c''est la règle 3 de
-- `CLAUDE.md` : compter les chemins qui mènent à un contenu.
create or replace function private.story_audience(p_story_id uuid, p_uid uuid)
  returns boolean
  language sql stable security definer set search_path to public, private as $$
  select exists (
    select 1 from stories s
    where s.id = p_story_id
      and s.expires_at > now()
      and not private.is_revoked(s.id)
      and (
        s.owner_id = p_uid
        or (
          -- Le palier, en amont de toutes les portes.
          (s.min_tier = 'friend'
            or private.friendship_tier(s.owner_id, p_uid) >= s.min_tier)
          and (
            can_view_stories(s.owner_id, p_uid)
            or exists (
              select 1 from content_grants g
              where g.content_id = s.id
                and g.grantee_id = p_uid
                -- Un relais reçu de quelqu'un que j'ai bloqué depuis ne vaut plus.
                and not private.is_blocked(g.granted_by, p_uid)
            )
          )
        )
      )
  );
$$;

-- ---------------------------------------------------------------------------
-- 9. L'ACQUISITION SE BRANCHE — `report_sightings`, réécrite en entier
-- ---------------------------------------------------------------------------
--
-- ⚠️ **Réécrite, pas rapiécée.** Une fonction dont on ne remplace qu'un
-- morceau finit par exister en deux versions dans la tête de celui qui la
-- relit. Les deux seules lignes neuves sont signalées ci-dessous.
create or replace function public.report_sightings(items jsonb)
returns integer
language plpgsql security definer set search_path to public, private
as $function$
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

    retenus := retenus + 1;

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

      -- ⚠️ **LES DEUX SEULES LIGNES NEUVES DU 2026-08-30.**
      --
      -- Le fait durable, écrit ici parce que c'est le SEUL endroit où un
      -- croisement mutuel entre amis est constaté. Une seconde source
      -- d'écriture serait un second compte des jours, donc un désaccord.
      insert into public.meeting_days (user_low, user_high, day)
      values (lo, hi, (now() at time zone 'utc')::date)
      on conflict do nothing;

      -- ⚠️ `found` est faux quand le conflit a joué : le palier ne se recalcule
      -- donc qu'au PREMIER croisement de la journée, et pas quatre fois par
      -- heure. Sans ce garde, chaque paire réécrirait sa connexion tous les
      -- quarts d'heure pour un résultat identique.
      if found then
        perform private.refresh_tier(lo, hi);
      end if;
    end if;
  end loop;

  return retenus;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 10. REPRISE DE L'HISTORIQUE DISPONIBLE
-- ---------------------------------------------------------------------------
--
-- `sightings` est purgée à 48 h : c'est tout ce qu'on peut reconstituer. Sans
-- cette reprise, tout le monde repartirait de zéro jour — et Jay verrait un
-- écran vide en croyant à une panne.
--
-- ⚠️ On ne reconstitue QUE les jours où le croisement était **mutuel**, comme
-- le fait `report_sightings`. Reprendre les observations à sens unique
-- gonflerait les paliers avec des rencontres qui n'en étaient pas.
insert into public.meeting_days (user_low, user_high, day)
select distinct
       least(a.observer_id, a.seen_id),
       greatest(a.observer_id, a.seen_id),
       (a.created_at at time zone 'utc')::date
  from public.sightings a
  join public.sightings b
    on b.observer_id = a.seen_id
   and b.seen_id = a.observer_id
   and b.slot between a.slot - 1 and a.slot + 1
 where exists (
   select 1 from public.connections c
   where c.status = 'full'
     and c.user_low = least(a.observer_id, a.seen_id)
     and c.user_high = greatest(a.observer_id, a.seen_id)
 )
on conflict do nothing;

select private.refresh_all_tiers();
