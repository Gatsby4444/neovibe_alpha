-- Reste de l'étape 5 (2026-08-11) : `saved_cards` a été supprimée, mais la
-- politique de lecture des LIGNES de `cards` qui s'y référait est restée, via
-- une fonction intermédiaire.
--
-- Pourquoi le `drop table ... cascade` ne l'a pas emportée : le corps d'une
-- fonction SQL classique (`AS $$ ... $$`) est du TEXTE, réanalysé à l'exécution.
-- PostgreSQL n'y voit donc AUCUNE dépendance vers les tables citées. La fonction
-- a survécu à la table, et la politique à la fonction.
--
-- Effet observé (v0.9.54) : toute lecture de `cards` par un utilisateur
-- authentifié échouait — les politiques SELECT sont combinées par OU, et celle-ci
-- échouait au démarrage de la fonction, avant tout court-circuit possible.
--   select count(*) from public.cards;
--   → 42P01: relation "saved_cards" does not exist
--        CONTEXT: SQL function "has_saved" during startup
--
-- Correctif : supprimer la cause. Une sauvegarde est désormais une COPIE LOCALE
-- sur l'appareil ; il n'existe donc plus aucun accès serveur « parce que j'ai
-- enregistré ». Les chemins de lecture de `cards` reviennent aux deux voulus :
-- propriétaire et destinataire d'une livraison — exactement ceux de
-- `can_view_card_file` depuis l'étape 5.

drop policy if exists "cards_select_saved" on public.cards;
drop function if exists private.has_saved(uuid, uuid);
