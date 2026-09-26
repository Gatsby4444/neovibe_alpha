-- Le schéma propre au serveur Rust : `nv`.
--
-- Tout ce que le programme ajoute à la base (sessions de connexion, journal
-- des tâches, etc.) vit ici, à part des tables du produit. Ces migrations
-- ne sont JAMAIS appliquées à Supabase (pause des nouveautés côté serveur,
-- docs/serveur-rust.md) : seulement à la base du serveur Rust.
create schema if not exists nv;
