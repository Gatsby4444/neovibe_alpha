-- =============================================================================
-- RETRAIT D'UN RESTE MORT — 2026-09-25 (revue « la règle vit au serveur »)
-- =============================================================================
--
-- `finish_hot_view` servait les Vibes « Hot », retirées du produit le
-- 2026-08-10. Relevé le 2026-09-25 (règle 8, les deux sens) : aucun appelant
-- dans l'app ni dans le moindre corps de fonction, aucune Vibe « hot » en
-- base. Une porte appelable qui ne sert plus rien est une surface à garder
-- sans raison.
-- =============================================================================

drop function public.finish_hot_view(uuid);
