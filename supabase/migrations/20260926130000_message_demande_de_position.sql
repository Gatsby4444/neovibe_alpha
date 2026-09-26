-- Un nouveau type de message : la demande de position d'un ami (2026-09-26).
-- À part : une valeur ajoutée à un type énuméré ne peut servir qu'une fois
-- validée (`20260926130100_demander_la_position.sql` s'en sert).
alter type public.message_kind add value if not exists 'location_request';
