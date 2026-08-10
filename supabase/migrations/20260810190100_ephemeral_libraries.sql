-- Bibliothèques éphémères de conversation — étape 2/2 : le socle.
--
-- Spécification complète et arrêtée : `docs/bibliotheques-ephemeres.md`.
-- Principe : on ajoute une vibe à une bibliothèque partagée par une
-- conversation au lieu de l'envoyer. Tout reste masqué pour TOUS, auteur
-- compris, jusqu'au reveal de 18h30.
--
-- ─── Où se fait le masquage ────────────────────────────────────────────────
-- Le client possède l'original (c'est lui qui l'a capturé). Il fabrique donc
-- lui-même le placeholder (réduction à 16-24 px) et chiffre l'original avec une
-- clé aléatoire, puis confie cette clé au serveur. AUCUN traitement d'image
-- côté serveur n'est nécessaire — pas d'Edge Function.
--
-- La garantie ne repose pas sur le client mais sur la RÉTENTION DE LA CLÉ :
-- avant `reveal_at`, `get_library_vibe_key` refuse de la donner, donc le média
-- scellé est un bloc illisible même pour un client modifié.
--
-- ⚠️ Limite honnête et assumée : pour l'AUTEUR, « ne pas voir ses propres
-- ajouts » ne peut pas être garanti par la cryptographie — il a capturé
-- l'image, elle est passée par son appareil, et c'est son client qui a fabriqué
-- la clé. C'est une promesse d'INTERFACE (aucun aperçu, rien d'affiché), pas une
-- barrière technique. Pour tous les autres membres, la barrière est réelle.

-- ─── Fuseau de la conversation ─────────────────────────────────────────────
-- Consigne Jay : un SEUL instant de reveal pour toute la conversation, fixé à
-- sa création. Tout le monde découvre au même moment réel, où qu'il soit —
-- c'est ce qui fait l'événement partagé. Écarté : « 18h30 à l'heure locale de
-- chacun », qui détruirait le moment commun.
alter table public.conversations
  add column if not exists library_timezone text not null default 'Europe/Paris';

-- ─── Calcul de l'heure de reveal ───────────────────────────────────────────
-- La journée de collecte va de 18h30 à 18h30 (consigne Jay) : une vibe ajoutée
-- APRÈS le reveal du jour part dans le lot du lendemain.
create or replace function public.library_reveal_at(
  p_timezone text,
  p_at timestamptz default now()
)
returns timestamptz
language sql
immutable
as $$
  select case
    when (p_at at time zone p_timezone)::time < time '18:30'
      then ((p_at at time zone p_timezone)::date + time '18:30') at time zone p_timezone
    else (((p_at at time zone p_timezone)::date + 1) + time '18:30') at time zone p_timezone
  end
$$;

-- ─── Les entrées de bibliothèque ───────────────────────────────────────────
create table if not exists public.library_vibes (
  id uuid primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  card_id uuid not null references public.cards(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,

  -- Instant du reveal. La révélation est une règle de LECTURE, pas un travail
  -- planifié : rien ne « bascule » à 18h30, c'est `now() >= reveal_at` qui
  -- décide. Aucune tâche cron n'est donc nécessaire pour révéler.
  reveal_at timestamptz not null,

  -- Drapeaux posés par l'auteur à la prise.
  -- `saveable_by_others` gouverne LES AUTRES : l'auteur peut toujours
  -- sauvegarder sa propre vibe au reveal.
  saveable_by_others boolean not null default false,
  -- `ephemeral` : disparaît 24 h après le reveal. Le défaut est FAUX — le but
  -- est une bibliothèque souvenir (consigne Jay).
  ephemeral boolean not null default false,

  -- Média. Le placeholder est lisible tout de suite ; le scellé ne l'est qu'à
  -- partir de reveal_at moins 5 minutes (préchargement), et reste illisible
  -- sans la clé.
  placeholder_path text not null,
  sealed_path text not null,

  created_at timestamptz not null default now(),
  unique (conversation_id, card_id)
);

create index if not exists library_vibes_conversation_reveal_idx
  on public.library_vibes (conversation_id, reveal_at desc);

-- ─── Les clés, isolées dans leur propre table ──────────────────────────────
-- Séparées de `library_vibes` parce que la RLS de PostgreSQL agit par LIGNE et
-- non par COLONNE : laisser la clé dans la table principale la livrerait à tout
-- membre autorisé à lire la ligne, donc avant le reveal. Ici, la table n'a
-- AUCUNE politique — nul ne la lit directement, seule la fonction ci-dessous y
-- accède, et seulement une fois l'heure passée.
create table if not exists public.library_vibe_keys (
  vibe_id uuid primary key references public.library_vibes(id) on delete cascade,
  media_key text not null
);

alter table public.library_vibes enable row level security;
alter table public.library_vibe_keys enable row level security;

revoke all on public.library_vibe_keys from public, anon, authenticated;

-- Un membre de la conversation voit les ENTRÉES (qui a ajouté, combien, quand
-- ça se révèle) dès l'ajout — cohérent avec l'annonce nommée dans le fil. Ce
-- qu'il ne voit pas, c'est le contenu.
drop policy if exists library_vibes_select on public.library_vibes;
create policy library_vibes_select on public.library_vibes
  for select to authenticated
  using (
    exists (
      select 1 from public.conversation_members m
      where m.conversation_id = library_vibes.conversation_id
        and m.user_id = auth.uid()
    )
  );

-- Pas de politique d'insertion, de mise à jour ni de suppression : tout passe
-- par les fonctions ci-dessous, qui valident l'appartenance et les règles.

-- ─── Ajouter une vibe à la bibliothèque ────────────────────────────────────
-- L'identifiant est fabriqué par le CLIENT, qui en a besoin avant l'appel pour
-- nommer ses fichiers dans le bucket.
create or replace function public.add_vibe_to_library(
  p_id uuid,
  p_conversation_id uuid,
  p_card_id uuid,
  p_placeholder_path text,
  p_sealed_path text,
  p_media_key text,
  p_saveable_by_others boolean default false,
  p_ephemeral boolean default false
)
returns public.library_vibes
language plpgsql
security definer
set search_path to 'public'
as $$
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

  -- Consigne Jay 2026-08-10 : pas de BeReal en bibliothèque. Les autres types
  -- sont acceptés — le Oneshot y compris, sa « vue unique puis destruction »
  -- n'existant plus depuis le 2026-07-11.
  if v_card_type = 'bereal' then
    raise exception 'Le BeReal n''entre pas en bibliothèque';
  end if;

  -- Une vibe de bibliothèque n'est JAMAIS une One of One, même en DM. Sans
  -- cette exemption, la règle livrée en v0.9.42 (un destinataire, aucune
  -- publication) la rendrait exclusive et non sauvegardable, ce qui viderait de
  -- leur sens les drapeaux « sauvegardable » et « souvenir ».
  if v_card_type = 'one_of_one' then
    raise exception 'Une One of One n''entre pas en bibliothèque';
  end if;

  select library_timezone into v_timezone
  from conversations where id = p_conversation_id;

  insert into library_vibes (
    id, conversation_id, card_id, author_id, reveal_at,
    saveable_by_others, ephemeral, placeholder_path, sealed_path
  )
  values (
    p_id, p_conversation_id, p_card_id, auth.uid(),
    library_reveal_at(v_timezone),
    p_saveable_by_others, p_ephemeral, p_placeholder_path, p_sealed_path
  )
  returning * into v_vibe;

  insert into library_vibe_keys (vibe_id, media_key) values (v_vibe.id, p_media_key);

  -- Annonce NOMMÉE dans le fil (consigne Jay, contre le compteur anonyme).
  -- Réserve signalée et maintenue par lui : cela expose chaque jour qui
  -- participe et qui s'abstient. À réévaluer au test.
  insert into messages (conversation_id, sender_id, kind, body)
  values (p_conversation_id, auth.uid(), 'library_add', null);

  return v_vibe;
end;
$$;

-- ─── La clé : le seul vrai verrou ──────────────────────────────────────────
-- Refuse la clé tant que l'heure n'est pas venue. L'auteur n'est PAS exempté :
-- la règle « même l'envoyeur ne voit pas ses ajouts » vaut aussi pour lui côté
-- serveur (avec la limite honnête rappelée en tête de fichier).
create or replace function public.get_library_vibe_key(p_vibe_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_vibe public.library_vibes;
begin
  select * into v_vibe from library_vibes where id = p_vibe_id;
  if not found then
    raise exception 'Vibe introuvable';
  end if;

  if not exists (
    select 1 from conversation_members
    where conversation_id = v_vibe.conversation_id and user_id = auth.uid()
  ) then
    -- Même message que « introuvable » : ne pas confirmer l'existence d'une
    -- vibe à quelqu'un qui n'est pas de la conversation.
    raise exception 'Vibe introuvable';
  end if;

  if now() < v_vibe.reveal_at then
    raise exception 'Le reveal n''a pas encore eu lieu';
  end if;

  return (select media_key from library_vibe_keys where vibe_id = p_vibe_id);
end;
$$;

revoke execute on function public.add_vibe_to_library(
  uuid, uuid, uuid, text, text, text, boolean, boolean) from public, anon;
revoke execute on function public.get_library_vibe_key(uuid) from public, anon;
grant execute on function public.add_vibe_to_library(
  uuid, uuid, uuid, text, text, text, boolean, boolean) to authenticated;
grant execute on function public.get_library_vibe_key(uuid) to authenticated;

-- ─── Le coffre de stockage ─────────────────────────────────────────────────
insert into storage.buckets (id, name, public)
values ('library_vault', 'library_vault', false)
on conflict (id) do nothing;

-- Dépôt : chacun n'écrit que sous son propre identifiant, ce qui interdit
-- d'écraser le fichier d'autrui. Le client dépose AVANT d'enregistrer la vibe
-- (il lui faut les chemins pour l'appel), d'où une politique qui ne peut pas
-- s'appuyer sur `library_vibes`.
drop policy if exists library_vault_insert on storage.objects;
create policy library_vault_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'library_vault'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Lecture du placeholder : tout de suite, pour les membres.
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
      where v.placeholder_path = storage.objects.name
    )
  );

-- Lecture du scellé : seulement à partir de 5 minutes avant le reveal, pour
-- laisser l'app précharger les octets. Ils restent illisibles sans la clé, qui
-- n'arrive qu'à l'heure pile.
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
      where v.sealed_path = storage.objects.name
        and now() >= v.reveal_at - interval '5 minutes'
    )
  );

