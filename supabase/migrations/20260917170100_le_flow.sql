-- =====================================================================
-- Le FLOW — une vidéo publiée seule  (Jay, 2026-09-17)
-- =====================================================================
--
-- Jay : *« pour les publications je change d'avis, on permet la publication
-- d'une vidéo simple. […] On va les requalifier automatiquement comme un
-- nouveau contenu, comme fait Insta qui requalifie en Reel les vidéos
-- seules. »* Nom choisi : **Flow**.
--
-- ## Pourquoi un `kind` à lui, et pas un album d'un seul média
--
-- Un album et un Flow n'obéissent pas aux mêmes règles : un album accepte 1
-- à 20 médias de toute nature, un Flow est **exactement une vidéo**. Rangés
-- ensemble, c'est la règle la plus permissive qui gagne — en silence (règle 2
-- de `CLAUDE.md`). Et c'est le `kind` qui permettra demain de rassembler les
-- Flows dans un fil, ce qui est précisément ce que Jay en attend.
--
-- Ce qu'il partage avec une publication, en revanche, il le garde : **son
-- format** (4:5, 1:1 ou 1,91:1, choisi à la publication — Jay a écarté le
-- 9:16 imposé), son audience, sa légende, ses likes. Il se regarde comme une
-- publication, pas comme une Vibe.
--
-- ⚠️ `alter type … add value` vit dans **sa propre migration** (fichier
-- `…_le_flow_valeur.sql`) : PostgreSQL refuse d'UTILISER une valeur d'enum
-- ajoutée dans la même transaction.

-- Le ratio appartient maintenant aussi au Flow.
alter table public.library_items
  drop constraint library_items_aspect_by_kind;

alter table public.library_items
  add constraint library_items_aspect_by_kind check (
    (kind = 'card' and aspect_w is null and aspect_h is null)
    or (
      kind in ('album', 'flow')
      and (aspect_w, aspect_h) in ((3, 4), (1, 1), (4, 5), (191, 100))
    )
  );

comment on column public.library_items.kind is
  'card = une Vibe (une ou deux faces, 9:16) ; album = une publication de 1 à 20 médias ; flow = une vidéo publiée seule (Jay, 2026-09-17).';

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

  insert into library_items (id, owner_id, kind, card_type, caption, is_public, aspect_w, aspect_h)
  values (
    p_item_id, v_me, p_kind, coalesce(p_card_type, 'standard'),
    nullif(p_caption, ''), coalesce(p_is_public, false),
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
