-- =============================================================================
-- LES DÉFIS EN DIRECT — 2026-09-24
-- =============================================================================
--
-- Jay : l'écran de soirée doit vivre sans qu'on tire pour rafraîchir. Les
-- présences et les messages sont déjà diffusés (`supabase_realtime`) ; le
-- Drop se suit par les messages `library_add` que pose chaque ajout. Il ne
-- manquait que les défis.
--
-- La diffusion respecte la politique de lecture de la table
-- (`event_challenges_read` : `concerned_by_event`) : un défi n'arrive qu'à
-- ceux qui ont le droit de le lire.
-- =============================================================================

alter publication supabase_realtime add table public.event_challenges;