-- L'auteur peut retirer ses propres fichiers (annulation, purge).
drop policy if exists library_vault_delete on storage.objects;
create policy library_vault_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'library_vault'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ─── Purge des vibes éphémères ─────────────────────────────────────────────
-- Seules les vibes marquées `ephemeral` disparaissent, 24 h après leur reveal.
-- Le défaut étant « souvenir », l'immense majorité reste.
create or replace function public.purge_expired_library_vibes()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  delete from storage.objects
  where bucket_id = 'library_vault'
    and name in (
      select placeholder_path from library_vibes
      where ephemeral and now() > reveal_at + interval '24 hours'
      union all
      select sealed_path from library_vibes
      where ephemeral and now() > reveal_at + interval '24 hours'
    );

  -- La suppression de la ligne emporte la clé (cascade).
  delete from library_vibes
  where ephemeral and now() > reveal_at + interval '24 hours';
end;
$$;

-- Greffé sur la tâche de purge existante plutôt que d'en créer une seconde :
-- `cron.schedule` réécrit le job de même nom.
select cron.schedule(
  'neovibe_purge',
  '*/5 * * * *',
  $$
  delete from public.messages where expires_at < now();
  update public.connection_requests set status = 'expired'
    where status = 'pending' and expires_at < now();
  update public.recommendations set status = 'expired'
    where status in ('requested', 'forwarded') and expires_at < now();
  delete from public.connections
    where status = 'partial' and partial_expires_at < now();
  delete from public.encounters where last_seen_at < now() - interval '24 hours';
  delete from public.stories where expires_at < now();
  select public.purge_expired_library_vibes();
  $$
);
