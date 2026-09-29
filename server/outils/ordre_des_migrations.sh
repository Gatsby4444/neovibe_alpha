#!/bin/sh
# L'ORDRE des migrations du serveur — une seule façon de le dire, pour le
# VPS (vps/deployer.sh) et pour la base du serveur du PC (recette_base.sh).
#
#   sh ordre_des_migrations.sh <dossier> [<dossier>…]
#
# Rend les fichiers .sql des dossiers donnés, triés ENSEMBLE par leur nom
# (horodaté : AAAAMMJJhhmmss_…) — pas dossier par dossier. Une migration
# « en service » (server/migrations_en_service/) prend ainsi sa place parmi
# celles de tout serveur (server/migrations/) : le retrait de l'ancien
# gardien passe avant une migration plus récente qui ajouterait une
# fonction, et ne l'efface donc jamais. (Constaté par le relecteur le
# 2026-09-29 : le PC jouait les migrations en service APRÈS toutes les
# autres, le VPS dans l'ordre des noms — deux bases qui auraient divergé en
# silence.)
set -eu
for d in "$@"; do
  ls "$d"/*.sql
done | awk -F/ '{print $NF "\t" $0}' | sort | cut -f2
