-- =============================================================================
-- UNE SUPPRESSION SE VOIT TOUT DE SUITE — 2026-09-25
-- =============================================================================
--
-- Jay : « Il faut qu'une suppression soit effective immédiatement. »
--
-- Ce qui manquait : le Drop n'écoutait que les AJOUTS (un message
-- `library_add`), et le temps réel de Supabase ne sait pas filtrer une
-- SUPPRESSION par conversation (la ligne n'existe plus pour être comparée ni
-- pour que la politique de lecture tranche). Chez les autres, une Vibe
-- supprimée restait donc affichée jusqu'à la relecture suivante.
--
-- ⚠️ **La cause supprimée, pas colmatée** : une disparition devient un FAIT
-- qu'on ÉCRIT — une ligne de `removals`, filtrable par conversation et
-- soumise à la politique de lecture comme n'importe quel ajout. Les
-- téléphones l'écoutent comme ils écoutent déjà les messages.
--
-- ⚠️ **Posé sur les tables, pas dans les fonctions** : toute disparition est
-- annoncée, quel que soit son chemin — l'auteur, l'organisateur, la purge des
-- Vibes éphémères, la cascade d'une conversation. Un chemin oublié ne se
-- verrait ni au diff ni au test : il n'annoncerait rien, en silence.
--
-- Pas de clé étrangère vers `conversations` : c'est un journal de faits, et
-- une conversation supprimée en cascade doit pouvoir annoncer ses dernières
-- disparitions sans se heurter à elle-même. Purgé à 24 h (job séparé) : il
-- ne sert qu'au direct — un téléphone qui rouvre relit la vérité.
-- =============================================================================

create table public.removals (
  id bigint generated always as identity primary key,
  conversation_id uuid not null,
  kind text not null check (kind in ('drop_vibe', 'message')),
  target_id uuid not null,
  created_at timestamptz not null default now()
);
create index removals_conversation_idx on public.removals (conversation_id, created_at);
create index removals_created_idx on public.removals (created_at);

alter table public.removals enable row level security;
-- Lisible par les membres de la conversation, comme ce qu'elle annonce.
-- Aucune écriture : seuls les déclencheurs ci-dessous l'alimentent.
create policy removals_select_member on public.removals
  for select to authenticated
  using (private.is_conversation_member(conversation_id, (select auth.uid())));

create function private.annonce_une_disparition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'library_vibes' then
    insert into public.removals (conversation_id, kind, target_id)
    values (old.conversation_id, 'drop_vibe', old.id);
  -- Un message qui EXPIRE n'a rien à annoncer : chaque téléphone le retire
  -- déjà à l'heure dite. Seul un container retiré avant l'heure compte.
  elsif old.expires_at > now() then
    insert into public.removals (conversation_id, kind, target_id)
    values (old.conversation_id, 'message', old.id);
  end if;
  return old;
end;
$$;

create trigger library_vibes_annonce_disparition
  after delete on public.library_vibes
  for each row execute function private.annonce_une_disparition();

create trigger messages_annonce_disparition
  after delete on public.messages
  for each row execute function private.annonce_une_disparition();

alter publication supabase_realtime add table public.removals;

-- Un job à lui (règle : ne jamais greffer une nouveauté sur un job existant).
create function public.purge_removals()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.removals where created_at < now() - interval '24 hours';
$$;
revoke all on function public.purge_removals() from public, anon, authenticated;

select cron.schedule('neovibe_purge_removals', '41 * * * *', 'select public.purge_removals()');
