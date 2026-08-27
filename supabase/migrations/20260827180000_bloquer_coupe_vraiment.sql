-- Bloquer coupe l'accès. Retirer un ami emporte ce qu'il avait ouvert.
--
-- Décision de Jay du 2026-08-27 : *« je veux que bloquer un ami lui coupe
-- immédiatement ses accès profil et stories. »*
--
-- ## 🔴 Ce qui était vrai avant, et qui ne se voyait nulle part
--
-- **① Bloquer quelqu'un ne lui coupait presque rien.** `private.is_blocked`
-- existait, la table `blocks` existait, le menu « Bloquer » existait — mais
-- cette fonction n'était consultée **qu'à un seul endroit** : `ping_shortlist`.
-- Autrement dit, bloquer quelqu'un l'empêchait de vous **découvrir par le
-- ping**, et rien d'autre. Il continuait de voir votre profil, votre avatar,
-- vos stories, et de vous écrire.
--
-- ⚠️ **Un bouton « Bloquer » qui ne bloque presque rien est pire que pas de
-- bouton** : la personne qui l'utilise croit s'être protégée.
--
-- **② Retirer un ami ne coupait pas son accès non plus.** Reproduit en base le
-- 2026-08-27 en **exécutant** les fonctions : treize heures après que Jay ait
-- retiré une amitié, l'ex-ami voyait encore le profil et les stories publiques.
-- La ligne `connections` était bien partie ; la ligne `encounters`, elle, lui
-- survivait jusqu'à sa purge (24 h). Or `can_view_profile` teste l'existence
-- d'un croisement **sans aucune limite de temps**.
--
-- C'est la règle 8 de `CLAUDE.md` — *une suppression est une opération sur un
-- réseau* — appliquée au bouton « Retirer de mes amis » : on avait coupé le
-- nœud sans relever ce qui dépendait de lui.
--
-- ## Deux corrections de nature différente, et c'est voulu
--
-- | | Mécanisme | Pourquoi celui-là |
-- |---|---|---|
-- | **Bloquer** | un **garde** dans `can_view_*` | le croisement a bien eu lieu ; le blocage est une règle qui le **surpasse**. Une règle négative se garde, elle ne s'efface pas. |
-- | **Retirer un ami** | une **suppression** de la ligne `encounters` | le croisement n'était qu'un dérivé du lien. Le lien coupé, le dérivé n'a plus de raison d'être : on supprime la cause au lieu de la surveiller. |

-- ---------------------------------------------------------------------------
-- Bloquer : le garde, en tête de chaque question d'accès
-- ---------------------------------------------------------------------------

/*
 * ⚠️ **En PREMIER, et pas en dernier.** Placé après les autres conditions, il
 * serait juste mais illisible : un lecteur pressé conclurait « ils sont amis,
 * donc il voit ». Placé devant, la règle se lit dans l'ordre où elle s'applique
 * — le blocage passe avant tout le reste, y compris l'amitié.
 *
 * ⚠️ `is_blocked` est **symétrique** : peu importe qui a bloqué l'autre.
 */
create or replace function private.can_view_profile(viewer uuid, target uuid)
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select viewer = target
    or (
      not private.is_blocked(viewer, target)
      and (
        has_any_connection(viewer, target)
        or exists (
          select 1 from encounters e
          where e.user_low = least(viewer, target)
            and e.user_high = greatest(viewer, target)
        )
        or exists (
          select 1 from conversation_members m1
          join conversation_members m2 using (conversation_id)
          where m1.user_id = viewer and m2.user_id = target
        )
        or exists (
          select 1 from connection_requests
          where (sender_id = viewer and receiver_id = target)
             or (sender_id = target and receiver_id = viewer)
        )
        or exists (
          select 1 from recommendations
          where (intermediary_id = viewer and (requester_id = target or target_id = target))
             or (requester_id = viewer and intermediary_id = target)
             or (target_id = viewer and intermediary_id = target)
             or (requester_id = viewer and target_id = target and status = 'accepted')
             or (target_id = viewer and requester_id = target and status in ('forwarded', 'accepted'))
        )
      )
    );
$$;

grant execute on function private.can_view_profile(uuid, uuid) to authenticated;

create or replace function private.can_view_stories(owner uuid, viewer uuid)
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select owner = viewer
    or (
      not private.is_blocked(owner, viewer)
      and (
        are_connected(owner, viewer)
        or exists (
          select 1 from profiles p
          where p.id = owner
            and p.stories_public
            and exists (
              select 1 from encounters e
              where ((e.user_low = owner and e.user_high = viewer)
                  or (e.user_low = viewer and e.user_high = owner))
                and e.last_seen_at > now() - interval '24 hours'
            )
        )
      )
    );
$$;

