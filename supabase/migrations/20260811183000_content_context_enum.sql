-- Contexte de diffusion — énumération, ISOLÉE dans sa propre migration.
--
-- PostgreSQL interdit d'utiliser une valeur d'énumération dans la transaction
-- qui la crée (leçon du 2026-08-10, migration `message_kind_library_add`).
-- D'où ce fichier qui ne fait que ça.
--
-- Refonte du 2026-08-11 — « 1 contenu = 1 format » : un média appartient à UN
-- SEUL contexte de diffusion, choisi à l'envoi, et n'en change jamais. Chaque
-- contexte a ses propres règles d'accès, son propre stockage et son propre
-- cycle de vie. Le repartage n'est pas une copie : c'est un CHEMIN vers la
-- source (consigne de Jay).
--
-- `bereal` est volontairement ABSENT : Jay a mis ce format de côté le
-- 2026-08-11 (« j'ai d'autres projets, ce n'est pas la priorité »). La règle
-- d'accès du BeReal n'étant pas connue, créer sa valeur maintenant reviendrait
-- à inventer sa règle plus tard pour la faire rentrer dans le conteneur —
-- l'ordre inverse de la consigne architecturale. L'ajouter le jour venu est
-- un `alter type ... add value`, pas une refonte : la place est réservée par
-- la conception, pas par une valeur morte.
create type public.content_context as enum (
  'story',                 -- 24 h, audience du cercle, repartageable si `shareable`
  'publication',           -- bibliothèque de profil
  'direct',                -- partage dans le cercle (DM et groupes), jamais repartageable
  'conversation_library'   -- bibliothèque éphémère de conversation (déjà livrée)
);
