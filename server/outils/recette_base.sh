#!/bin/sh
# LA recette de la base du serveur NeoVibe — une seule, pour le PC et le VPS.
#   1. l'imitation minimale de Supabase et les migrations de
#      supabase/migrations/ (tool/repetition_vps/replay.sh) ;
#   2. les migrations du serveur Rust (server/migrations/) — et, pour une
#      base EN SERVICE (EN_SERVICE=<server/migrations_en_service>), les
#      siennes, rangées parmi elles par ordre_des_migrations.sh, le même
#      ordre que sur le VPS ;
#   3. la copie des données de dev (importer_copie.sql).
#
# Appelée par server/outils/base_locale.py (dans le conteneur de la base
# locale). (Sur le VPS, elle a servi à monter la base avant la bascule ;
# depuis, la base du VPS évolue par migrations — deployer.sh.) Elle parle
# à PostgreSQL en tant que `postgres` et suppose la base créée, avec son
# search_path (`"$user", public, extensions`).
#
#   BASE=… TRAVAIL=<repetition_vps> MIGR=<supabase/migrations>
#   NVMIGR=<server/migrations> OUTILS=<server/outils> COPIE=<copie> [EN_SERVICE=<dossier>] sh recette_base.sh
#
# Sans EN_SERVICE : la base de RÉFÉRENCE de la preuve (elle garde l'ancien
# gardien). Avec : une base en service (nv_serveur du PC), comme le VPS.
set -eu
# Des fichiers de travail à soi : un ancien /tmp/… laissé par un autre
# utilisateur ne peut pas bloquer la recette.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
: "${BASE:?}" "${TRAVAIL:?}" "${MIGR:?}" "${NVMIGR:?}" "${OUTILS:?}" "${COPIE:?}"

echo "1. Les migrations de Supabase (structure + ancien gardien)…"
if ! TMPDIR="$T" BASE="$BASE" TRAVAIL="$TRAVAIL" MIGR="$MIGR" sh "$TRAVAIL/replay.sh" > "$T/replay.txt" 2>&1; then
  sed 's/^/   /' "$T/replay.txt"; exit 1
fi
echo "   $(tail -1 "$T/replay.txt")"

echo "2. Les migrations du serveur Rust${EN_SERVICE:+ (et celles d'une base en service)}…"
n=0
for f in $(sh "$OUTILS/ordre_des_migrations.sh" "$NVMIGR" ${EN_SERVICE:+"$EN_SERVICE"}); do
  psql -q -v ON_ERROR_STOP=1 -1 -U postgres -d "$BASE" -f "$f" > "$T/nvmigr.txt" 2>&1 || {
    echo "ECHEC au fichier $(basename "$f")"; grep -v NOTICE "$T/nvmigr.txt" | head -20; exit 1; }
  n=$((n+1))
done
echo "   $n fichier(s)"

echo "3. La copie des données de dev…"
# La sortie est gardée ENTIÈRE : en cas d'échec, c'est le message de
# PostgreSQL qu'on montre, pas un simple compte.
if ! psql -q -v ON_ERROR_STOP=1 -v copie="$COPIE" -U postgres -d "$BASE" -f "$OUTILS/importer_copie.sql" > "$T/import.txt" 2>&1; then
  echo "ECHEC de l'import :"; grep -v NOTICE "$T/import.txt" | head -20; exit 1
fi
echo "   $(grep -c NOTICE "$T/import.txt" || true) tables remplies"
