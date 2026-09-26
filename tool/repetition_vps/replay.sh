#!/bin/sh
# Rejoue chaque migration dans l'ordre, une transaction par fichier ; s'arrête à la première erreur.
# Les fins de ligne Windows (CRLF de la copie de travail) sont ramenées à LF.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f /work/bootstrap.sql >/dev/null || exit 1
n=0
for f in $(ls /migr/*.sql | sort); do
  tr -d '\r' < "$f" | sed -E 's/create extension if not exists (pg_cron|pgsodium)[^;]*;/-- (répétition) extension absente : \1/I' > /tmp/m.sql
  if ! psql -q -v ON_ERROR_STOP=1 -1 -U postgres -d postgres -f /tmp/m.sql > /tmp/out.txt 2>&1; then
    echo "ECHEC au fichier $(basename $f) (après $n fichiers réussis)"; grep -v NOTICE /tmp/out.txt | head -20; exit 1
  fi
  n=$((n+1))
done
echo "OK : $n fichiers rejoués sans erreur"
