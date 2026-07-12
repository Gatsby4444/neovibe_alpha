-- Mode Mono : une card à face unique — back_path devient nullable, mais
-- uniquement pour le type mono (les autres types gardent leurs deux faces).
alter table public.cards alter column back_path drop not null;
alter table public.cards add constraint cards_back_required
  check (back_path is not null or card_type = 'mono');

-- Import galerie (cards classiques/mono) : l'image ne vient pas d'une capture
-- en direct — signalé par un petit logo galerie sur le container en chat.
alter table public.cards add column imported boolean not null default false;
