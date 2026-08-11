-- Deux corrections trouvées **par inventaire** après l'étape 2, invisibles
-- pour le compilateur comme pour l'analyse statique.

-- ---------------------------------------------------------------------------
-- 1. `profile_stats` était cassée
-- ---------------------------------------------------------------------------
--
-- Elle comptait les Vibes de la semaine en joignant `library_items.card_id` —
-- colonne supprimée par l'étape 2. La fonction levait donc à chaque appel.
--
-- Le compte devient celui du **socle** : toute publication et toute story
-- créées dans les 7 jours, plus les Vibes réellement envoyées dans le cercle.
-- C'est plus juste qu'avant, où une Vibe ni envoyée ni publiée n'était pas
-- comptée mais où rien ne comptait les stories.
create or replace function public.profile_stats(target uuid)
returns table(friends integer, posts integer, cards_week integer)
language sql
stable
security definer
set search_path = 'public', 'private'
as $$
  select
    (select count(*)::integer from connections
      where (user_low = target or user_high = target) and status = 'full'),
    (select count(*)::integer from library_items where owner_id = target),
    (
      (select count(*) from cards c
        where c.owner_id = target
          and c.created_at > now() - interval '7 days'
          and exists (select 1 from card_deliveries d where d.card_id = c.id))
      + (select count(*) from contents ct
          where ct.owner_id = target
            and ct.created_at > now() - interval '7 days')
    )::integer
  where auth.uid() = target or can_view_profile(auth.uid(), target);
$$;

-- ---------------------------------------------------------------------------
-- 2. `contents` était illisible par l'audience
-- ---------------------------------------------------------------------------
--
-- `shareable` a déménagé sur `contents` (socle unifié). Sans droit de lecture,
-- le client ne pouvait plus savoir s'il a le droit de relayer — le bouton de
-- partage n'apparaissait jamais, y compris pour l'auteur d'un contenu qu'il
-- avait lui-même marqué partageable.
--
-- L'audience d'un contenu peut légitimement savoir si elle peut le relayer :
-- c'est une propriété du contenu qu'elle consulte, pas une donnée d'autrui. Le
-- reste de la table (contexte, date de révocation) n'apprend rien de sensible,
-- et la **chaîne** de partage reste dans `content_grants`, qui n'a toujours
-- aucune politique.
--
-- Pas de récursion : `content_audience` est SECURITY DEFINER et interroge les
-- tables de format sans repasser par leurs politiques.
create policy contents_select_audience on public.contents
  for select using (private.content_audience(id, (select auth.uid())));
