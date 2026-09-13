-- ===========================================================================
-- LES MESSAGES VOCAUX — demande de Jay du 2026-09-13
-- ===========================================================================
--
-- « La possibilité d'envoyer des messages vocaux, uniquement dans les chats
-- de groupe ou DM, pas en mode ping inconnus. »
--
-- Grille de décision (CLAUDE.md) : « augmenter la valeur d'une relation
-- existante » — un vocal ne s'échange qu'entre amis, dans un fil qui existe.
--
-- ---------------------------------------------------------------------------
-- CE QU'EST UN VOCAL, ET CE QU'IL N'EST PAS
-- ---------------------------------------------------------------------------
--
--   · C'est un **média de message** : il vit avec son message (24 h,
--     `messages.expires_at`), il est lisible par les membres de la
--     conversation, et il meurt avec lui (`on delete cascade`). Même règle
--     d'accès et même cycle de vie que les photos/vidéos de message : donc
--     **même bucket** (`media`, politique `media_read_via_message`). Règle 2 de
--     CLAUDE.md dans l'autre sens : deux objets qui obéissent aux MÊMES règles
--     ne se fabriquent pas deux rangements.
--   · Il est **scellé** (format par blocs `NVC1`, comme une Vibe) : le fichier
--     sur le serveur est du bruit sans la clé, et la clé ne sort que par une
--     fonction qui vérifie qu'on est membre et que le message n'a pas expiré.
--     C'est la promesse « ce qui se passe sur NeoVibe reste sur NeoVibe »,
--     surface DM/chat = verrouillée (CLAUDE.md, précision du 2026-09-11).
--   · Ce n'est **pas** une Vibe : pas de compte de vues, pas de `max_views`,
--     pas de `cards`. Obtenir la clé n'est pas « consommer une vue ».
--   · **Pas dans un canal de proximité** : déjà refusé par
--     `enforce_message_rules` (« limité au texte »). **Le chat d'un événement
--     PRIVÉ, oui** — « c'est un groupe aussi » (Jay, 2026-09-13) ; celui d'un
--     événement d'établissement, non : le lieu filtre, pas la relation.
--
-- ---------------------------------------------------------------------------
-- LA CLÉ — une table sans aucune politique, comme `content_media_keys`
-- ---------------------------------------------------------------------------
--
-- Personne ne lit `message_media_keys` directement : RLS activée, zéro
-- politique, aucun droit direct. Elle n'est touchée que par les deux fonctions
-- ci-dessous, en `security definer`. Un chemin, une clé.
--
-- ⚠️ Fonctions `public` en `security definer` : exécutables par
-- `authenticated`, jamais par `anon` (piège Supabase déjà payé, CLAUDE.md).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Le genre de message, et sa durée
-- ---------------------------------------------------------------------------

alter type public.message_kind add value if not exists 'voice';

-- La durée est une donnée du MESSAGE, pas du fichier : l'écran l'affiche
-- avant d'avoir téléchargé un seul octet, et le fichier scellé ne la dit pas
-- sans la clé.
alter table public.messages add column if not exists duration_ms integer;

-- ---------------------------------------------------------------------------
-- 2. La clé
-- ---------------------------------------------------------------------------

create table if not exists public.message_media_keys (
  message_id uuid primary key references public.messages(id) on delete cascade,
  media_key  text not null
);

