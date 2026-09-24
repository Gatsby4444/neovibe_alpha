-- =============================================================================
-- « CE USERNAME EST-IL LIBRE ? » — 2026-09-24
-- =============================================================================
--
-- Jay : dire à l'inscription si le username est libre pendant qu'on le tape,
-- au lieu de l'apprendre après la création du compte.
--
-- ⚠️ Appelable SANS compte (`anon`) : l'inscription pose la question avant
-- d'avoir un compte. Ce que ça révèle — « ce username existe » — est déjà
-- public : le username signe toutes les publications. La fonction ne rend
-- qu'un booléen, jamais une ligne.
--
-- Elle ne décide de rien : c'est l'index `profiles_username_unique` qui refuse
-- un doublon au moment de créer le profil. Ceci ne sert qu'à le dire plus tôt.
-- =============================================================================

create or replace function public.username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_username ~ '^[a-z0-9._]{3,20}$'
     and not exists (
       select 1 from public.profiles
       where lower(display_name) = lower(p_username)
     );
$$;

revoke all on function public.username_available(text) from public;
grant execute on function public.username_available(text) to anon, authenticated;

notify pgrst, 'reload schema';
