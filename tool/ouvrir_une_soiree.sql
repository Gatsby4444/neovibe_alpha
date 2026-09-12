-- ===========================================================================
-- OUVRIR UNE SOIRÉE D'ÉTABLISSEMENT — outil de test, base de DEV seulement
-- ===========================================================================
--
-- La plateforme des commerçants n'existe pas encore : ce script joue son rôle.
-- Il crée un lieu à la position donnée, en fait un gérant du compte donné, et
-- ouvre une soirée qui se fermera seule.
--
-- Mode d'emploi : remplacer les quatre valeurs ci-dessous, coller le tout dans
-- l'éditeur SQL du projet de dev (ou le passer par le PAT), puis dans l'app :
-- Cercle → 🎉 → « Autour de moi » → « Je suis là ».
--
-- ⚠️ Il faut ÊTRE à moins de 60 m + 100 m du point déclaré pour entrer : mettre
-- la latitude et la longitude de l'endroit où l'on teste (Google Maps → clic
-- droit → les deux nombres).
-- ===========================================================================

do $$
declare
  -- ⬇️ À REMPLACER ⬇️
  gerant   uuid := '135ed9b3-03a0-4f28-a2f3-784223a2dcde';  -- le compte qui gère (Testeur)
  nom      text := 'Le Temple';                              -- le nom du lieu
  latitude double precision := 48.8600;                      -- où l'on teste
  longitude double precision := 2.3400;
  duree    interval := interval '4 hours';                   -- la soirée se ferme seule après
  -- ⬆️ À REMPLACER ⬆️

  lieu uuid;
  conv uuid;
  soiree uuid;
begin
  insert into public.venues (name, address, lat, lon, radius_m, created_by)
  values (nom, 'lieu de test', latitude, longitude, 60, gerant)
  returning id into lieu;

  insert into public.venue_managers (venue_id, user_id) values (lieu, gerant);

  insert into public.conversations (conversation_type, title, created_by)
  values ('event', 'Soirée à ' || nom, gerant)
  returning id into conv;

  insert into public.events
    (kind, title, created_by, venue_id, conversation_id, lat, lon, radius_m,
     starts_at, scheduled_end_at)
  values
    ('venue', 'Soirée à ' || nom, gerant, lieu, conv, latitude, longitude, 60,
     now(), now() + duree)
  returning id into soiree;

  insert into public.conversation_members (conversation_id, user_id)
  values (conv, gerant);

  raise notice 'Lieu % — soirée % ouverte jusqu''à %', lieu, soiree, now() + duree;
end $$;
