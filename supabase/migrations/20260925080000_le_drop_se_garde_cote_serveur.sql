-- =============================================================================
-- LE DROP SE GARDE CÔTÉ SERVEUR — 2026-09-25
-- =============================================================================
--
-- Constaté par Jay : par la caméra principale, on pouvait poser une Vibe dans
-- le Drop d'un événement **après sa fermeture** et **après en être sorti**, et
-- y poser un **fond uni** (la caméra du Drop ne le propose pas : « le but est
-- de prendre de vraies photos ou vidéos »). L'écran était la seule garde ;
-- un second chemin (la caméra principale) ne la portait pas.
--
-- ⚠️ **La règle vit ici, une fois, quel que soit le chemin** (règle 3 de
-- `CLAUDE.md` : compter les chemins). `add_vibe_to_library` est la seule
-- porte d'écriture de `library_vibes` (aucune politique INSERT sur la table).
--
-- 1. **Le Drop d'un événement n'accepte qu'un présent, pendant l'événement.**
--    Énoncé positivement : l'événement de cette conversation est ouvert
--    (`closed_at is null`) ET j'y ai une présence en cours (`left_at is
--    null`). Vrai pour les deux origines (privé, établissement) : la
--    présence est déjà la preuve d'accès de chacune (`join_event`).
--
-- 2. **Un Drop n'accepte que des faces prises à la caméra** — ni import de
--    la galerie, ni fond uni. ⚠️ Limite honnête : le serveur ne voit pas
--    l'image (elle arrive scellée, et aucun service ne la regarde — voir
--    `docs/serveur-media.md`, non construit). Il exige donc que l'app
--    **déclare** l'origine (`p_camera_only`), et refuse toute autre réponse
--    — y compris l'absence de réponse d'une ancienne version. Ce qui est
--    fermé : tous les chemins de l'app. Ce qui ne l'est pas : une app
--    modifiée qui mentirait.
-- =============================================================================

drop function if exists public.add_vibe_to_library(
  uuid, uuid, text, text, text, public.card_type, boolean, boolean, boolean,
  boolean, text, text, uuid, text
);
drop function if exists private.unguarded_add_vibe_to_library(
  uuid, uuid, text, text, text, public.card_type, boolean, boolean, boolean,
  boolean, text, text, uuid, text
);

create function private.unguarded_add_vibe_to_library(
  p_id uuid,
  p_conversation_id uuid,
  p_placeholder_path text,
  p_sealed_path text,
  p_media_key text,
  p_card_type public.card_type,
  p_front_is_video boolean,
  p_back_is_video boolean,
  p_saveable_by_others boolean,
  p_ephemeral boolean,
  p_placeholder_back_path text,
  p_sealed_back_path text,
  p_challenge_id uuid,
  p_title text,
  p_camera_only boolean
)
returns public.library_vibes
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_timezone text;
  v_type public.conversation_type;
  v_reveal timestamptz;
  v_vibe public.library_vibes;
  v_event public.events;
  -- Un titre vide ou fait d'espaces n'est pas un titre.
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
begin
  if not exists (
    select 1 from conversation_members
    where conversation_id = p_conversation_id and user_id = auth.uid()
  ) then
    raise exception 'Conversation introuvable';
  end if;

  if p_card_type in ('bereal', 'one_of_one') then
    raise exception 'Ce type de vibe n''entre pas en bibliotheque';
  end if;

  -- 2026-09-25 : de vraies photos ou vidéos, déclarées par l'app.
  if p_camera_only is distinct from true then
    raise exception 'Le Drop n''accepte que des photos ou vidéos prises à la caméra';
  end if;

  if v_title is not null and char_length(v_title) > 60 then
    raise exception 'Titre trop long (60 caractères au plus)';
  end if;

  select library_timezone, conversation_type into v_timezone, v_type
  from conversations where id = p_conversation_id;

  if v_type = 'event' then
    -- 2026-09-25 : ouvert, et j'y suis.
    select * into v_event from public.events where conversation_id = p_conversation_id;
    if not found or v_event.closed_at is not null then
      raise exception 'Cet événement est terminé : son Drop est fermé';
    end if;
    if not exists (
      select 1 from public.event_presences
      where event_id = v_event.id and user_id = auth.uid() and left_at is null
    ) then
      raise exception 'Tu n''es plus dans cet événement : son Drop t''est fermé';
    end if;

    -- 2026-09-21 : visible tout de suite, pour les participants (Jay :
    -- « voir ce qui a été publié au cours de la soirée »). Le placeholder
    -- flouté ne sert plus qu'à l'affichage en attendant le scellé.
    v_reveal := now();
    if p_challenge_id is not null and not exists (
      select 1 from public.event_challenges c
      where c.id = p_challenge_id and c.event_id = v_event.id
    ) then
      raise exception 'Défi introuvable';
    end if;
  else
    if p_challenge_id is not null then raise exception 'Un défi appartient à un événement'; end if;
    v_reveal := library_reveal_at(v_timezone);
  end if;

  insert into library_vibes (
    id, conversation_id, author_id, reveal_at,
    card_type, front_is_video, back_is_video,
    saveable_by_others, ephemeral,
    placeholder_path, sealed_path,
    placeholder_back_path, sealed_back_path,
    challenge_id, title
  )
  values (
    p_id, p_conversation_id, auth.uid(),
    v_reveal,
    p_card_type, p_front_is_video, p_back_is_video,
    p_saveable_by_others, p_ephemeral,
    p_placeholder_path, p_sealed_path,
    p_placeholder_back_path, p_sealed_back_path,
    p_challenge_id, v_title
  )
  returning * into v_vibe;

  insert into library_vibe_keys (vibe_id, media_key) values (v_vibe.id, p_media_key);

  insert into messages (conversation_id, sender_id, kind, body)
  values (p_conversation_id, auth.uid(), 'library_add', null);

  return v_vibe;
end;
$$;

create function public.add_vibe_to_library(
  p_id uuid,
  p_conversation_id uuid,
  p_placeholder_path text,
  p_sealed_path text,
  p_media_key text,
  p_card_type public.card_type default 'standard',
  p_front_is_video boolean default false,
  p_back_is_video boolean default false,
  p_saveable_by_others boolean default false,
  p_ephemeral boolean default false,
  p_placeholder_back_path text default null,
  p_sealed_back_path text default null,
  p_challenge_id uuid default null,
  p_title text default null,
  p_camera_only boolean default null
)
returns public.library_vibes
language plpgsql
security definer
set search_path = public, private
as $$
begin
  perform private.assert_not_suspended();
  return private.unguarded_add_vibe_to_library(
    p_id, p_conversation_id, p_placeholder_path, p_sealed_path, p_media_key,
    p_card_type, p_front_is_video, p_back_is_video, p_saveable_by_others,
    p_ephemeral, p_placeholder_back_path, p_sealed_back_path, p_challenge_id,
    p_title, p_camera_only
  );
end;
$$;

-- Le schéma `private` n'est pas exposé par PostgREST : seule la porte
-- publique est joignable, et seulement par un compte connecté.
revoke all on function public.add_vibe_to_library(
  uuid, uuid, text, text, text, public.card_type, boolean, boolean, boolean,
  boolean, text, text, uuid, text, boolean
) from public, anon;
grant execute on function public.add_vibe_to_library(
  uuid, uuid, text, text, text, public.card_type, boolean, boolean, boolean,
  boolean, text, text, uuid, text, boolean
) to authenticated;
