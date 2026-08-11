-- Un repartage doit SE VOIR dans le fil.
--
-- Isolée : PostgreSQL interdit d'utiliser une valeur d'énumération dans la
-- transaction qui la crée (leçon du 2026-08-10).
alter type public.message_kind add value 'content_share';
