-- Une rencontre en soirée SANS LIEU ne fait plus tout échouer.
--
-- Trouvé le 2026-09-27 par la preuve du serveur Rust (docs/serveur-rust.md,
-- domaine 4), puis REPRODUIT sur la base de dev sous l'identité d'un compte
-- (transaction annulée) : quand deux présents d'une soirée se reconnaissent,
-- `report_sightings` crée un croisement en soirée, dont le déclencheur
-- appelle `private.note_meeting` avec le lieu de la soirée. Si la soirée n'a
-- pas de lieu (une soirée PRIVÉE — 1 sur 14 en base ce jour-là), la variable
-- `g` n'était jamais remplie, et la lire faisait planter la fonction :
--   « record "g" is not assigned yet »
-- … et avec elle TOUT l'envoi des reconnaissances, y compris celles entre
-- amis qui voyageaient dans le même envoi.
--
-- Réparation : deux variables simples, `null` quand il n'y a pas de lieu.
-- Même signature : les droits d'exécution sont conservés.
create or replace function private.note_meeting(
  a uuid, b uuid, p_origin text, p_event uuid, p_title text,
  p_lat double precision, p_lon double precision, p_at timestamp with time zone)
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  v_lat double precision;
  v_lng double precision;
begin
  if a = b or private.is_blocked(a, b) then return; end if;
  if p_lat is not null and p_lon is not null then
    select g.lat, g.lng into v_lat, v_lng from private.gomme_ancre(p_lat, p_lon) g;
  end if;
  if p_event is not null then
    insert into public.meetings (user_id, other_id, origin, event_id, event_title, lat, lon, met_at, last_at)
    values (a, b, p_origin, p_event, p_title, v_lat, v_lng, p_at, p_at),
           (b, a, p_origin, p_event, p_title, v_lat, v_lng, p_at, p_at)
    on conflict (user_id, other_id, event_id) where event_id is not null
      do update set last_at = greatest(meetings.last_at, excluded.last_at);
  else
    insert into public.meetings (user_id, other_id, origin, met_at, last_at)
    values (a, b, p_origin, p_at, p_at), (b, a, p_origin, p_at, p_at);
  end if;
end;
$$;
