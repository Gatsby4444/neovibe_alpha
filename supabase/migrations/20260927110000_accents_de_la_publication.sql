-- Les messages de la publication retrouvent leurs accents.
--
-- Trouvé le 2026-09-27 en traduisant la publication pour le serveur Rust,
-- puis REPRODUIT sur la base de dev sous l'identité de Charles : une
-- publication refusée répondait « MÃ©dias manquants ». Dix lignes de
-- `20260920160000_le_feed_pulse.sql` avaient été enregistrées avec des
-- accents abîmés (double encodage) ; la fonction en a hérité, puis
-- `20260921220000_administration.sql` l'a renommée
-- `private.unguarded_publish_to_library` telle quelle.
--
-- Même fonction, même logique : seuls les messages sont réparés.
create or replace function private.unguarded_publish_to_library(
  p_item_id uuid, p_kind library_kind, p_card_type card_type, p_media jsonb, p_caption text,
  p_is_public boolean, p_shareable boolean, p_saveable boolean, p_media_key text,
  p_aspect_w smallint default null, p_aspect_h smallint default null, p_caption_font text default null,
  p_anchor_lat double precision default null, p_anchor_lng double precision default null)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  v_me uuid := auth.uid();
  v_count integer;
  v_slot integer := 0;
  v_m jsonb;
  v_path text;
  v_poster text;
  v_is_video boolean;
  v_duration integer;
  v_lat double precision;
  v_lng double precision;
begin
  if v_me is null then
    raise exception 'Authentification requise';
  end if;
  if p_media is null or jsonb_typeof(p_media) <> 'array' then
    raise exception 'Médias manquants';
  end if;
  v_count := jsonb_array_length(p_media);
  if p_kind = 'card' and v_count not between 1 and 2 then
    raise exception 'Une Card a une ou deux faces';
  end if;
  if p_kind = 'album' and v_count not between 1 and 20 then
    raise exception 'Une publication contient de 1 à 20 médias';
  end if;
  if p_kind = 'flow' and (
       v_count <> 1
       or not coalesce((p_media -> 0 ->> 'is_video')::boolean, false)
     ) then
    raise exception 'Un Flow est une vidéo, et une seule';
  end if;
  if p_anchor_lat is not null and p_anchor_lng is not null then
    select g.lat, g.lng into v_lat, v_lng from private.gomme_ancre(p_anchor_lat, p_anchor_lng) g;
  end if;
  insert into contents (id, owner_id, context, shareable, saveable, anchor_lat, anchor_lng)
  values (p_item_id, v_me, 'publication', coalesce(p_shareable, false),
          coalesce(p_saveable, false), v_lat, v_lng);
  insert into library_items (id, owner_id, kind, card_type, caption, caption_font, is_public, aspect_w, aspect_h)
  values (
    p_item_id, v_me, p_kind, coalesce(p_card_type, 'standard'),
    nullif(p_caption, ''), nullif(p_caption_font, ''),
    coalesce(p_is_public, false),
    case when p_kind in ('album', 'flow') then p_aspect_w end,
    case when p_kind in ('album', 'flow') then p_aspect_h end
  );
  for v_m in select * from jsonb_array_elements(p_media) loop
    v_path := v_m ->> 'path';
    v_poster := v_m ->> 'poster_path';
    v_is_video := coalesce((v_m ->> 'is_video')::boolean, false);
    v_duration := (v_m ->> 'duration_ms')::integer;
    if v_path is null or (storage.foldername(v_path))[1] <> v_me::text then
      raise exception 'Chemin de média hors du dossier du propriétaire';
    end if;
    if v_poster is not null and (storage.foldername(v_poster))[1] <> v_me::text then
      raise exception 'Chemin de couverture hors du dossier du propriétaire';
    end if;
    if v_is_video and v_duration is not null
       and v_duration > (case when p_kind = 'flow' then 180000 else 60000 end) then
      raise exception 'Une vidéo dure au plus % ',
        case when p_kind = 'flow' then 'trois minutes' else 'une minute' end;
    end if;
    insert into library_media (item_id, owner_id, slot, path, is_video, duration_ms, poster_path, width, height)
    values (
      p_item_id, v_me, v_slot, v_path, v_is_video,
      case when v_is_video then v_duration end,
      case when v_is_video then v_poster end,
      (v_m ->> 'width')::integer,
      (v_m ->> 'height')::integer
    );
    v_slot := v_slot + 1;
  end loop;
  insert into content_media_keys (content_id, media_key)
  values (p_item_id, p_media_key);
  return p_item_id;
end;
$$;
