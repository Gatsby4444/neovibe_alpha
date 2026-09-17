-- =====================================================================
-- La légende : sa limite, et sa police  (Jay, 2026-09-17)
-- =====================================================================
--
-- Deux demandes de Jay après le test de la v0.9.196 :
--   « limite de 500 caractères, espaces et sauts de ligne compris »
--   « ce serait bien de pouvoir choisir la police d'écriture de la
--     description » — et il a tranché : **c'est l'auteur qui choisit**, à la
--     publication.
--
-- ⚠️ **La limite vit ICI, pas seulement dans l'écran de saisie.** Une règle
-- qui n'existe que dans un champ de texte n'est pas une règle : elle tombe
-- au premier client modifié, et personne ne s'en aperçoit avant de lire une
-- légende de dix mille signes dans un fil.
--
-- ⚠️ La fonction est **relevée en base** puis modifiée sur ses seuls points
-- utiles — elle n'est pas réécrite de mémoire. Et comme un paramètre de plus
-- fait une **autre** fonction pour PostgreSQL (surcharge), l'ancienne est
-- supprimée : deux surcharges, et PostgREST ne saurait plus laquelle appeler.

alter table public.library_items
  add column if not exists caption_font text;

alter table public.library_items
  drop constraint if exists library_items_caption_font;

alter table public.library_items
  add constraint library_items_caption_font check (
    caption_font is null
    or caption_font in ('moderne', 'rond', 'classique', 'signature', 'machine', 'neon')
  );

alter table public.library_items
  drop constraint if exists library_items_caption_len;

alter table public.library_items
  add constraint library_items_caption_len check (
    caption is null or char_length(caption) <= 500
  );

comment on column public.library_items.caption_font is
  'La police choisie par l''auteur pour sa légende (une valeur de OverlayFont côté app), nulle = la police du texte courant.';

drop function if exists public.publish_to_library(
  uuid, library_kind, card_type, jsonb, text, boolean, boolean, boolean, text,
  smallint, smallint
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


revoke all on function public.publish_to_library(
  uuid, library_kind, card_type, jsonb, text, boolean, boolean, boolean, text,
  smallint, smallint, text
) from public;

grant execute on function public.publish_to_library(
  uuid, library_kind, card_type, jsonb, text, boolean, boolean, boolean, text,
  smallint, smallint, text
) to authenticated, service_role;

-- ⚠️ Une fonction **recréée** reçoit les droits par défaut du schéma, et
-- Supabase y met `anon`. L'ancienne ne l'avait pas : on ne laisse pas une
-- migration élargir un droit au passage, même sur une fonction qui commence
-- par exiger une identité.
revoke execute on function public.publish_to_library(
  uuid, library_kind, card_type, jsonb, text, boolean, boolean, boolean, text,
  smallint, smallint, text
) from anon;
