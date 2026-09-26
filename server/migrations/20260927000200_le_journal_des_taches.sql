-- Le journal des tâches automatiques du serveur Rust.
--
-- Chaque passage d'une tâche (un balai) y laisse une ligne : quand, combien
-- de temps, réussi ou non, et ce qu'il a fait. L'ancien réveil (pg_cron)
-- échouait EN SILENCE (constaté le 2026-08-10 : un job cassé ne le disait à
-- personne) : ici, un échec se lit.
create table if not exists nv.job_runs (
  id bigserial primary key,
  job text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  ok boolean,
  detail text
);
create index if not exists job_runs_job_idx on nv.job_runs (job, started_at desc);
