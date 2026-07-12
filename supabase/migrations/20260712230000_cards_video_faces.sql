-- Mode vidéo (consignes Jay 2026-07-12) : chaque face d'une card peut être
-- une photo ou une vidéo. `scrubbable` : le créateur décide à l'envoi si le
-- destinataire peut contrôler la barre de lecture (défaut : intouchable).
alter table public.cards
  add column front_is_video boolean not null default false,
  add column back_is_video boolean not null default false,
  add column scrubbable boolean not null default false;
