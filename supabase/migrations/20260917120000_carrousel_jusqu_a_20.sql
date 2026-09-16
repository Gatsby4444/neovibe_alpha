-- =====================================================================
-- Le carrousel va jusqu'à 20 médias  (Jay, 2026-09-17)
-- =====================================================================
--
-- Règle d'Instagram, reprise telle quelle : « carrousel : 2 à 20 médias ».
-- C'était 11 depuis le 2026-09-15 (« jusqu'à 11 contenus »).
--
-- Deux verrous, pas un : la place maximale d'un média (`slot`) ET le
-- contrôle de la RPC. Les bouger séparément, c'est soit une app qui laisse
-- composer ce que le serveur refuse, soit un serveur qui accepte ce que la
-- table rejette — dans les deux cas l'erreur n'apparaît qu'au dernier
-- moment, chez l'utilisateur.
--
-- ⚠️ La fonction ci-dessous est la fonction RELEVÉE EN BASE le 2026-09-17,
-- avec ses deux seules bornes changées. Elle n'est pas réécrite de mémoire :
-- une migration dit ce qui était vrai le jour où elle a été écrite, la base
-- dit ce qui est vrai.
--
-- Le format (4:5 / 1:1 / 1,91:1) n'est PAS touché : la contrainte
-- `library_items_aspect_by_kind` les admet déjà tous les trois (plus le 3:4
-- des publications d'avant le 2026-09-17, qui doivent rester lisibles).

alter table public.library_media
  drop constraint library_media_slot_check;

alter table public.library_media
  add constraint library_media_slot_check check (slot >= 0 and slot <= 19);

comment on table public.library_media is
  'Les médias d''une publication, à leur place. Une Card : places 0 et 1. Un album : 1 à 20 places. Le fichier est scellé avec la clé unique du contenu (content_media_keys).';

CREATE OR REPLACE FUNCTION public.publish_to_library(p_item_id uuid, p_kind library_kind, p_card_type card_type, p_media jsonb, p_caption text, p_is_public boolean, p_shareable boolean, p_saveable boolean, p_media_key text, p_aspect_w smallint DEFAULT NULL::smallint, p_aspect_h smallint DEFAULT NULL::smallint)
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

  insert into contents (id, owner_id, context, shareable, saveable)
  values (p_item_id, v_me, 'publication', coalesce(p_shareable, false),
          coalesce(p_saveable, false));

  insert into library_items (id, owner_id, kind, card_type, caption, is_public, aspect_w, aspect_h)
  values (
    p_item_id, v_me, p_kind, coalesce(p_card_type, 'standard'),
    nullif(p_caption, ''), coalesce(p_is_public, false),
    case when p_kind = 'album' then p_aspect_w end,
    case when p_kind = 'album' then p_aspect_h end
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
    if v_is_video and v_duration is not null and v_duration > 60000 then
      raise exception 'Une vidéo dure au plus une minute';
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
