-- Le FLOW, première moitié : la valeur d'enum, seule.
--
-- PostgreSQL refuse d'utiliser une valeur d'enum dans la transaction qui
-- l'ajoute. Elle vit donc dans sa propre migration, avant celle qui s'en
-- sert (`20260917170100_le_flow.sql`).
alter type public.library_kind add value if not exists 'flow';
