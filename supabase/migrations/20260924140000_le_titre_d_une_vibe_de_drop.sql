-- =============================================================================
-- LE TITRE D'UNE VIBE DE DROP — 2026-09-24
-- =============================================================================
--
-- Jay, sur l'écran de soirée validé : « on voit directement les vibes créées
-- dans l'événement, avec le titre et quand elles ont été publiées » ; au choix
-- « afficher l'auteur » ou « ajouter un vrai titre », il a choisi le titre.
--
-- Une ligne de Drop n'avait pas de titre (relevé en base le 2026-09-24 :
-- colonnes de `library_vibes` sans aucun texte). On ajoute :
-- - `library_vibes.title` : facultatif, rogné, 1 à 60 caractères ;
-- - un paramètre `p_title` aux deux fonctions d'ajout.
--
-- ⚠️ **Changer la liste des paramètres oblige à supprimer puis recréer** les
-- deux fonctions. Relevé avant (règle 8) :
-- - appelants SQL de `add_vibe_to_library` : aucun (seul son propre corps
--   cite le nom de la fonction privée) ;
-- - appelant de l'app : `LibraryVibesRepository.addVibe` (paramètres nommés,
--   donc `p_title` absent = NULL : les versions précédentes de l'app
--   continuent de marcher) ;
-- - droits d'origine, recopiés à l'identique en bas de ce fichier.
-- =============================================================================

alter table public.library_vibes
  add column title text
  check (title is null or (title = btrim(title) and char_length(title) between 1 and 60));

drop function public.add_vibe_to_library(uuid, uuid, text, text, text, card_type, boolean, boolean, boolean, boolean, text, text, uuid);
drop function private.unguarded_add_vibe_to_library(uuid, uuid, text, text, text, card_type, boolean, boolean, boolean, boolean, text, text, uuid);

create function private.unguarded_add_vibe_to_library(
  p_id uuid,
  p_conversation_id uuid,
  p_placeholder_path text,
  p_sealed_path text,
  p_media_key text,
  p_card_type card_type default 'standard'::card_type,
  p_front_is_video boolean default false,
  p_back_is_video boolean default false,
  p_saveable_by_others boolean default false,
  p_ephemeral boolean default false,
  p_placeholder_back_path text default null,
  p_sealed_back_path text default null,
  p_challenge_id uuid default null,
  p_title text default null
)
returns library_vibes
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare
  v_timezone text;
  v_type public.conversation_type;
  v_reveal timestamptz;
  v_vibe public.library_vibes;
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

  if v_title is not null and char_length(v_title) > 60 then
    raise exception 'Titre trop long (60 caractères au plus)';
  end if;

  select library_timezone, conversation_type into v_timezone, v_type
  from conversations where id = p_conversation_id;

  if v_type = 'event' then
    -- 2026-09-21 : visible tout de suite, pour les participants (Jay :
    -- « voir ce qui a été publié au cours de la soirée »). Le placeholder
    -- flouté ne sert plus qu'à l'affichage en attendant le scellé.
    v_reveal := now();
    if p_challenge_id is not null and not exists (
      select 1 from public.event_challenges c
      join public.events e on e.id = c.event_id
      where c.id = p_challenge_id and e.conversation_id = p_conversation_id
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
$function$;

create function public.add_vibe_to_library(
  p_id uuid,
  p_conversation_id uuid,
  p_placeholder_path text,
  p_sealed_path text,
  p_media_key text,
  p_card_type card_type default 'standard'::card_type,
  p_front_is_video boolean default false,
  p_back_is_video boolean default false,
  p_saveable_by_others boolean default false,
  p_ephemeral boolean default false,
  p_placeholder_back_path text default null,
  p_sealed_back_path text default null,
  p_challenge_id uuid default null,
  p_title text default null
)
returns library_vibes
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$ begin perform private.assert_not_suspended(); return private.unguarded_add_vibe_to_library(p_id, p_conversation_id, p_placeholder_path, p_sealed_path, p_media_key, p_card_type, p_front_is_video, p_back_is_video, p_saveable_by_others, p_ephemeral, p_placeholder_back_path, p_sealed_back_path, p_challenge_id, p_title); end; $function$;

-- Les droits d'origine, relevés en base le 2026-09-24, à l'identique.
revoke all on function public.add_vibe_to_library(uuid, uuid, text, text, text, card_type, boolean, boolean, boolean, boolean, text, text, uuid, text) from public;
grant execute on function public.add_vibe_to_library(uuid, uuid, text, text, text, card_type, boolean, boolean, boolean, boolean, text, text, uuid, text) to anon, authenticated, service_role;
grant execute on function private.unguarded_add_vibe_to_library(uuid, uuid, text, text, text, card_type, boolean, boolean, boolean, boolean, text, text, uuid, text) to public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
