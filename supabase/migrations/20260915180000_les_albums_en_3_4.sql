-- ===========================================================================
-- LES ALBUMS EN 3:4 — un seul format vertical (Jay, 2026-09-15, après test)
-- ===========================================================================
--
-- Jay, sur la v0.9.185 : « Le format n'est pas bon, on avait dit vertical
-- comme sur Instagram. » Tranché : **3:4 uniquement** — le format vertical
-- d'Instagram, un seul, pas de choix.
--
-- Le ratio reste porté par l'en-tête (`aspect_w`, `aspect_h`) : le visionneur
-- en a besoin pour afficher juste, et les albums déjà publiés en 1:1 pendant
-- le test gardent le leur. On AJOUTE 3:4 à la liste admise ; l'app, elle, ne
-- propose plus que celui-là.

alter table public.library_items
  drop constraint library_items_aspect_by_kind;

alter table public.library_items
  add constraint library_items_aspect_by_kind check (
    (kind = 'card' and aspect_w is null and aspect_h is null)
    or (kind = 'album' and (aspect_w, aspect_h) in ((3, 4), (1, 1), (4, 5), (191, 100)))
  );
