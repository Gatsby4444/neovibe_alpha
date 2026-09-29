-- LES DROITS D'UNE BASE EN SERVICE, après le retrait de l'ancien gardien
-- (migration « en service » : jamais sur la base de référence de la preuve,
-- où l'ancien gardien a besoin de ces droits pour être joué).
--
-- Relevé par le gardien-securite le 2026-09-29 : sans effet exploitable
-- (seuls `postgres` et `nv_server` peuvent se connecter), mais des droits
-- donnés à « tout le monde » (PUBLIC) et un droit devenu inutile au serveur.
-- La règle, énoncée positivement : **se connecte à cette base et exécute
-- ses fonctions celui à qui on l'a accordé, et lui seul.**

-- 1. Se connecter, créer des tables temporaires : `nv_server` (et
--    `postgres`), plus personne d'autre.
do $$ begin
  execute format('revoke connect, temporary on database %I from public', current_database());
  execute format('grant connect on database %I to nv_server', current_database());
end $$;

-- 2. Exécuter les fonctions (les fondations) : plus PUBLIC. `nv_server` a
--    ses droits (20260929000000_le_role_du_serveur.sql) ; les fondations
--    `security definer` s'exécutent de toute façon avec ceux de `postgres`.
revoke execute on all functions in schema public, private, storage, nv from public;
alter default privileges for role postgres revoke execute on functions from public;

-- 3. BYPASSRLS ne sert plus : il n'y a plus de règle RLS dans une base en
--    service (le rôle est au serveur de base ; sur le PC, la référence ne
--    s'en sert pas — la preuve y joue en `postgres` et en `authenticated`).
alter role nv_server nobypassrls;
