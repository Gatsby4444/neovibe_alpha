-- Separation des deux natures de vibe — decision de Jay, 2026-08-10.
--
-- ─── Le probleme ───────────────────────────────────────────────────────────
-- Une vibe de bibliotheque etait AUSSI une Card ordinaire : son original
-- partait donc EN CLAIR dans le bucket `cards`, en plus de la copie chiffree
-- dans `library_vault`. La protection reposait alors entierement sur l'ABSENCE,
-- dans `can_view_card_file`, d'une regle « les membres d'une conversation
-- voient les cards de cette conversation ».
--
-- Or cette regle parait naturelle — Jay lui-meme a suppose qu'elle existait
-- deja. Une protection qui repose sur l'absence d'une regle evidente finit
-- toujours par tomber : il aurait suffi qu'un jour quelqu'un l'ajoute, de bonne
-- foi, pour que le reveal cesse de proteger quoi que ce soit. En silence, sans
-- rien casser.
--
-- ─── La decision de Jay ────────────────────────────────────────────────────
-- Separer franchement les deux objets, parce qu'ils n'obeissent pas aux memes
-- regles :
--
--   Vibe ENVOYEE en conversation : bucket `cards`, acces par LIVRAISON
--     nominative, limites de vues et de duree, replay sur accord.
--   Vibe de BIBLIOTHEQUE : bucket `library_vault`, acces par APPARTENANCE a la
--     conversation, AUCUNE limite de vue ni de duree — seul le drapeau
--     ephemere compte —, contenu scelle jusqu'a la cle de 18h30.
--
-- Consequence : **plus aucun original en clair n'existe** pour une vibe de
-- bibliotheque. Le probleme n'est plus contenu, il est supprime — il n'y a plus
-- rien a proteger dans `cards`, et `can_view_card_file` ne concerne plus du
-- tout les bibliotheques.
--
-- `library_vibes` devient donc AUTONOME : elle porte elle-meme ce dont
-- l'affichage a besoin, au lieu de le lire sur une ligne `cards`.

alter table public.library_vibes
  add column if not exists card_type public.card_type not null default 'standard',
  add column if not exists front_is_video boolean not null default false,
  add column if not exists back_is_video boolean not null default false;

-- `card_id` devient facultatif : les vibes creees a partir de maintenant n'ont
-- plus de ligne `cards` du tout. Conservee nullable pour ne pas casser les
-- lignes deja enregistrees en base de dev.
alter table public.library_vibes alter column card_id drop not null;

create or replace function public.add_vibe_to_library(
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
  p_sealed_back_path text default null
)
returns public.library_vibes
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_timezone text;
  v_vibe public.library_vibes;
begin
  if not exists (
    select 1 from conversation_members
    where conversation_id = p_conversation_id and user_id = auth.uid()
  ) then
    raise exception 'Conversation introuvable';
  end if;

  -- Consigne Jay : pas de BeReal en bibliotheque. Le One of One n'y a pas de
  -- sens non plus — l'exclusivite d'un destinataire unique contredit un objet
  -- partage par toute une conversation.
  if p_card_type in ('bereal', 'one_of_one') then
    raise exception 'Ce type de vibe n''entre pas en bibliotheque';
  end if;

  select library_timezone into v_timezone
  from conversations where id = p_conversation_id;

  insert into library_vibes (
    id, conversation_id, author_id, reveal_at,
    card_type, front_is_video, back_is_video,
    saveable_by_others, ephemeral,
    placeholder_path, sealed_path,
    placeholder_back_path, sealed_back_path
  )
  values (
    p_id, p_conversation_id, auth.uid(),
    library_reveal_at(v_timezone),
    p_card_type, p_front_is_video, p_back_is_video,
    p_saveable_by_others, p_ephemeral,
    p_placeholder_path, p_sealed_path,
    p_placeholder_back_path, p_sealed_back_path
  )
  returning * into v_vibe;

  insert into library_vibe_keys (vibe_id, media_key) values (v_vibe.id, p_media_key);

  insert into messages (conversation_id, sender_id, kind, body)
  values (p_conversation_id, auth.uid(), 'library_add', null);

  return v_vibe;
end;
$fn$;

revoke execute on function public.add_vibe_to_library(
  uuid, uuid, text, text, text, public.card_type, boolean, boolean,
  boolean, boolean, text, text) from public, anon;
grant execute on function public.add_vibe_to_library(
  uuid, uuid, text, text, text, public.card_type, boolean, boolean,
  boolean, boolean, text, text) to authenticated;

-- L'ancienne signature disparait : un APK anterieur echouera proprement au lieu
-- d'enregistrer une vibe avec un original en clair dans `cards`.
drop function if exists public.add_vibe_to_library(
  uuid, uuid, uuid, text, text, text, boolean, boolean, text, text);
