-- ===========================================================================
-- LA MENTION SPÉCIALE — demandée par Jay le 2026-08-29
-- ===========================================================================
--
-- *« Une mention spéciale qui est comme une deuxième bio, c'est une option
-- qu'on rajoutera dans les paramètres profil, et l'affichage de la mention
-- spéciale dans le Ping pour les inconnus sera facultatif. »*
--
-- ---------------------------------------------------------------------------
-- ⚠️ POURQUOI CE N'EST PAS `bio`, ET POURQUOI ÇA NE DOIT JAMAIS LE DEVENIR
-- ---------------------------------------------------------------------------
--
-- Les deux se ressemblent — du texte libre qu'on écrit sur soi — et c'est
-- exactement le piège de la règle 2 de `CLAUDE.md` : deux objets qui n'obéissent
-- pas aux mêmes règles ne partagent pas le même rangement, sinon c'est la règle
-- la plus permissive qui gagne, en silence.
--
--   | | `bio` | `special_mention` |
--   |---|---|---|
--   | à qui elle s'adresse | à mes **amis**, sur mon profil | aux **inconnus croisés**, dans le Ping |
--   | quand on la lit | quand on vient me voir | quand on passe à côté de moi |
--   | qui décide de la montrer | personne, elle est là | **moi**, par un interrupteur |
--
-- Les fusionner reviendrait à afficher à des inconnus un texte écrit pour des
-- amis. Ce serait une fuite, et personne ne la verrait passer.
--
-- ---------------------------------------------------------------------------
-- 🔴 CE QUI REND L'INTERRUPTEUR RÉELLEMENT ÉTANCHE
-- ---------------------------------------------------------------------------
--
-- PostgreSQL ne sait pas cacher **une colonne** selon la ligne : la sécurité y
-- est par ligne. Poser la mention sur `profiles` et compter sur le client pour
-- ne pas l'afficher serait donc un vœu, pas une règle.
--
-- ✅ **Vérifié le 2026-08-30, et c'est ce qui rend le montage sûr : un inconnu
-- ne peut PAS lire une ligne de `profiles`.** `private.can_view_profile`
-- n'ouvre le profil qu'à cinq titres — être connectés, s'être croisés (et
-- `encounters` n'existe qu'entre AMIS), partager une conversation, avoir une
-- demande d'ami en cours, ou une recommandation. Un simple voisin de Ping
-- n'entre dans aucun.
--
-- Ce qu'un inconnu voit de moi passe donc **uniquement** par `ping_nearby`, qui
-- choisit ses colonnes une par une. C'est là, et nulle part ailleurs, que
-- l'interrupteur s'applique.
--
-- ⚠️ **Corollaire à ne pas perdre** : le jour où quelqu'un ouvrira `profiles`
-- aux gens croisés, la mention partira avec — sans qu'aucune erreur ne le dise.
-- ===========================================================================

alter table public.profiles
  add column special_mention text,
  add column special_mention_public boolean not null default false;

alter table public.profiles
  add constraint profiles_special_mention_check
  check (special_mention is null or char_length(special_mention) <= 90);

comment on column public.profiles.special_mention is
  'Deuxième bio, écrite pour les gens qu''on croise sans les connaître. '
  'Distincte de `bio`, qui s''adresse aux amis — voir la migration du '
  '2026-08-30. 90 caractères : c''est une accroche, pas une présentation.';

comment on column public.profiles.special_mention_public is
  'Faux par défaut. Décide si les INCONNUS croisés voient la mention dans le '
  'Ping. Appliqué dans `ping_nearby`, le seul chemin par lequel un inconnu '
  'apprend quoi que ce soit de moi.';

-- ---------------------------------------------------------------------------
-- `ping_nearby` — réécrite EN ENTIER
-- ---------------------------------------------------------------------------
--
-- ⚠️ **Réécrite, pas rapiécée.** Une fonction dont on ne remplace qu'un morceau
-- finit par exister en deux versions dans la tête de celui qui la relit. La
-- seule chose neuve est la dernière colonne.
-- ⚠️ **`create or replace` ne suffit PAS quand on ajoute une colonne au
-- résultat** : PostgreSQL refuse de changer le type de retour d'une fonction
-- existante. Il faut la supprimer d'abord.
--
-- ✅ **Inventaire fait avant de supprimer, dans les deux sens** (règle 8) :
--   * qui l'appelle ? — **aucune** autre fonction SQL, **aucune** politique
--     RLS ; un seul appelant côté app, `ping_repository.dart` ;
--   * qu'appelle-t-elle ? — `ping_beacon_ttl`, `fenetre_rencontre`,
--     `are_connected`, `is_blocked`, toutes utilisées ailleurs, donc rien ne
--     devient orphelin.
--
-- ⚠️ **Une suppression efface aussi les DROITS.** Ils sont donc reposés juste
-- après. Sans ça, l'app recevrait « permission denied » sur un écran qui
-- marchait la veille — et le diff, lui, n'aurait montré qu'un ajout de colonne.
drop function if exists public.ping_nearby();

create or replace function public.ping_nearby()
returns table (
  user_id uuid,
  display_name text,
  tag_name text,
  avatar_url text,
  last_seen_at timestamptz,
  token text,
  special_mention text
)
language plpgsql security definer set search_path to public, private
as $function$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifie';
  end if;

  return query
  select p.id,
         p.display_name,
         p.tag_name,
         p.avatar_url,
         pp.last_seen_at,
         b.token,
         -- ⚠️ **L'interrupteur s'applique ICI, à la source.** Rendre la mention
         -- puis laisser l'app décider de l'afficher serait la donner à qui sait
         -- lire une réponse réseau. Ce qui n'est pas autorisé n'est pas envoyé.
         case when p.special_mention_public then p.special_mention end
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
$function$;

-- Les droits, reposés à l'identique — à une exception près, assumée.
--
-- ⚠️ `anon` avait `execute` (droit par défaut de Supabase). Il n'est pas
-- reconduit : la fonction lève immédiatement quand `auth.uid()` est nul, donc
-- personne ne perd rien. C'est la même règle énoncée positivement — au lieu de
-- « anon peut appeler mais n'obtient rien », on écrit « anon ne peut pas
-- appeler ».
revoke all on function public.ping_nearby() from public;
grant execute on function public.ping_nearby() to authenticated;
grant execute on function public.ping_nearby() to service_role;
