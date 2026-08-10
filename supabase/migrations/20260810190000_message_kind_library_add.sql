-- Bibliothèques éphémères — étape 1/2 : la valeur d'énumération.
--
-- Isolée dans sa propre migration à dessein : PostgreSQL interdit d'UTILISER
-- une valeur d'énumération dans la transaction qui l'a créée. La migration
-- suivante s'en sert dans `add_vibe_to_library`, elle ne peut donc pas la
-- déclarer elle-même.
--
-- `library_add` est l'annonce nommée postée dans le fil quand quelqu'un ajoute
-- une vibe à la bibliothèque de la conversation (consigne Jay 2026-08-10 :
-- nommément, pas un compteur anonyme). Le client la rend comme une ligne
-- système discrète, pas comme une bulle de message.

alter type public.message_kind add value if not exists 'library_add';