grant execute on function private.can_view_stories(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Bloquer coupe aussi la PAROLE
-- ---------------------------------------------------------------------------

/*
 * ⚠️ **Un blocage qui laisse écrire n'est pas un blocage.** Jay a demandé le
 * profil et les stories ; laisser la messagerie ouverte aurait rendu le bouton
 * à moitié vrai — et c'est exactement le défaut qu'on vient de corriger.
 *
 * ⚠️ **Seulement pour les conversations à DEUX.** Bloquer une personne ne doit
 * pas fermer un groupe de dix : dans un groupe, chacun reste responsable de ce
 * qu'il lit. La règle ne s'applique donc qu'à `direct` et `proximity`, où « le
 * groupe » et « la personne bloquée » sont la même chose.
 */
create or replace function private.can_write_in_conversation(
  conv_id uuid,
  uid uuid
) returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select case
    when c.conversation_type = 'group' then true
    when exists (
      select 1 from public.conversation_members autre
      where autre.conversation_id = c.id
        and autre.user_id <> uid
        and private.is_blocked(uid, autre.user_id)
    ) then false
    when c.conversation_type <> 'proximity' then true
    else exists (
      select 1
      from public.conversation_members autre
      join public.ping_pairs pp
        on (pp.user_low = least(uid, autre.user_id)
            and pp.user_high = greatest(uid, autre.user_id))
      where autre.conversation_id = c.id
        and autre.user_id <> uid
        and pp.last_seen_at > now() - private.fenetre_canal()
    )
  end
  from public.conversations c
  where c.id = conv_id;
$$;

grant execute on function private.can_write_in_conversation(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Bloquer coupe aussi la découverte déjà acquise
-- ---------------------------------------------------------------------------

/*
 * ⚠️ `ping_shortlist` excluait déjà les bloqués, donc **aucune paire nouvelle**
 * ne peut naître. Mais une paire **déjà formée** vit dix minutes : sans ce
 * filtre, la personne bloquée resterait dans « Autour de toi » ce temps-là.
 * Bloquer doit se voir tout de suite.
 */
create or replace function public.ping_nearby()
returns table (
  user_id uuid,
  display_name text,
  tag_name text,
  avatar_url text,
  last_seen_at timestamptz,
  token text
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
  select p.id, p.display_name, p.tag_name, p.avatar_url, pp.last_seen_at, b.token
  from public.ping_pairs pp
  join public.profiles p
    on p.id = case when pp.user_low = me then pp.user_high else pp.user_low end
  left join public.ping_beacons b
    on b.user_id = p.id
   and b.updated_at > now() - private.ping_beacon_ttl()
  where (pp.user_low = me or pp.user_high = me)
    -- Borne de LISTE, pas règle : la vue affine (voir 20260827170000).
    and pp.last_seen_at > now() - private.fenetre_rencontre()
    and not are_connected(me, p.id)
    and not private.is_blocked(me, p.id)
  order by pp.last_seen_at desc;
end;
$$;

revoke all on function public.ping_nearby() from public;
grant execute on function public.ping_nearby() to authenticated;

-- ---------------------------------------------------------------------------
-- Retirer un ami : la suppression emporte ce qu'elle a ouvert
-- ---------------------------------------------------------------------------

/*
 * ⚠️ **Un TRIGGER, pas un appel côté client.** Retirer un ami est aujourd'hui un
 * `delete` direct sur `connections`, écrit dans trois écrans. Poser la règle
 * dans le dépôt Dart obligerait à la répéter à chaque nouvel appelant, et le
 * jour où l'un l'oublierait, personne ne le verrait. Ici, **il n'existe aucun
 * chemin qui supprime une connexion sans emporter ce qui en dérive.**
 *
 * ⚠️ **Sens sortant relevé avant d'écrire** (règle 8). Ce qui dérive d'une
 * amitié et lui survivait :
 *
 *   - `encounters` — le croisement, qui ouvre le profil (sans limite de temps)
 *     et les stories publiques (24 h). **C'est la fuite.**
 *   - `sightings` — les observations brutes qui le produisent. Elles ne peuvent
 *     plus rien recréer (`report_sightings` exige `status = 'full'`), mais ce
 *     sont des données de déplacement : les garder après une rupture de lien
 *     n'a aucune justification.
 *
 * ⚠️ **`ping_pairs` n'est PAS touchée, et c'est délibéré.** Une paire de ping
 * est une proximité **physique constatée**, pas un dérivé de l'amitié — deux
 * inconnus en ont une. La supprimer ici confondrait « nous ne sommes plus amis »
 * avec « nous ne sommes pas à côté ». Elle expire seule en 10 min pour l'usage,
 * 24 h pour la ligne.
 */
create or replace function private.oublie_ce_qui_derivait_du_lien()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  delete from public.encounters e
  where e.user_low = least(old.user_low, old.user_high)
    and e.user_high = greatest(old.user_low, old.user_high);

  delete from public.sightings s
  where (s.observer_id = old.user_low and s.seen_id = old.user_high)
     or (s.observer_id = old.user_high and s.seen_id = old.user_low);

  return old;
end;
$$;

drop trigger if exists connections_delete_oublie on public.connections;

create trigger connections_delete_oublie
  after delete on public.connections
  for each row
  execute function private.oublie_ce_qui_derivait_du_lien();

comment on trigger connections_delete_oublie on public.connections is
  'Retirer un lien emporte ce qui en dérivait : le croisement (qui ouvrait le '
  'profil sans limite de temps et les stories publiques 24 h) et les '
  'observations qui le produisent. Sans lui, un ex-ami gardait ses accès '
  'jusqu''à 24 h — reproduit en base le 2026-08-27.';
