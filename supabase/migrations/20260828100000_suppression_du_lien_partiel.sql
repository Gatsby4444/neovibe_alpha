-- Le LIEN PARTIEL est supprimé : il n'y a plus qu'une porte pour devenir amis.
--
-- ## Ce qui existait, et que personne n'avait demandé
--
-- Un déclencheur sur `messages` créait tout seul une ligne `connections` au
-- statut `partial` dès que **les deux** avaient écrit un message dans un canal
-- de proximité. Chacun devait ensuite appuyer sur « Confirmer la connexion ».
-- Deux confirmations, 3 jours de validité, et on devenait amis.
--
-- ## Pourquoi il part — décision de Jay, 2026-08-28
--
-- Il y avait **deux chemins vers `status = 'full'`**, avec deux horloges et
-- deux vocabulaires :
--
-- | | la demande d'ami | le lien partiel |
-- |---|---|---|
-- | déclenchement | un geste explicite | **automatique** |
-- | délai | 7 jours | 3 jours |
-- | forme | un émetteur, un destinataire | deux confirmations symétriques |
--
-- C'est « un chemin, une donnée » pris à l'envers. Et le lien partiel avait un
-- **prix caché** que personne n'avait choisi de payer : `has_any_connection`
-- ne teste que l'EXISTENCE de la ligne, pas son statut — donc **écrire deux
-- messages à un inconnu lui ouvrait le profil**, sans qu'aucune des deux
-- personnes n'ait rien confirmé.
--
-- ⚠️ **Ce n'est PAS un renoncement aux niveaux de relation.** Jay les a au
-- contraire posés comme une mécanique essentielle à venir : des cercles à
-- plusieurs paliers, donnant accès à plus ou moins de fonctionnalités. Le lien
-- partiel n'en était pas un palier — c'était un **sas d'entrée**, une deuxième
-- porte vers le même et unique statut. Les paliers viendront comme des
-- **valeurs de `status`**, sur un chemin d'entrée unique.
--
-- ## Sens entrant / sens sortant, relevés avant de couper
--
-- Interrogé en base, pas déduit :
--
-- - **qui appelle** : le déclencheur `messages_partial_connection`, la fonction
--   `confirm_partial_connection` (RPC appelée par le client), et **une ligne du
--   job `neovibe_purge`** ;
-- - **aucune politique RLS, aucune vue, aucune clé étrangère** ne cite
--   `partial`, `confirmed_low`, `confirmed_high` ni `partial_expires_at` ;
-- - **ce qu'il appelait** : la table `connections` (qui survit) et le type
--   `connection_status` (nettoyé ci-dessous).

-- ---------------------------------------------------------------------------
-- 1. Les deux fonctions et le déclencheur
-- ---------------------------------------------------------------------------

drop trigger if exists messages_partial_connection on public.messages;
drop function if exists public.maybe_create_partial_connection();
drop function if exists public.confirm_partial_connection(uuid);

-- ---------------------------------------------------------------------------
-- 2. Les lignes restantes
-- ---------------------------------------------------------------------------
--
-- ⚠️ **Supprimées, pas promues.** Une ligne partielle est un lien que personne
-- n'a fini de confirmer : la promouvoir en amitié donnerait à des gens une
-- connexion qu'ils n'ont jamais acceptée. Le déclencheur
-- `connections_delete_oublie` emporte au passage les croisements et constats de
-- la paire, ce qui est correct — ils n'étaient jamais devenus amis.
--
-- (0 ligne concernée en base de dev au moment d'écrire ceci — relevé, pas
-- supposé.)

delete from public.connections where status = 'partial';

-- ---------------------------------------------------------------------------
-- 3. Les colonnes qui n'existaient que pour lui
-- ---------------------------------------------------------------------------

alter table public.connections
  drop column if exists partial_expires_at,
  drop column if exists confirmed_low,
  drop column if exists confirmed_high;

-- ---------------------------------------------------------------------------
-- 4. Le type : « partial » ne doit plus pouvoir s'écrire
-- ---------------------------------------------------------------------------
--
-- ⚠️ **Règle 4 de `CLAUDE.md` : une règle s'énonce positivement.** Laisser la
-- valeur `partial` dans le type en se disant que « plus rien ne l'écrit », c'est
-- une sécurité par la négation — vraie aujourd'hui, muette le jour où quelqu'un
-- l'écrira. On la retire du type : elle devient **impossible**, pas seulement
-- inutilisée.
--
-- PostgreSQL ne sait pas retirer une étiquette d'un enum ; on recrée le type. Il
-- n'a qu'un seul porteur (`connections.status`), vérifié en base.
--
-- ⚠️ **Le type reste, avec une seule valeur, et c'est délibéré** : c'est ici que
-- viendront les **paliers de relation** annoncés par Jay le 2026-08-28.
-- `alter type ... add value` suffira alors.

