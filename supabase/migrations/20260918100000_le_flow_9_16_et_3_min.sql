-- =====================================================================
-- Le FLOW, deuxième moitié : 9:16 et trois minutes  (Jay, 2026-09-18)
-- =====================================================================
--
-- Jay : *« insta convertit automatiquement les publications vidéo simples
-- en réel mais à la base un réel c'est du 9:16 donc on devrait ajouter une
-- 3ème option de publication "flow" […] avec une limite vidéo de 3 min et un
-- format 9:16 »*.
--
-- Deux règles serveur qui n'existaient pas :
--   - un Flow peut être en **9:16** (les publications restent à 4:5, 1:1,
--     1,91:1 — et un Flow issu d'une conversion garde le format d'origine) ;
--   - une vidéo de Flow va jusqu'à **180 s** ; une vidéo de publication
--     reste à 60 s. La table admet le plus grand, la RPC tranche par kind :
--     la table ne connaît pas le kind, la fonction si.
--
-- La fonction est relevée en base et modifiée sur sa seule garde de durée.

alter table public.library_items
  drop constraint library_items_aspect_by_kind;

alter table public.library_items
  add constraint library_items_aspect_by_kind check (
    (kind = 'card' and aspect_w is null and aspect_h is null)
    or (kind = 'album' and (aspect_w, aspect_h) in ((3, 4), (1, 1), (4, 5), (191, 100)))
    or (kind = 'flow' and (aspect_w, aspect_h) in ((3, 4), (1, 1), (4, 5), (191, 100), (9, 16)))
  );

alter table public.library_media
  drop constraint library_media_duration_ms_check;

alter table public.library_media
  add constraint library_media_duration_ms_check check (
    duration_ms is null or (duration_ms >= 1 and duration_ms <= 180000)
  );

CREATE OR REPLACE FUNCTION public.publish_to_library(p_item_id uuid, p_kind library_kind, p_card_type card_type, p_media jsonb, p_caption text, p_is_public boolean, p_shareable boolean, p_saveable boolean, p_media_key text, p_aspect_w smallint DEFAULT NULL::smallint, p_aspect_h smallint DEFAULT NULL::smallint, p_caption_font text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := auth.uid();
  v_count integer;
  v_slot integer := 0;
  v_m jsonb;
  v_path text;
  v_poster text;
  v_is_video boolean;
  v_duration integer;
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
  -- Un Flow est une vidéo publiée SEULE : c'est sa définition, pas une
  -- préférence d'affichage. Deux médias, ou une photo, et ce n'est plus un
  -- Flow — c'est une publication ordinaire, qui a son propre kind.
  if p_kind = 'flow' and (
       v_count <> 1
       or not coalesce((p_media -> 0 ->> 'is_video')::boolean, false)
     ) then
    raise exception 'Un Flow est une vidéo, et une seule';
  end if;

  insert into contents (id, owner_id, context, shareable, saveable)
  values (p_item_id, v_me, 'publication', coalesce(p_shareable, false),
          coalesce(p_saveable, false));

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
    -- Un Flow va jusqu'à trois minutes (Jay, 2026-09-18) ; une vidéo de
    -- publication reste à une minute — deux formats, deux règles.
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
$function$
;
