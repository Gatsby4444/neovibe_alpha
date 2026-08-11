-- Renommage : la fonction compte des PERSONNES, pas des ouvertures.
--
-- `content_views` porte **une ligne par spectateur**, avec son propre
-- `view_count`. « story_view_count » laissait donc croire au nombre
-- d'ouvertures alors qu'elle renvoie le nombre de spectateurs — et c'est bien
-- « combien de personnes ont vu » que Jay veut afficher.
--
-- La migration précédente a été corrigée pour créer directement le bon nom :
-- ce fichier ne sert qu'aux environnements ayant déjà appliqué l'ancienne
-- version (la base de dev). Il est sans effet ailleurs.
drop function if exists public.story_view_count(uuid);

create or replace function public.story_viewer_count(p_story_id uuid)
returns integer
language sql
stable
security definer
set search_path = 'public'
as $$
  select coalesce(count(*), 0)::integer
  from content_views v
  where v.content_id = p_story_id
    and exists (
      select 1 from stories s
      where s.id = p_story_id and s.owner_id = auth.uid()
    );
$$;

revoke all on function public.story_viewer_count(uuid) from public, anon;
grant execute on function public.story_viewer_count(uuid) to authenticated;
