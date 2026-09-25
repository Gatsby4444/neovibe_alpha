-- =============================================================================
-- LE SCELLÉ DE MODÉRATION — 2026-09-25
-- =============================================================================
--
-- Jay : « Il faut que le serveur garde l'image pour les modérateurs. »
-- Option choisie par Jay : le **scellé sur place**, gardé **jusqu'au
-- traitement** du signalement.
--
-- Ce qui manquait : un signalement survivait à la suppression de la Vibe
-- (clé à NULL, auteur recopié), mais la preuve partait avec elle — la ligne,
-- sa clé (cascade) et, sept jours plus tard, ses fichiers (balai). La
-- console voyait le motif, jamais l'image.
--
-- ### Le principe
--
-- À l'instant où un signalement naît, le serveur **relève** les fichiers de
-- ce qu'il vise et **recopie leur clé** dans `moderation_holds`, une table
-- que PERSONNE ne lit — ni l'auteur, ni celui qui signale — hormis les
-- fonctions ci-dessous. Tant qu'un fichier y figure :
--
-- | Qui | Ce qui change |
-- |---|---|
-- | son propriétaire | ne peut plus l'effacer (politiques `*_delete_own`) |
-- | le balai | ne le rend plus à effacer (`mes_octets_a_supprimer`) |
-- | un administrateur | peut le lire (`moderation_read_held`) et obtenir sa clé (`admin_report_evidence`) |
-- | les membres | RIEN : leurs droits viennent toujours de la Vibe ; supprimée, elle ne leur donne plus rien |
--
-- Le fichier ne bouge pas : c'est l'ACCÈS qui change. Aucune copie, donc
-- rien à falsifier — les octets sont ceux de l'auteur, tels qu'il les a
-- déposés (aucune politique UPDATE sur ces coffres : on ne réécrit pas un
-- fichier existant).
--
-- ⚠️ **Posé sur les tables de signalements, pas dans les fonctions** : un
-- signalement né par n'importe quel chemin (RPC des Vibes, insertion directe
-- des contenus du socle) scelle sa preuve. Et il la **libère** en quittant
-- l'état « ouvert » (tranché, écarté) ou en disparaissant — jusqu'au
-- traitement, pas au-delà (Jay). Libéré, un fichier dont la ligne est partie
-- retourne au balai, qui le rendra à son propriétaire à la prochaine
-- ouverture de l'app.
-- =============================================================================

