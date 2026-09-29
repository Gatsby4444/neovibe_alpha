#!/usr/bin/env bash
# Monte la base `neovibe` du VPS — à lancer EN ROOT SUR LE VPS
# (deployer.sh --base l'envoie et l'appelle). LA recette est celle de la
# base locale (server/outils/recette_base.sh), sans l'instrument de la
# preuve. Les données sont la copie de la dev : décision de Jay du
# 2026-09-28, on recopie les données de test, purge totale avant la
# production (RAPPELS #176 ⑥).
#
#   monter_base.sh <dossier envoyé> [--remplacer]
#
# Refuse d'écraser une base existante sans --remplacer : c'est une
# opération destructrice, sur ordre de Jay seulement.
set -euo pipefail
PAQUET="$1"
REMPLACER="${2:-}"
BASE=neovibe

if sudo -u postgres psql -Atqc "select 1 from pg_database where datname = '$BASE'" | grep -q 1; then
  if [ "$REMPLACER" != "--remplacer" ]; then
    echo "La base $BASE existe déjà : rien n'est fait (--remplacer pour l'effacer et la refaire)."
    exit 1
  fi
  systemctl stop nv-server || true
  sudo -u postgres psql -q -c "drop database $BASE with (force)"
fi

# Le serveur de la base (utilisateur postgres) lit la copie lui-même
# (pg_read_file) : elle doit lui être lisible, et à personne d'autre.
chown -R postgres:postgres "$PAQUET"
chmod -R go-rwx "$PAQUET"

sudo -u postgres psql -q -v ON_ERROR_STOP=1 -c "create database $BASE"
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -c "alter database $BASE set search_path = \"\$user\", public, extensions"
STATUT=0
( cd /tmp && sudo -u postgres env BASE="$BASE" TRAVAIL="$PAQUET/repetition_vps" MIGR="$PAQUET/supabase_migrations" \
    NVMIGR="$PAQUET/server_migrations" OUTILS="$PAQUET/outils" COPIE="$PAQUET/copie" \
    sh "$PAQUET/outils/recette_base.sh" ) || STATUT=$?

# La copie contient les comptes de test (adresses, empreintes de mots de
# passe) : elle ne reste pas sur le disque, réussite ou échec.
rm -rf "$PAQUET/copie"
[ "$STATUT" = 0 ] || { echo "La base $BASE n'est PAS prête."; exit "$STATUT"; }
# Une base neuve a l'ancien gardien ALLUMÉ (il vient des migrations de
# Supabase) : le serveur refuse d'y démarrer tant qu'il n'est pas éteint.
if [ -x /opt/neovibe/bin/nv-server ]; then
  /opt/neovibe/bin/nv-server eteindre-l-ancien-gardien | sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$BASE"
  echo "Ancien gardien éteint."
  systemctl start nv-server
else
  echo "⚠️  Serveur pas encore construit : l'ancien gardien sera éteint au déploiement (deployer.sh)."
fi
echo "Base $BASE prête."
