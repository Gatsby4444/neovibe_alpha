-- NeoVibe V1 — buckets Storage, publication Realtime, purge cron

-- ============================================================
-- Buckets
-- ============================================================
insert into storage.buckets (id, name, public)
values
  ('avatars', 'avatars', true),
  ('media', 'media', false),     -- médias de messagerie (éphémères)
  ('cards', 'cards', false),     -- recto/verso des Cards
  ('library', 'library', false)  -- contenus de bibliothèque (persistants)
on conflict (id) do nothing;

-- Convention de chemin : {user_id}/... pour tous les buckets privés.
-- L'écriture est toujours limitée au dossier de l'utilisateur.

-- avatars : lecture publique (bucket public), écriture dans son dossier
create policy "avatars_write_own" on storage.objects for insert
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "avatars_update_own" on storage.objects for update
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "avatars_delete_own" on storage.objects for delete
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- media : lecture si un message NON EXPIRÉ d'une de mes conversations pointe ce fichier
create policy "media_write_own" on storage.objects for insert
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "media_read_via_message" on storage.objects for select
  using (
    bucket_id = 'media'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (
        select 1 from public.messages m
        where m.media_path = name
          and m.expires_at > now()
          and public.is_conversation_member(m.conversation_id, (select auth.uid()))
      )
    )
  );
create policy "media_delete_own" on storage.objects for delete
  using (bucket_id = 'media' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- cards : lecture par le propriétaire, un destinataire non détruit, ou via bibliothèque
create policy "cards_write_own" on storage.objects for insert
  with check (bucket_id = 'cards' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "cards_read_via_delivery" on storage.objects for select
  using (
    bucket_id = 'cards'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (
        select 1 from public.cards c
        join public.card_deliveries d on d.card_id = c.id
        where (c.front_path = name or c.back_path = name)
          and d.recipient_id = (select auth.uid())
          and d.destroyed_at is null
      )
      or exists (
        select 1 from public.cards c
        join public.library_items li on li.card_id = c.id
        where (c.front_path = name or c.back_path = name)
          and public.can_view_library(li.owner_id, (select auth.uid()))
      )
    )
  );
create policy "cards_delete_own" on storage.objects for delete
  using (bucket_id = 'cards' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- library : lecture selon les règles d'accès de la bibliothèque
create policy "library_write_own" on storage.objects for insert
  with check (bucket_id = 'library' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "library_read_via_acl" on storage.objects for select
  using (
    bucket_id = 'library'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (
        select 1 from public.library_items li
        where li.media_path = name
          and public.can_view_library(li.owner_id, (select auth.uid()))
      )
    )
  );
create policy "library_delete_own" on storage.objects for delete
  using (bucket_id = 'library' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ============================================================
-- Realtime
-- ============================================================
alter publication supabase_realtime add table
  public.messages,
  public.connection_requests,
  public.connections,
  public.recommendations,
  public.conversations,
  public.conversation_members,
  public.card_deliveries,
  public.message_reads,
  public.waves;

-- ============================================================
-- Purge périodique (pg_cron) — garantit l'éphémère côté données
-- ============================================================
create extension if not exists pg_cron;

select cron.schedule(
  'neovibe_purge',
  '*/5 * * * *',
  $$
  -- Messages expirés (24h)
  delete from public.messages where expires_at < now();
  -- Demandes BLE expirées (sortie de portée)
  update public.connection_requests set status = 'expired'
    where status = 'pending' and expires_at < now();
  -- Recommandations expirées (silencieux pour B)
  update public.recommendations set status = 'expired'
    where status in ('requested', 'forwarded') and expires_at < now();
  -- Connexions partielles non confirmées sous 3 jours
  delete from public.connections
    where status = 'partial' and partial_expires_at < now();
  -- Cards oneshot entièrement détruites et non référencées
  delete from public.cards c
    where c.card_type = 'oneshot'
      and exists (select 1 from public.card_deliveries d where d.card_id = c.id and d.destroyed_at is not null)
      and not exists (select 1 from public.card_deliveries d where d.card_id = c.id and d.destroyed_at is null);
  $$
);
