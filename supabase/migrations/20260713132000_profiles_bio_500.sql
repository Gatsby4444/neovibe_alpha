-- Bio étendue à 500 caractères (consigne Jay 2026-07-13) ; l'affichage
-- replie au-delà de 130 caractères côté client (« voir plus »).
alter table public.profiles
  drop constraint if exists profiles_bio_check;
alter table public.profiles
  add constraint profiles_bio_check
  check (bio is null or char_length(bio) <= 500);
