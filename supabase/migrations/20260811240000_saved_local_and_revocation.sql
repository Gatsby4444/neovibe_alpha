-- Étape 5 — la sauvegarde devient une COPIE LOCALE (volet 3 de Jay).
--
-- « Les contenus sauvegardés par l'utilisateur (s'ils sont sauvegardables)
-- sont téléchargés sur l'appareil et il les conserve en local. Plus besoin
-- d'appeler le serveur pour les afficher. Pas d'espace serveur dédié. »
--
-- **Ce que ça corrige** : `saved_cards` était en `ON DELETE CASCADE`. Si
-- l'auteur supprimait sa Vibe, TOUS ceux qui l'avaient enregistrée la
-- perdaient, sans avertissement — alors qu'« Enregistrer » promet de garder
-- (`RAPPELS.md` #18).
--
-- **Ce que ça supprime en prime** : `saved_cards` était la DERNIÈRE branche
-- « accès illimité » de `can_view_card_file`. Elle passe de TROIS chemins à
-- **DEUX** — propriétaire et livraison. C'était l'objectif annoncé le
-- 2026-08-10, et il est atteint.

-- 1. La sauvegardabilité appartient au CONTENU, comme la partageabilité.
--    Elle vaut donc pour les stories et les publications, là où elle
--    n'existait que pour les Vibes envoyées (`cards.saveable`).
alter table public.contents
  add column saveable boolean not null default false;

-- 2. `saved_cards` disparaît : une sauvegarde ne vit plus sur le serveur.
drop table if exists public.saved_cards cascade;
drop function if exists private.can_save_card(uuid, uuid);

-- 3. Plus aucun accès illimité à une Vibe envoyée : le seul régime restant est
--    la livraison nominative, avec ses limites.
drop function if exists private.has_unlimited_card_access(uuid, uuid);

create or replace function private.can_view_card_file(file_path text, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select exists (
    select 1 from cards c
    where (c.front_path = file_path or c.back_path = file_path)
      and (
        c.owner_id = uid
        or exists (
          select 1 from card_deliveries d
          where d.card_id = c.id and d.recipient_id = uid and d.destroyed_at is null
        )
      )
  );
$$;

create or replace function public.open_card_media(p_card_id uuid)
returns text
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_card cards%rowtype;
  v_delivery card_deliveries%rowtype;
  v_effective_max integer;
begin
  select * into v_card from cards where id = p_card_id;
  if not found then
    raise exception 'Vibe introuvable';
  end if;

  -- Le propriétaire : toujours, sans décompte. C'est son contenu.
  if v_card.owner_id = v_me then
    return (select media_key from card_media_keys where card_id = p_card_id);
  end if;

  -- Destinataire en conversation : la limite s'applique, et le décompte est
  -- INDISSOCIABLE de la remise de la clé. Il n'y a plus d'autre chemin.
  select * into v_delivery from card_deliveries
  where card_id = p_card_id and recipient_id = v_me
  for update;

  if not found then
    raise exception 'Vibe introuvable';
  end if;

  if v_delivery.destroyed_at is not null then
    raise exception 'Vibe detruite';
  end if;

  v_effective_max := coalesce(v_card.max_views, 2147483647)
    + case when v_delivery.replay_granted_at is not null then 1 else 0 end;

  if v_delivery.view_count >= v_effective_max then
    raise exception 'Plus de visionnages disponibles';
  end if;

  update card_deliveries
  set view_count = view_count + 1,
      first_viewed_at = coalesce(first_viewed_at, now())
  where id = v_delivery.id;

  return (select media_key from card_media_keys where card_id = p_card_id);
end;
$$;

-- 4. La révocation des copies locales.
--
--    C'est le SEUL point de contact entre une sauvegarde locale et le serveur.
--    L'app envoie les identifiants qu'elle détient, le serveur répond lesquels
--    sont révoqués, l'app les supprime.
--
--    ⚠️ Elle ne renvoie QUE les contenus révoqués — **jamais** ceux qui ont
--    simplement disparu. C'est toute la différence avec l'ancien
--    `ON DELETE CASCADE` : l'auteur qui supprime son contenu ne reprend pas ce
--    que d'autres ont gardé. Seule la modération le peut.
--
--    Révocation **coopérative**, faille connue et acceptée par Jay le
--    2026-08-11 : le fichier local est en clair, un client modifié peut
--    l'ignorer. On ne promet donc jamais « révocation garantie » sur une
--    sauvegarde — seulement sur un contenu que le serveur sert encore.
create or replace function public.revoked_contents(p_ids uuid[])
returns setof uuid
language sql
stable
security definer
set search_path = 'public'
as $$
  select id from contents
  where id = any(p_ids) and revoked_at is not null;
$$;

revoke all on function public.revoked_contents(uuid[]) from public, anon;
grant execute on function public.revoked_contents(uuid[]) to authenticated;
