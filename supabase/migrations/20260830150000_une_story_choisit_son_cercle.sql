-- ===========================================================================
-- UNE STORY CHOISIT SON CERCLE — `publish_story` accepte enfin `min_tier`
-- ===========================================================================
--
-- ## 🔴 Le défaut : une colonne livrée sans personne pour l'écrire
--
-- `stories.min_tier` existe depuis les paliers d'amitié (2026-08-30) et
-- `private.story_audience` la lit à chaque lecture — *« le palier, en amont de
-- toutes les portes »*. Mais **aucun appel Dart ne la renseigne** : relevé par
-- inventaire, zéro occurrence de `min_tier` dans `lib/` avant ce jour.
--
-- Toutes les stories partaient donc sur le défaut `'friend'`, et la porte la
-- plus fine du produit ne servait à rien. ⚠️ **Ça ne lève aucune erreur** :
-- la story s'affiche, le filtre s'applique, il se trouve seulement qu'il ne
-- filtre jamais rien.
--
-- C'est ce que le nouvel écran de partage rend enfin utilisable : trois cercles
-- réels — amis, proches, inséparables — là où Snapchat n'a que deux boutons.
--
-- ## ⚠️ POURQUOI UN `drop` ET PAS UN `create or replace`
--
-- Ajouter un paramètre **change la signature**, donc crée une SURCHARGE au lieu
-- de remplacer. Les deux coexisteraient, et l'appel à neuf arguments
-- deviendrait ambigu — `function is not unique` — c'est-à-dire une panne à
-- l'exécution sur un écran qui marchait la veille.
--
-- 🔴 **Et une suppression EFFACE LES DROITS** (leçon du 2026-08-29). Ils sont
-- relevés avant, et reposés plus bas :
--   `postgres:EXECUTE, authenticated:EXECUTE, service_role:EXECUTE`
--
-- ## Inventaire avant de supprimer — les deux sens
--
-- ⬅️ **Qui appelle ?** Un seul appelant, `StoriesRepository.publish`. Aucune
--    politique RLS, aucun trigger, aucune autre fonction SQL ne la cite —
--    vérifié sur `pg_proc.prosrc` et `pg_policies`.
-- ➡️ **Qu'appelle-t-elle ?** `contents`, `stories`, `content_media_keys`.
--    Aucune ne devient orpheline : la fonction est recréée à l'identique, avec
--    un paramètre de plus.
-- ===========================================================================

drop function if exists public.publish_story(
  uuid, card_type, text, text, boolean, boolean, boolean, text, boolean
);

create or replace function public.publish_story(
  p_story_id uuid,
  p_card_type card_type,
  p_front_path text,
  p_back_path text,
  p_front_is_video boolean,
  p_back_is_video boolean,
  p_shareable boolean,
  p_media_key text,
  p_saveable boolean default false,
  -- ⚠️ **Le défaut est le palier le plus BAS, jamais le plus haut.** Une valeur
  -- absente doit ouvrir la story à tous mes amis, pas la restreindre à mes
  -- inséparables : un repli qui ferme est un repli qui fait disparaître du
  -- contenu sans que personne comprenne pourquoi.
  p_min_tier friendship_tier default 'friend'
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Authentification requise';
  end if;

  insert into contents (id, owner_id, context, shareable, saveable)
  values (p_story_id, v_me, 'story', coalesce(p_shareable, false),
          coalesce(p_saveable, false));

  insert into stories (
    id, owner_id, card_type, front_path, back_path,
    front_is_video, back_is_video, min_tier
  )
  values (
    p_story_id, v_me, p_card_type, p_front_path, p_back_path,
    coalesce(p_front_is_video, false), coalesce(p_back_is_video, false),
    coalesce(p_min_tier, 'friend')
  );

  insert into content_media_keys (content_id, media_key)
  values (p_story_id, p_media_key);

  return p_story_id;
end;
$function$;

-- 🔴 **LES DROITS, REPOSÉS.** Sans ces lignes, l'app recevrait « permission
-- denied » sur une story qui partait la veille, et le diff ne montrerait qu'un
-- paramètre en plus.
--
-- ⚠️ `anon` n'est pas reconduit, et ce n'est pas un oubli : la fonction lève
-- de toute façon quand `auth.uid()` est nul. La règle est simplement énoncée
-- positivement.
grant execute on function public.publish_story(
  uuid, card_type, text, text, boolean, boolean, boolean, text, boolean,
  friendship_tier
) to authenticated, service_role;

comment on function public.publish_story(
  uuid, card_type, text, text, boolean, boolean, boolean, text, boolean,
  friendship_tier
) is
  'Publie une story et son contenu. `p_min_tier` décide du cercle qui la voit '
  '— la colonne existait depuis les paliers, plus rien ne l''écrivait.';

-- 🔴 **`revoke ... from public`, et ce n'est pas de la coquetterie.**
--
-- PostgreSQL accorde `EXECUTE` à `PUBLIC` sur toute fonction nouvellement
-- créée. Relevé juste après l'application de cette migration : la fonction
-- rendait `PUBLIC:EXECUTE, anon:EXECUTE` — alors que le commentaire ci-dessus
-- affirmait le contraire.
--
-- ⚠️ **Un commentaire qui affirme une règle de sécurité et une base qui en
-- applique une autre, c'est pire que pas de commentaire** : le lecteur suivant
-- croira la phrase et ne vérifiera pas. La règle s'énonce donc positivement —
-- ces deux-là n'ont pas le droit, et c'est écrit dans la base, pas dans un
-- commentaire.
revoke execute on function public.publish_story(
  uuid, card_type, text, text, boolean, boolean, boolean, text, boolean,
  friendship_tier
) from public, anon;
