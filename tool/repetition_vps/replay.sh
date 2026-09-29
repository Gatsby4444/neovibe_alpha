#!/bin/sh
# Rejoue chaque migration dans l'ordre, une transaction par fichier ; s'arrête à la première erreur.
# Les fins de ligne Windows (CRLF de la copie de travail) sont ramenées à LF.
#
# Par défaut, les chemins du conteneur de répétition (/work, /migr) et la
# base `postgres`. Le VPS passe les siens (server/outils/vps/monter_base.sh) :
#   BASE=neovibe TRAVAIL=/chemin/repetition_vps MIGR=/chemin/migrations sh replay.sh
BASE="${BASE:-postgres}"
TRAVAIL="${TRAVAIL:-/work}"
MIGR="${MIGR:-/migr}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
psql -q -v ON_ERROR_STOP=1 -U postgres -d "$BASE" -f "$TRAVAIL/bootstrap.sql" >/dev/null || exit 1
n=0
for f in $(ls "$MIGR"/*.sql | sort); do
  tr -d '\r' < "$f" | sed -E 's/create extension if not exists (pg_cron|pgsodium)[^;]*;/-- (répétition) extension absente : \1/I' > "$T/m.sql"
  if ! psql -q -v ON_ERROR_STOP=1 -1 -U postgres -d "$BASE" -f "$T/m.sql" > "$T/out.txt" 2>&1; then
    echo "ECHEC au fichier $(basename $f) (après $n fichiers réussis)"; grep -v NOTICE "$T/out.txt" | head -20; exit 1
  fi
  n=$((n+1))
done
echo "OK : $n fichiers rejoués sans erreur"