-- ⚠️ **Une politique RLS empêche de changer le type d'une colonne qu'elle
-- cite**, et PostgreSQL le dit clairement :
--
--     cannot alter type of a column used in a policy definition
--     DETAIL: policy device_keys_friends on table device_keys depends on
--             column "status"
--
-- 🔎 **Relevé en interrogeant `pg_policies`, pas deviné** — et c'est une
-- politique d'une AUTRE table que celle qu'on modifie. Un inventaire limité à
-- `connections` ne l'aurait pas vue. Elle est reposée à l'identique juste
-- après, dans la même transaction : aucune fenêtre où `device_keys` serait
-- sans politique.

drop policy device_keys_friends on public.device_keys;

alter type public.connection_status rename to connection_status_ancien;
create type public.connection_status as enum ('full');

alter table public.connections
  alter column status type public.connection_status
  using status::text::public.connection_status;

drop type public.connection_status_ancien;

-- Reposée mot pour mot depuis `20260827210000`.
create policy device_keys_friends on public.device_keys
  for select to authenticated
  using (
    exists (
      select 1 from public.connections c
      where c.status = 'full'
        and ((c.user_low = (select auth.uid()) and c.user_high = device_keys.user_id)
          or (c.user_high = (select auth.uid()) and c.user_low = device_keys.user_id))
    )
    and not private.a_bloque(device_keys.user_id, (select auth.uid()))
  );

comment on policy device_keys_friends on public.device_keys is
  'La clé publique de mes amis — sauf ceux qui m''ont bloqué. ⚠️ Cette '
  'politique décide À ELLE SEULE qui je peux reconnaître par la radio : le '
  'client ne doit jamais retirer un ami de son carnet parce qu''un PROFIL est '
  'invisible (défaut du 2026-08-27, qui vidait le carnet des deux côtés au '
  'premier blocage).';

comment on column public.connections.status is
  'Le palier de la relation. ⚠️ Une seule valeur aujourd''hui : « partial » a '
  'été retirée le 2026-08-28 avec le lien partiel. C''est ce type qui portera '
  'les paliers de relation à venir — un chemin d''entrée unique, plusieurs '
  'niveaux ensuite.';

-- ---------------------------------------------------------------------------
-- 5. `origin = 'ble'` était devenu faux
-- ---------------------------------------------------------------------------
--
-- Cette colonne dit **comment** la connexion s'est formée. Elle valait `ble` du
-- temps où une connexion naissait d'un échange BLE pair-à-pair. Depuis le
-- 2026-08-27, **le BLE ne transporte plus rien** : il ne fait que prouver la
-- proximité, et la connexion se forme par une demande passée au serveur.
--
-- L'étiquette est renommée pour dire ce qui est vrai. ⚠️ **Le renommage casse
-- toute fonction qui écrivait le littéral `'ble'`** : `accept_connection_request`
-- est réécrite juste en dessous, dans la même migration. C'était la seule qui
-- restait, `maybe_create_partial_connection` ayant été supprimée à l'étape 1.

alter type public.connection_origin rename value 'ble' to 'proximity';

comment on type public.connection_origin is
  'Comment la connexion s''est formée : « proximity » (rencontre physique, '
  'prouvée par le ping) ou « recommendation » (chaîne A→B→C). ⚠️ « ble » a été '
  'renommée en « proximity » le 2026-08-28 : le BLE ne transporte plus rien '
  'depuis le 2026-08-27, il ne fait que prouver la présence.';

create or replace function public.accept_connection_request(req_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
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
    raise exception 'Demande expirée';
  end if;

  update connection_requests set status = 'accepted' where id = req_id;

  insert into connections (user_low, user_high, status, origin, established_at)
  values (least(r.sender_id, r.receiver_id), greatest(r.sender_id, r.receiver_id),
          'full', 'proximity', now())
  on conflict (user_low, user_high) do update
    set status = 'full', established_at = coalesce(connections.established_at, now())
  returning id into conn_id;

  return conn_id;
end;
$$;

revoke all on function public.accept_connection_request(uuid) from public;
grant execute on function public.accept_connection_request(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Le job de purge
-- ---------------------------------------------------------------------------
--
-- ⚠️ **Réécrit EN ENTIER, pas amputé d'une ligne.** Un job cron est une
-- transaction : on ne greffe pas, on repose le tout. La ligne retirée était
-- `delete from public.connections where status = 'partial' and
-- partial_expires_at < now()` — elle cite une colonne qui n'existe plus, donc le
-- job **entier** échouerait à partir du prochain tour si on l'oubliait, et une
-- tâche planifiée qui échoue ne dit rien à personne (`RAPPELS.md` #57).

select cron.schedule('neovibe_purge', '*/5 * * * *', $job$
  delete from public.messages where expires_at < now();
  update public.connection_requests set status = 'expired'
    where status = 'pending' and expires_at < now();
  update public.recommendations set status = 'expired'
    where status in ('requested', 'forwarded') and expires_at < now();
  delete from public.encounters where last_seen_at < now() - interval '24 hours';
  delete from public.contents c
    where c.context = 'story'
      and exists (select 1 from public.stories s
                  where s.id = c.id and s.expires_at < now());
$job$);
