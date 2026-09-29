#!/usr/bin/env bash
# Note le résultat de la sauvegarde nocturne (base + envoi hors du VPS) dans
# le journal des tâches du serveur, `nv.job_runs` — là où se lit déjà chaque
# passage des balais. Lancé par nv-sauvegarde.service (`ExecStopPost=+`),
# que la sauvegarde ait réussi ou non : un échec qui ne laisse aucune trace
# est le piège déjà payé de l'ancien réveil (pg_cron, 2026-08-10).
#
# ⚠️ Noter n'est pas prévenir : personne n'est alerté. La ligne se lit dans
# nv.job_runs (job = 'sauvegarde'), en attendant la surveillance (RAPPELS #11).
set -euo pipefail
OK=false
[ "${SERVICE_RESULT:-}" = success ] && OK=true
sudo -u postgres psql -d neovibe -q -v ON_ERROR_STOP=1 -v ok="$OK" \
  -v detail="${SERVICE_RESULT:-?} (code ${EXIT_STATUS:-?})" <<'SQL'
insert into nv.job_runs (job, finished_at, ok, detail) values ('sauvegarde', now(), :'ok'::boolean, :'detail');
SQL
