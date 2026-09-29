#!/usr/bin/env bash
# Restaure une sauvegarde de la base NeoVibe — EN ROOT SUR LE VPS.
#
#   restaurer.sh <neovibe-<date>.dump> [base]   base par défaut : essai_restauration
#   PGPORT=5433 restaurer.sh …                  vers un autre serveur de base
#                                               de la machine (essai sur un neuf)
#
# Deux choses que `pg_restore -d <base>` seul ne fait PAS, et que ce script
# fait (constaté le 2026-09-29) :
# 1. les RÔLES : ils vivent hors de la base (sauvegarde.sh les range dans
#    `roles-<date>.sql`, à côté du .dump). Sur une machine neuve, la base ne
#    se restaure pas sans eux. Ceux qui existent déjà ne sont pas touchés.
# 2. les RÉGLAGES de la base (`ALTER DATABASE … SET search_path`) : sans
#    eux, une base restaurée ne trouve plus les fonctions du schéma
#    `extensions` (`uuid_generate_v4() does not exist`, reproduit). Le .dump
#    les CONTIENT (pg_restore ne les sort qu'avec --create, qui impose
#    l'ancien nom de base) : on les y lit, aucune valeur n'est écrite ici de
#    mémoire.
#
# Refuse d'écraser une base existante : pour remplacer `neovibe`, l'effacer
# d'abord, sur ordre de Jay.
set -euo pipefail
FICHIER="$1"
BASE="${2:-essai_restauration}"
PG=(sudo -u postgres env PGPORT="${PGPORT:-5432}")
ROLES="$(dirname "$FICHIER")/roles-$(basename "$FICHIER" .dump | sed 's/^neovibe-//').sql"

if "${PG[@]}" psql -Atqc "select 1 from pg_database where datname = '$BASE'" | grep -q 1; then
  echo "La base $BASE existe déjà : rien n'est fait."
  exit 1
fi
REGLAGES="$("${PG[@]}" pg_restore --create -f - "$FICHIER" \
  | sed -nE "s/^ALTER DATABASE [a-z_]+ SET (.*)$/ALTER DATABASE $BASE SET \1/p")"
if [ -z "$REGLAGES" ]; then
  echo "Aucun réglage de base dans la sauvegarde : elle n'est pas complète, rien n'est fait."
  exit 1
fi

# Les rôles manquants seulement : chaque « create role » d'un rôle existant
# est écarté, et son mot de passe n'est pas remplacé.
[ -f "$ROLES" ] || { echo "Pas de fichier des rôles ($ROLES) : rien n'est fait."; exit 1; }
EXISTANTS="$("${PG[@]}" psql -Atqc "select string_agg(rolname, '|') from pg_roles")"
# (Quand tous existent, le filtre ne rend rien, et grep le signale par un
# code d'échec : ce n'en est pas un — sans `|| true`, le script s'arrêtait
# là en silence, constaté le 2026-09-29.)
{ grep -E '^(CREATE|ALTER) ROLE ' "$ROLES" | grep -vE "^(CREATE|ALTER) ROLE ($EXISTANTS)( |;)" || true; } \
  | "${PG[@]}" psql -q -v ON_ERROR_STOP=1
grep -E '^GRANT .* TO ' "$ROLES" | "${PG[@]}" psql -q -v ON_ERROR_STOP=1 2>&1 | grep -v "already a member" || true

"${PG[@]}" psql -q -v ON_ERROR_STOP=1 -c "create database $BASE"
echo "$REGLAGES" | "${PG[@]}" psql -q -v ON_ERROR_STOP=1
"${PG[@]}" pg_restore --exit-on-error -d "$BASE" "$FICHIER"
N="$("${PG[@]}" psql -d "$BASE" -Atqc "select count(*) from auth.users")"
echo "Restaurée dans $BASE : $N comptes."
