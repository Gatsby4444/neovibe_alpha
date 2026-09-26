-- La table des diagnostics envoyés depuis l'app (Réglages › Développeur).
--
-- ⚠️ Fichier RECONSTITUÉ le 2026-09-26, lors de la répétition du déménagement
-- vers un VPS : la table existe en base de dev depuis le 2026-08-16 mais
-- AUCUNE migration ne la créait. Sur un serveur neuf, l'envoi d'un diagnostic
-- échouait donc (« relation dev_reports does not exist »). Colonnes,
-- contraintes, index et politiques relevés en base ce jour-là, à l'identique.
--
-- Outil de DÉVELOPPEMENT : à supprimer avant la production, avec l'écran qui
-- l'écrit (`lib/core/diagnostics/dev_report.dart`). Sans effet sur la base de
-- dev, qui l'a déjà.
create table if not exists public.dev_reports (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  app_version text,
  device text,
  note text,
  body text,
  data jsonb
);

comment on table public.dev_reports is
  'Outil de dev : rapports de diagnostic envoyés depuis l''app. À supprimer avant la prod.';

create index if not exists dev_reports_recent on public.dev_reports (created_at desc);

alter table public.dev_reports enable row level security;

-- Chacun ne voit, n'écrit et ne supprime que SES rapports.
drop policy if exists dev_reports_select_own on public.dev_reports;
create policy dev_reports_select_own on public.dev_reports
  for select to authenticated using (author_id = (select auth.uid()));
drop policy if exists dev_reports_insert_own on public.dev_reports;
create policy dev_reports_insert_own on public.dev_reports
  for insert to authenticated with check (author_id = (select auth.uid()));
drop policy if exists dev_reports_delete_own on public.dev_reports;
create policy dev_reports_delete_own on public.dev_reports
  for delete to authenticated using (author_id = (select auth.uid()));