create table public.moderation_holds (
  id uuid primary key default gen_random_uuid(),
  report_kind text not null check (report_kind in ('content', 'drop_vibe', 'sent_vibe')),
  report_id uuid not null,
  bucket_id text not null,
  object_name text not null,
  -- 0 = recto, 1 = verso ; pour une publication, le rang de la diapo.
  rang smallint not null,
  is_video boolean not null default false,
  -- Nulle = fichier déposé en clair (Vibes d'avant le chiffrement).
  media_key text,
  created_at timestamptz not null default now(),
  unique (report_kind, report_id, bucket_id, object_name)
);
create index moderation_holds_object_idx on public.moderation_holds (bucket_id, object_name);
create index moderation_holds_report_idx on public.moderation_holds (report_kind, report_id);

alter table public.moderation_holds enable row level security;
-- ⚠️ **Aucune politique, et c'est la règle** : une clé de média ne se lit
-- que par `admin_report_evidence`, qui exige un administrateur.

-- Ce fichier est-il sous scellé ? Citée par des politiques de `storage` :
-- exécutable par `authenticated` (piège du 2026-08-11).
create function private.is_held(p_bucket text, p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.moderation_holds h
    where h.bucket_id = p_bucket and h.object_name = p_name
  );
$$;
revoke all on function private.is_held(text, text) from public, anon;
grant execute on function private.is_held(text, text) to authenticated;

-- ─── Sceller et libérer ─────────────────────────────────────────────────────

create function private.scelle_la_preuve()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text := case tg_table_name
    when 'library_vibe_reports' then 'drop_vibe'
    when 'card_reports' then 'sent_vibe'
    else 'content' end;
begin
  if v_kind = 'drop_vibe' then
    insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
    select v_kind, new.id, 'library_vault', f.chemin, f.rang, f.video, k.media_key
    from public.library_vibes v
    left join public.library_vibe_keys k on k.vibe_id = v.id
    cross join lateral (values
      (v.sealed_path, 0::smallint, v.front_is_video),
      (v.sealed_back_path, 1::smallint, v.back_is_video)
    ) as f(chemin, rang, video)
    where v.id = new.vibe_id and f.chemin is not null
    on conflict do nothing;

  elsif v_kind = 'sent_vibe' then
    insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
    select v_kind, new.id, 'cards', f.chemin, f.rang, f.video,
           case when c.encrypted then k.media_key end
    from public.cards c
    left join public.card_media_keys k on k.card_id = c.id
    cross join lateral (values
      (c.front_path, 0::smallint, c.front_is_video),
      (c.back_path, 1::smallint, c.back_is_video)
    ) as f(chemin, rang, video)
    where c.id = new.card_id and f.chemin is not null
    on conflict do nothing;

  else
    -- Une story…
    insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
    select v_kind, new.id, 'stories', f.chemin, f.rang, f.video,
           case when s.encrypted then k.media_key end
    from public.stories s
    left join public.content_media_keys k on k.content_id = s.id
    cross join lateral (values
      (s.front_path, 0::smallint, s.front_is_video),
      (s.back_path, 1::smallint, s.back_is_video)
    ) as f(chemin, rang, video)
    where s.id = new.content_id and f.chemin is not null
    on conflict do nothing;
    -- …ou une publication (ses diapos).
    insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
    select v_kind, new.id, 'library', m.path, m.slot, m.is_video, k.media_key
    from public.library_media m
    left join public.content_media_keys k on k.content_id = m.item_id
    where m.item_id = new.content_id and m.path is not null
    on conflict do nothing;
  end if;
  return new;
end;
$$;

create function private.libere_la_preuve()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text := case tg_table_name
    when 'library_vibe_reports' then 'drop_vibe'
    when 'card_reports' then 'sent_vibe'
    else 'content' end;
begin
  -- Tranché ou écarté (mise à jour), ou disparu (suppression) : libéré.
  if tg_op = 'DELETE' or new.status <> 'open' then
    delete from public.moderation_holds
    where report_kind = v_kind and report_id = old.id;
  end if;
  return null;
end;
$$;

create trigger library_vibe_reports_scelle after insert on public.library_vibe_reports
  for each row execute function private.scelle_la_preuve();
create trigger card_reports_scelle after insert on public.card_reports
  for each row execute function private.scelle_la_preuve();
create trigger content_reports_scelle after insert on public.content_reports
  for each row execute function private.scelle_la_preuve();

create trigger library_vibe_reports_libere after update of status or delete on public.library_vibe_reports
  for each row execute function private.libere_la_preuve();
create trigger card_reports_libere after update of status or delete on public.card_reports
  for each row execute function private.libere_la_preuve();
create trigger content_reports_libere after update of status or delete on public.content_reports
  for each row execute function private.libere_la_preuve();

-- ─── Ce que le scellé change pour les autres ───────────────────────────────

-- Le propriétaire efface ses fichiers — sauf ceux sous scellé.
drop policy cards_delete_own on storage.objects;
create policy cards_delete_own on storage.objects for delete using (
  bucket_id = 'cards'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and not private.is_held(bucket_id, name)
);
drop policy library_delete_own on storage.objects;
create policy library_delete_own on storage.objects for delete using (
  bucket_id = 'library'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and not private.is_held(bucket_id, name)
);
drop policy library_vault_delete on storage.objects;
create policy library_vault_delete on storage.objects for delete to authenticated using (
  bucket_id = 'library_vault'
  and (storage.foldername(name))[1] = (auth.uid())::text
  and not private.is_held(bucket_id, name)
);
drop policy stories_delete_own on storage.objects;
create policy stories_delete_own on storage.objects for delete using (
  bucket_id = 'stories'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and not private.is_held(bucket_id, name)
);

-- Le balai ne rend pas un fichier sous scellé : il le rendra une fois libéré.
create or replace function public.mes_octets_a_supprimer()
returns table (bucket_id text, object_name text)
language sql
security definer
set search_path to 'public'
as $$
  select t.bucket_id, t.object_name
  from public.storage_tombstones t
  where t.owner_id = auth.uid()
    and t.delete_after <= now()
    and not private.is_held(t.bucket_id, t.object_name)
  order by t.delete_after
  limit 200;
$$;

-- Un administrateur lit un fichier sous scellé — et seulement celui-là.
create policy moderation_read_held on storage.objects for select to authenticated using (
  private.is_admin((select auth.uid()))
  and private.is_held(bucket_id, name)
);

-- ─── La console ─────────────────────────────────────────────────────────────

create function public.admin_report_evidence(p_kind text, p_report uuid)
returns table (bucket_id text, object_name text, rang smallint, is_video boolean, media_key text)
language plpgsql
security definer
set search_path = public, private
as $$
declare
  me uuid := private.assert_admin();
begin
  -- Ouvrir une preuve est un acte de modération : il se journalise.
  perform private.log_action(me, 'view_evidence', null, null, null, p_kind, p_report, null);
  return query
  select h.bucket_id, h.object_name, h.rang, h.is_video, h.media_key
  from public.moderation_holds h
  where h.report_kind = p_kind and h.report_id = p_report
  order by h.rang;
end;
$$;
revoke all on function public.admin_report_evidence(text, uuid) from public, anon;
grant execute on function public.admin_report_evidence(text, uuid) to authenticated;

-- ─── Le journal connaît les nouvelles sortes ───────────────────────────────
-- ⚠️ **Correctif d'un défaut du 2026-09-25 (migration `…090000`)** : le
-- journal n'acceptait que les signalements `content` et `profile`. Trancher
-- un signalement de Vibe (`drop_vibe`, `sent_vibe`) aurait ÉCHOUÉ sur sa
-- ligne de journal — l'essai à blanc de ce jour-là ne jouait pas ce geste.
alter table public.moderation_actions drop constraint moderation_actions_report_kind_check;
alter table public.moderation_actions add constraint moderation_actions_report_kind_check
  check (report_kind = any (array['content', 'profile', 'drop_vibe', 'sent_vibe']));
alter table public.moderation_actions drop constraint moderation_actions_action_check;
alter table public.moderation_actions add constraint moderation_actions_action_check
  check (action = any (array['resolve_report', 'dismiss_report', 'suspend_user',
    'unsuspend_user', 'delete_content', 'close_event', 'view_evidence']));

-- Aucun signalement ouvert au 2026-09-25 (relevé en base) : rien à sceller
-- rétroactivement.
