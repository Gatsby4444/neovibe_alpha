-- Verso des vibes de bibliotheque — demande de Jay au test de la v0.9.44 :
-- pouvoir ouvrir une vibe en grand MEME FLOUTEE et basculer de face, comme
-- dans la bibliotheque du profil.
--
-- Jusqu'ici seul le recto etait masque et scelle : le verso d'un Oneshot ou
-- d'une vibe a deux faces n'avait ni placeholder ni copie chiffree — il n'y
-- avait donc rien a montrer avant le reveal.
--
-- Colonnes NULLABLES : une vibe a une seule face reste valide (le verso est
-- facultatif depuis la refonte du 2026-08-10).
--
-- La cle reste UNIQUE pour les deux faces : AES-GCM tire un nonce aleatoire a
-- chaque chiffrement, reutiliser la cle sur deux fichiers distincts est donc
-- sur. Une cle par face doublerait le stockage sans rien apporter.

alter table public.library_vibes
  add column if not exists placeholder_back_path text,
  add column if not exists sealed_back_path text;

create or replace function public.add_vibe_to_library(
  p_id uuid,
  p_conversation_id uuid,
  p_card_id uuid,
  p_placeholder_path text,
  p_sealed_path text,
  p_media_key text,
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
  v_card_type card_type;
  v_vibe public.library_vibes;
begin
  if not exists (
    select 1 from conversation_members
    where conversation_id = p_conversation_id and user_id = auth.uid()
  ) then
    raise exception 'Conversation introuvable';
  end if;

  select card_type into v_card_type
  from cards where id = p_card_id and owner_id = auth.uid();
  if not found then
    raise exception 'Vibe introuvable';
  end if;

  if v_card_type = 'bereal' then
    raise exception 'Le BeReal n''entre pas en bibliotheque';
  end if;

  if v_card_type = 'one_of_one' then
    raise exception 'Une One of One n''entre pas en bibliotheque';
  end if;

  select library_timezone into v_timezone
  from conversations where id = p_conversation_id;

  insert into library_vibes (
    id, conversation_id, card_id, author_id, reveal_at,
    saveable_by_others, ephemeral,
    placeholder_path, sealed_path,
    placeholder_back_path, sealed_back_path
  )
  values (
    p_id, p_conversation_id, p_card_id, auth.uid(),
    library_reveal_at(v_timezone),
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
  uuid, uuid, uuid, text, text, text, boolean, boolean, text, text)
  from public, anon;
grant execute on function public.add_vibe_to_library(
  uuid, uuid, uuid, text, text, text, boolean, boolean, text, text)
  to authenticated;

-- L'ancienne signature a 8 arguments disparait : un APK anterieur appellera une
-- fonction inexistante et verra son ajout echouer proprement, plutot que
-- d'enregistrer une vibe sans verso.
drop function if exists public.add_vibe_to_library(
  uuid, uuid, uuid, text, text, text, boolean, boolean);

-- ─── Politiques de stockage : les DEUX faces ───────────────────────────────
drop policy if exists library_vault_read_placeholder on storage.objects;
create policy library_vault_read_placeholder on storage.objects
  for select to authenticated
  using (
    bucket_id = 'library_vault'
    and exists (
      select 1
      from public.library_vibes v
      join public.conversation_members m
        on m.conversation_id = v.conversation_id and m.user_id = auth.uid()
      where storage.objects.name in (v.placeholder_path, v.placeholder_back_path)
    )
  );

drop policy if exists library_vault_read_sealed on storage.objects;
create policy library_vault_read_sealed on storage.objects
  for select to authenticated
  using (
    bucket_id = 'library_vault'
    and exists (
      select 1
      from public.library_vibes v
      join public.conversation_members m
        on m.conversation_id = v.conversation_id and m.user_id = auth.uid()
      where storage.objects.name in (v.sealed_path, v.sealed_back_path)
        and now() >= v.reveal_at - interval '5 minutes'
    )
  );

-- La purge doit emporter les QUATRE fichiers, pas deux.
create or replace function public.purge_expired_library_vibes()
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  delete from storage.objects
  where bucket_id = 'library_vault'
    and name in (
      select unnest(array_remove(array[
        placeholder_path, sealed_path, placeholder_back_path, sealed_back_path
      ], null))
      from library_vibes
      where ephemeral and now() > reveal_at + interval '24 hours'
    );

  delete from library_vibes
  where ephemeral and now() > reveal_at + interval '24 hours';
end;
$fn$;

-- Fonction de MAINTENANCE : jamais joignable depuis l'API (cf. migration
-- 20260810190200, meme motif).
revoke execute on function public.purge_expired_library_vibes()
  from public, anon, authenticated;