alter table public.message_media_keys enable row level security;
-- Règle énoncée positivement : cette table n'a AUCUN lecteur direct.
revoke all on public.message_media_keys from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Envoyer : le message et sa clé dans la même transaction
-- ---------------------------------------------------------------------------
--
-- Un message sans clé serait un vocal que personne ne peut écouter ; une clé
-- sans message, une clé orpheline. Les deux se posent ensemble ou pas du tout.
-- ⚠️ En `security definer`, l'insertion dans `messages` ne passe PAS par la
-- politique `messages_insert_member` : la fonction refait donc ses contrôles
-- elle-même, dans le même ordre (membre, droit d'écrire — blocage compris).
-- Le trigger `enforce_message_rules`, lui, s'applique quand même.

create or replace function public.send_voice_message(
  p_conversation_id uuid,
  p_media_path text,
  p_duration_ms integer,
  p_media_key text
) returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_me uuid := auth.uid();
  v_type public.conversation_type;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Non authentifié';
  end if;
  if p_media_path is null or p_media_key is null or length(p_media_key) = 0 then
    raise exception 'Vocal incomplet';
  end if;
  if p_duration_ms is null or p_duration_ms <= 0 or p_duration_ms > 120000 then
    raise exception 'Durée de vocal hors bornes';
  end if;
  -- Le fichier doit être dans le dossier de l'expéditeur : c'est ce que la
  -- politique du bucket `media` exige pour l'écriture, et ce qui empêche de
  -- pointer un message vers le média de quelqu'un d'autre.
  if split_part(p_media_path, '/', 1) <> v_me::text then
    raise exception 'Chemin de média invalide';
  end if;

  select conversation_type into v_type
  from public.conversations where id = p_conversation_id;
  if v_type is null then
    raise exception 'Conversation introuvable';
  end if;
  -- DM, groupes, et le chat d'un événement PRIVÉ (Jay, 2026-09-13 : « c'est
  -- un groupe aussi »). Le chat d'un événement d'établissement, non : ses
  -- membres sont réunis par le lieu, pas par la relation.
  if v_type = 'event' then
    if not exists (
      select 1 from public.events e
      where e.conversation_id = p_conversation_id and e.kind = 'private'
    ) then
      raise exception 'Les vocaux ne s''envoient pas dans un événement d''établissement';
    end if;
  elsif v_type not in ('direct', 'group') then
    raise exception 'Les vocaux ne s''envoient que dans un DM ou un groupe';
  end if;
  if not private.is_conversation_member(p_conversation_id, v_me) then
    raise exception 'Conversation introuvable';
  end if;
  if not private.can_write_in_conversation(p_conversation_id, v_me) then
    raise exception 'Vous ne pouvez pas écrire dans cette conversation';
  end if;

  insert into public.messages (conversation_id, sender_id, kind, media_path, duration_ms)
  values (p_conversation_id, v_me, 'voice', p_media_path, p_duration_ms)
  returning id into v_id;

  insert into public.message_media_keys (message_id, media_key)
  values (v_id, p_media_key);

  return v_id;
end;
$$;

revoke all on function public.send_voice_message(uuid, text, integer, text) from public, anon;
grant execute on function public.send_voice_message(uuid, text, integer, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Écouter : la clé, si on est membre et que le message vit encore
-- ---------------------------------------------------------------------------
--
-- Même juge que la lecture du message (`messages_select_member_unexpired`) :
-- membre, non expiré, et arrivé après qu'on a rejoint la conversation. Un
-- membre qui ne voit pas le message ne doit pas pouvoir en obtenir la clé.

create or replace function public.open_voice_message(p_message_id uuid)
returns text
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_me uuid := auth.uid();
  v_key text;
begin
  if v_me is null then
    raise exception 'Non authentifié';
  end if;
  if not exists (
    select 1
    from public.messages m
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id = v_me
    where m.id = p_message_id
      and m.kind = 'voice'
      and m.expires_at > now()
      and m.created_at >= cm.joined_at
  ) then
    raise exception 'Vocal introuvable';
  end if;

  select media_key into v_key
  from public.message_media_keys where message_id = p_message_id;
  if v_key is null then
    raise exception 'Vocal indisponible : sa clé n''a jamais été déposée';
  end if;
  return v_key;
end;
$$;

revoke all on function public.open_voice_message(uuid) from public, anon;
grant execute on function public.open_voice_message(uuid) to authenticated;
