-- Durcissement du socle des bibliothèques éphémères, suite à l'audit Supabase
-- lancé juste après l'application de `20260810190100_ephemeral_libraries.sql`.
--
-- Deux défauts introduits par cette migration, corrigés ici. Les deux ont été
-- trouvés par `get_advisors` et non à la relecture : lancer l'audit après
-- CHAQUE migration qui crée des fonctions ou des politiques.

-- 1. FAILLE. `purge_expired_library_vibes()` est une fonction de MAINTENANCE,
--    appelée uniquement par la tâche cron. Créée sans révocation, elle se
--    retrouvait exposée sur `/rest/v1/rpc/purge_expired_library_vibes` et
--    exécutable par `anon` comme par `authenticated` — alors qu'elle SUPPRIME
--    des lignes et des objets de stockage, en `SECURITY DEFINER` donc avec les
--    droits du propriétaire.
--    Portée réelle de l'abus : elle ne détruit que ce qui est déjà expiré
--    (vibes `ephemeral` dont le reveal a plus de 24 h), donc pas de perte de
--    données au-delà de la purge normale — mais rien ne justifie de la laisser
--    joignable depuis l'extérieur.
revoke execute on function public.purge_expired_library_vibes()
  from public, anon, authenticated;

-- 2. `search_path` mutable sur `library_reveal_at`. Sans `search_path` figé, un
--    rôle peut détourner la résolution des noms. Les autres fonctions du projet
--    le figent déjà ; celle-ci avait été écrite en `language sql` sans y penser.
alter function public.library_reveal_at(text, timestamptz)
  set search_path to 'public';

-- ─── Ce que l'audit signale encore, et qui est VOULU ───────────────────────
-- `public.library_vibe_keys` : « RLS enabled, no policy » (niveau INFO). C'est
-- exactement le dessein — aucune politique signifie que personne ne lit cette
-- table directement, quel que soit son rôle. Seule `get_library_vibe_key`,
-- en `SECURITY DEFINER`, y accède, et seulement une fois `reveal_at` passé.
-- Ne PAS « corriger » ce point en ajoutant une politique de lecture : ce serait
-- ouvrir la porte que tout le mécanisme sert à fermer.
